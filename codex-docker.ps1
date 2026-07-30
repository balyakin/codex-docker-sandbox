param(
    [Parameter(Position = 0)]
    [string]$Command = "run",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"
$MinimumDockerMajor = 28
$BundleDir = (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).ProviderPath
$ComposeFile = Join-Path $BundleDir ".codex-container/compose.yaml"
$WorkspacePath = (Resolve-Path -LiteralPath (Get-Location).Path).ProviderPath
$env:CODEX_HOST_GID = "1000"
$env:CODEX_HOST_UID = "1000"
$env:CODEX_WORKSPACE = $WorkspacePath

function Test-PathWithin {
    param(
        [string]$Path,
        [string]$Root
    )

    $DirectorySeparator = [System.IO.Path]::DirectorySeparatorChar
    $AlternateSeparator = [System.IO.Path]::AltDirectorySeparatorChar
    $PathValue = [System.IO.Path]::GetFullPath($Path).TrimEnd($DirectorySeparator, $AlternateSeparator)
    $RootValue = [System.IO.Path]::GetFullPath($Root).TrimEnd($DirectorySeparator, $AlternateSeparator)
    $RootPrefix = $RootValue + $DirectorySeparator
    $PathsEqual = $PathValue.Equals($RootValue, [System.StringComparison]::OrdinalIgnoreCase)
    $PathInsideRoot = $PathValue.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    return $PathsEqual -or $PathInsideRoot
}

function Assert-SafeWorkspace {
    param(
        [switch]$SkipContentScan
    )

    $DirectorySeparator = [System.IO.Path]::DirectorySeparatorChar
    $AlternateSeparator = [System.IO.Path]::AltDirectorySeparatorChar
    $WorkspaceRoot = [System.IO.Path]::GetPathRoot($WorkspacePath)
    $WorkspaceValue = $WorkspacePath.TrimEnd($DirectorySeparator, $AlternateSeparator)
    $WorkspaceRootValue = $WorkspaceRoot.TrimEnd($DirectorySeparator, $AlternateSeparator)
    if ($WorkspaceValue -eq $WorkspaceRootValue) {
        throw "Refusing a drive root as the workspace"
    }
    if ($env:USERPROFILE -and (Test-PathWithin -Path $env:USERPROFILE -Root $WorkspacePath)) {
        throw "Refusing a workspace that contains the user profile"
    }
    $SystemPaths = @(
        $env:SystemRoot,
        $env:ProgramData,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )
    foreach ($SystemPath in $SystemPaths) {
        if (-not $SystemPath) {
            continue
        }
        $WorkspaceInSystem = Test-PathWithin -Path $WorkspacePath -Root $SystemPath
        $SystemInWorkspace = Test-PathWithin -Path $SystemPath -Root $WorkspacePath
        if ($WorkspaceInSystem -or $SystemInWorkspace) {
            throw "Refusing a workspace that overlaps a system directory"
        }
    }
    $WorkspaceInBundle = Test-PathWithin -Path $WorkspacePath -Root $BundleDir
    $BundleInWorkspace = Test-PathWithin -Path $BundleDir -Root $WorkspacePath
    if ($WorkspaceInBundle -or $BundleInWorkspace) {
        throw "The workspace must be outside the codex-docker bundle"
    }
    $WorkspaceItem = Get-Item -LiteralPath $WorkspacePath -Force
    $ReparsePoint = [System.IO.FileAttributes]::ReparsePoint
    if (($WorkspaceItem.Attributes -band $ReparsePoint) -ne 0) {
        throw "Refusing a reparse point as the workspace"
    }
    if ($SkipContentScan) {
        return
    }
    $WorkspaceReparsePoint = Get-ChildItem -LiteralPath $WorkspacePath -Force -Recurse -Attributes ReparsePoint |
        Select-Object -First 1
    if ($WorkspaceReparsePoint) {
        throw "Refusing a workspace that contains a reparse point: $($WorkspaceReparsePoint.FullName)"
    }
    $WorkspaceSocket = Get-ChildItem -LiteralPath $WorkspacePath -Filter "docker.sock" -Force -Recurse |
        Select-Object -First 1
    if ($WorkspaceSocket) {
        throw "Refusing a workspace that contains docker.sock: $($WorkspaceSocket.FullName)"
    }
}

function Get-WorkspaceHash {
    $Sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $WorkspaceBytes = [System.Text.Encoding]::UTF8.GetBytes($WorkspacePath)
        $HashBytes = $Sha256.ComputeHash($WorkspaceBytes)
    }
    finally {
        $Sha256.Dispose()
    }
    $HashText = [System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLowerInvariant()
    return $HashText.Substring(0, 16)
}

function Assert-SecureDocker {
    [string]$ServerVersion = & docker version --format '{{.Server.Version}}'
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    $ServerMajor = [int](($ServerVersion.Trim().Split("."))[0])
    if ($ServerMajor -lt $MinimumDockerMajor) {
        throw "Docker Engine $MinimumDockerMajor or newer is required for isolated bridge gateways"
    }
}

function Assert-SafeCodexArguments {
    foreach ($CodexArgument in $RemainingArgs) {
        $DangerousSwitch = $CodexArgument -match `
            '^--(dangerously-bypass-approvals-and-sandbox|dangerously-bypass-hook-trust|full-auto|yolo)$'
        $PolicySwitch = $CodexArgument -match '^--(sandbox|ask-for-approval|config|cd|add-dir)(=|$)'
        $RemoteSwitch = $CodexArgument -match '^--remote'
        $ShortPolicySwitch = $CodexArgument -match '^-[sacC].*$'
        if ($DangerousSwitch -or $PolicySwitch -or $RemoteSwitch -or $ShortPolicySwitch) {
            throw "Refusing Codex argument that weakens workspace policy: $CodexArgument"
        }
    }
}

if ($Command -in @("status", "stop")) {
    Assert-SafeWorkspace -SkipContentScan
}
else {
    Assert-SafeWorkspace
}
$WorkspaceHash = Get-WorkspaceHash
$env:COMPOSE_PROJECT_NAME = "codex-$WorkspaceHash"

function Invoke-Compose {
    & docker compose --project-directory $BundleDir -f $ComposeFile @args
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

function Invoke-Codex {
    Assert-SafeCodexArguments
    Assert-SecureDocker
    Invoke-Compose run --rm codex `
        --sandbox workspace-write `
        --ask-for-approval on-request `
        @RemainingArgs
}

switch ($Command) {
    "run" {
        Invoke-Codex
    }
    "login" {
        if ($RemainingArgs.Count -gt 0) {
            throw "The login command does not accept arguments"
        }
        Assert-SecureDocker
        Invoke-Compose run --rm codex login --device-auth
    }
    "api-login" {
        if ($RemainingArgs.Count -gt 0) {
            throw "The api-login command does not accept arguments"
        }
        Assert-SecureDocker
        if (-not $env:OPENAI_API_KEY) {
            throw "OPENAI_API_KEY is not set"
        }
        $env:OPENAI_API_KEY |
            & docker compose --project-directory $BundleDir -f $ComposeFile run --rm -T codex login --with-api-key
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
    "build" {
        if ($RemainingArgs.Count -gt 0) {
            $env:CODEX_VERSION = $RemainingArgs[0]
        }
        Invoke-Compose build
    }
    "check" {
        Assert-SecureDocker
        Invoke-Compose up --detach egress
        $NetworkName = "${env:COMPOSE_PROJECT_NAME}_codex_internal"
        $NetworkDetails = & docker network inspect $NetworkName | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
        [string]$GatewayIp = $NetworkDetails[0].IPAM.Config[0].Gateway
        [string]$GatewayMode = $NetworkDetails[0].Options.'com.docker.network.bridge.gateway_mode_ipv4'
        $GatewayIp = $GatewayIp.Trim()
        if ($GatewayMode.Trim() -ne "isolated") {
            throw "The internal network is not using isolated gateway mode"
        }
        if ($GatewayIp -eq "invalid IP") {
            $GatewayIp = ""
        }
        $SecurityCheckScript = @'
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
if awk '$2 == "00000000" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/route; then
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
        '$1 == address && $3 == "0x2" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/arp; then
        echo "The Docker bridge gateway answered ARP" >&2
        exit 1
    fi
fi
host_address=$(getent ahostsv4 host.docker.internal 2>/dev/null | awk 'NR == 1 { print $1 }')
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
'@
        $SecurityCheckScript = $SecurityCheckScript.Replace("`r", "")
        $SecurityCheckBytes = [System.Text.Encoding]::UTF8.GetBytes($SecurityCheckScript)
        $SecurityCheckBase64 = [System.Convert]::ToBase64String($SecurityCheckBytes)
        $SecurityCheckCommand = "printf %s $SecurityCheckBase64 | base64 --decode > /tmp/codex-check.sh"
        $SecurityCheckCommand += " && test -s /tmp/codex-check.sh && sh /tmp/codex-check.sh"
        Invoke-Compose run --rm --env "CODEX_GATEWAY_IP=$GatewayIp" --entrypoint sh codex `
            -c $SecurityCheckCommand
    }
    "status" {
        Invoke-Compose ps @RemainingArgs
    }
    "stop" {
        if ($RemainingArgs.Count -gt 0) {
            throw "The stop command does not accept arguments"
        }
        Invoke-Compose down
    }
    default {
        $RemainingArgs = @($Command) + $RemainingArgs
        Invoke-Codex
    }
}
