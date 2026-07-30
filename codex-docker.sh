#!/bin/sh

set -eu

minimum_docker_major=28
bundle_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
compose_file="$bundle_dir/.codex-container/compose.yaml"
CODEX_WORKSPACE=$(pwd -P)
CODEX_HOST_UID=$(id -u)
CODEX_HOST_GID=$(id -g)
export CODEX_HOST_GID
export CODEX_HOST_UID
export CODEX_WORKSPACE
command_name=${1:-run}

get_workspace_hash() (
    if command -v sha256sum >/dev/null 2>&1; then
        hash_output=$(printf '%s' "$CODEX_WORKSPACE" | sha256sum)
    elif command -v shasum >/dev/null 2>&1; then
        hash_output=$(printf '%s' "$CODEX_WORKSPACE" | shasum -a 256)
    else
        echo "sha256sum or shasum is required" >&2
        exit 1
    fi
    workspace_hash=${hash_output%% *}
    printf '%.16s' "$workspace_hash"
)

validate_workspace() {
    case "$CODEX_WORKSPACE" in
        /|/Applications|/Applications/*|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|\
        /lib64|/lib64/*|/opt|/opt/*|/private|/private/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|\
        /sbin/*|/sys|/sys/*|/System|/System/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/*)
            echo "Refusing unsafe workspace: $CODEX_WORKSPACE" >&2
            exit 1
            ;;
    esac
    if test -n "${HOME:-}"; then
        case "$HOME/" in
            "$CODEX_WORKSPACE/"*)
                echo "Refusing a workspace that contains the home directory" >&2
                exit 1
                ;;
        esac
    fi
    case "$bundle_dir/" in
        "$CODEX_WORKSPACE/"*)
            echo "The workspace must not contain the codex-docker bundle" >&2
            exit 1
            ;;
    esac
    case "$CODEX_WORKSPACE/" in
        "$bundle_dir/"*)
            echo "The workspace must be outside the codex-docker bundle" >&2
            exit 1
            ;;
    esac
    if test "${1:-}" = skip-content; then
        return
    fi
    workspace_hazards=$(find "$CODEX_WORKSPACE" \( -type l -o -type s -o -name docker.sock \) -print 2>/dev/null) || {
        echo "Unable to inspect the workspace for symlinks and sockets" >&2
        exit 1
    }
    if test -n "$workspace_hazards"; then
        echo "Refusing a workspace that contains a symlink or socket: $workspace_hazards" >&2
        exit 1
    fi
}

validate_host_identity() {
    if test "$CODEX_HOST_UID" -eq 0 || test "$CODEX_HOST_GID" -eq 0; then
        echo "Refusing to map the Codex user to host UID or GID 0" >&2
        exit 1
    fi
}

require_secure_docker() {
    docker_version=$(docker version --format '{{.Server.Version}}')
    docker_major=${docker_version%%.*}
    case "$docker_major" in
        ''|*[!0-9]*)
            echo "Unable to determine the Docker Engine version" >&2
            exit 1
            ;;
    esac
    if test "$docker_major" -lt "$minimum_docker_major"; then
        echo "Docker Engine $minimum_docker_major or newer is required for isolated bridge gateways" >&2
        exit 1
    fi
}

validate_codex_args() {
    for codex_argument do
        case "$codex_argument" in
            --dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust|--full-auto|--yolo|\
            --sandbox|--sandbox=*|-s|-s?*|--ask-for-approval|--ask-for-approval=*|-a|-a?*|\
            --config|--config=*|-c|-c?*|--cd|--cd=*|-C|-C?*|--add-dir|--add-dir=*|--remote*)
                echo "Refusing Codex argument that weakens workspace policy: $codex_argument" >&2
                exit 1
                ;;
        esac
    done
}

case "$command_name" in
    status|stop)
        validate_workspace skip-content
        ;;
    *)
        validate_workspace
        ;;
esac
workspace_hash=$(get_workspace_hash)
COMPOSE_PROJECT_NAME="codex-$workspace_hash"
export COMPOSE_PROJECT_NAME

run_compose() {
    docker compose --project-directory "$bundle_dir" -f "$compose_file" "$@"
}

run_codex() {
    validate_codex_args "$@"
    validate_host_identity
    require_secure_docker
    run_compose run --rm codex \
        --sandbox workspace-write \
        --ask-for-approval on-request \
        "$@"
}

check_security() {
    validate_host_identity
    require_secure_docker
    run_compose up --detach egress
    network_name="${COMPOSE_PROJECT_NAME}_codex_internal"
    gateway_ip=$(docker network inspect "$network_name" --format '{{(index .IPAM.Config 0).Gateway}}')
    gateway_mode=$(docker network inspect "$network_name" \
        --format '{{index .Options "com.docker.network.bridge.gateway_mode_ipv4"}}')
    if test "$gateway_mode" != isolated; then
        echo "The internal network is not using isolated gateway mode" >&2
        exit 1
    fi
    if test "$gateway_ip" = "invalid IP"; then
        gateway_ip=
    fi
    run_compose run --rm --env "CODEX_GATEWAY_IP=$gateway_ip" --entrypoint sh codex -c '
        set -eu
        probe_blocked_address() {
            CODEX_PROBE_ADDRESS=$1
            export CODEX_PROBE_ADDRESS
            node -e "
                const net = require(\"net\");
                const socket = net.connect(9, process.env.CODEX_PROBE_ADDRESS);
                const blocked = [\"EHOSTUNREACH\", \"ENETUNREACH\", \"ETIMEDOUT\"];
                socket.setTimeout(1000, () => process.exit(0));
                socket.on(\"connect\", () => process.exit(1));
                socket.on(\"error\", error => process.exit(blocked.indexOf(error.code) >= 0 ? 0 : 1));
            "
        }
        proxy_connect_denied_code=403
        proxy_connect_timeout=5
        require_proxy_connect_denied() {
            target_url=$1
            connect_code=$(curl --insecure --silent --output /dev/null --proxy "$HTTPS_PROXY" \
                --max-time "$proxy_connect_timeout" --write-out "%{http_connect}" "$target_url" || true)
            if test "$connect_code" != "$proxy_connect_denied_code"; then
                echo "Proxy CONNECT was not denied for $target_url: HTTP $connect_code" >&2
                exit 1
            fi
        }
        openai_status=$(curl --silent --output /dev/null --write-out "%{http_connect}:%{http_code}" --max-time 15 \
            https://api.openai.com/v1/models)
        case "$openai_status" in
            200:2*|200:401|200:403) ;;
            *) echo "OpenAI endpoint check failed: CONNECT/HTTP $openai_status" >&2; exit 1 ;;
        esac
        require_proxy_connect_denied https://example.com
        require_proxy_connect_denied https://1.1.1.1
        require_proxy_connect_denied "https://[::1]"
        require_proxy_connect_denied https://169.254.169.254
        if env -u ALL_PROXY -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u http_proxy -u https_proxy \
            curl --fail --silent --noproxy "*" --output /dev/null --max-time 5 https://example.com; then
            echo "Direct internet is reachable" >&2
            exit 1
        fi
        if env -u ALL_PROXY -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u http_proxy -u https_proxy \
            curl --fail --silent --noproxy "*" --output /dev/null --max-time 3 \
            http://169.254.169.254/latest/meta-data/; then
            echo "Metadata address is directly reachable" >&2
            exit 1
        fi
        if getent ahostsv4 example.com >/dev/null 2>&1; then
            echo "External DNS resolution is available" >&2
            exit 1
        fi
        if awk "\$2 == \"00000000\" { found = 1 } END { exit found ? 0 : 1 }" /proc/net/route; then
            echo "A direct default route is available" >&2
            exit 1
        fi
        if test -s /proc/net/if_inet6; then
            echo "IPv6 is enabled" >&2
            exit 1
        fi
        if test -n "$CODEX_GATEWAY_IP"; then
            if ! probe_blocked_address "$CODEX_GATEWAY_IP"; then
                echo "The Docker bridge gateway is reachable" >&2
                exit 1
            fi
            if awk -v address="$CODEX_GATEWAY_IP" \
                "\$1 == address && \$3 == \"0x2\" { found = 1 } END { exit found ? 0 : 1 }" /proc/net/arp; then
                echo "The Docker bridge gateway answered ARP" >&2
                exit 1
            fi
        fi
        host_address=$(getent ahostsv4 host.docker.internal 2>/dev/null | awk "NR == 1 { print \$1 }")
        if test -n "$host_address" && ! probe_blocked_address "$host_address"; then
            echo "host.docker.internal is reachable" >&2
            exit 1
        fi
        if test -S /var/run/docker.sock || test -S /run/docker.sock || \
            find /workspace -name docker.sock -print 2>/dev/null | grep -q .; then
            echo "A Docker socket is visible" >&2
            exit 1
        fi
        if touch /read-only-root-check 2>/dev/null; then
            echo "Container root is writable" >&2
            exit 1
        fi
        home_owner=$(stat --format "%u:%g" /codex-home)
        current_owner=$(id -u):$(id -g)
        if test "$home_owner" != "$current_owner"; then
            echo "Codex home has an unexpected owner" >&2
            exit 1
        fi
        home_mode=$(stat --format "%a" /codex-home)
        if test "$home_mode" != 700; then
            echo "Codex home permissions are not 0700" >&2
            exit 1
        fi
        workspace_check=/workspace/.codex-workspace-check
        touch "$workspace_check"
        rm "$workspace_check"
        echo "PASS: proxy allowlist, direct route, DNS, mount, auth, and filesystem checks passed"
    '
}

case "$command_name" in
    run)
        if test "$#" -gt 0; then
            shift
        fi
        run_codex "$@"
        ;;
    login)
        shift
        if test "$#" -gt 0; then
            echo "The login command does not accept arguments" >&2
            exit 1
        fi
        validate_host_identity
        require_secure_docker
        run_compose run --rm codex login --device-auth
        ;;
    api-login)
        shift
        if test "$#" -gt 0; then
            echo "The api-login command does not accept arguments" >&2
            exit 1
        fi
        validate_host_identity
        require_secure_docker
        test -n "${OPENAI_API_KEY:-}" || {
            echo "OPENAI_API_KEY is not set" >&2
            exit 1
        }
        printf '%s' "$OPENAI_API_KEY" | run_compose run --rm -T codex login --with-api-key
        ;;
    build)
        shift
        validate_host_identity
        if test "$#" -gt 0; then
            CODEX_VERSION=$1
            export CODEX_VERSION
        fi
        run_compose build
        ;;
    check)
        shift
        check_security "$@"
        ;;
    status)
        shift
        run_compose ps "$@"
        ;;
    stop)
        shift
        if test "$#" -gt 0; then
            echo "The stop command does not accept arguments" >&2
            exit 1
        fi
        run_compose down
        ;;
    *)
        run_codex "$@"
        ;;
esac
