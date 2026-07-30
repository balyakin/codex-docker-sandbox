# Codex Docker Sandbox

A deliberately narrow Docker home for OpenAI Codex CLI.

[![CI][badge-ci]][ci]
[![Codex CLI][badge-codex]][codex]
[![Docker Engine][badge-docker]][docker-engine]
[![Platforms][badge-platforms]][requirements]
[![Network policy][badge-network]][network-policy]
[![License: MIT][badge-license]][license]

Codex is useful because it can read code, edit files, and run commands. That is also the sharp edge.

Codex Docker Sandbox gives the CLI one project directory, a private home for that project, and a very thin road to the
internet. The rest of the host stays outside. No SSH directory. No shared `~/.codex`. No Docker socket quietly tucked
into the container.

Two containers do the job. The Codex container lives on an internal bridge with no gateway address and no working
external DNS. A small Squid sidecar straddles that bridge and the internet, forwarding HTTPS only to three explicit
destinations:

- `api.openai.com`
- `auth.openai.com`
- `chatgpt.com`

That is the whole runtime network allowlist. Short on purpose.

This is an independent community project. It is not affiliated with or endorsed by OpenAI.

## What It Locks Down

- The current directory is the only host path mounted into the Codex container.
- Each absolute workspace path gets its own Compose project, network, and persistent Codex home.
- The Docker socket is never mounted.
- Codex runs as a non-root user mapped to the host UID and GID on macOS and Linux.
- Both containers drop every Linux capability and set `no-new-privileges`.
- Container root filesystems are read-only. Only the workspace, Codex home, and bounded `tmpfs` mounts are writable.
- Direct internet, host bridge access, external DNS, IP-literal proxy targets, IPv6, and cloud metadata routes are
  blocked.
- CPU, memory, PID, and temporary-storage limits are set.
- CLI arguments that could replace the fixed workspace or security policy are rejected before Docker starts.

The launcher is strict about the workspace too. It rejects disk roots, home and system directories, the bundle itself,
symbolic links, sockets, reparse points, and any file named `docker.sock`.

Strict means strict. A generated `node_modules` tree full of symlinks will be rejected; use a clean checkout or remove
that generated directory before launch.

## Security Boundary

Docker is the outer sandbox here.

Codex also keeps its own `workspace-write` sandbox and `on-request` approval policy inside the container. The outer
Docker boundary remains independent: its only host bind mount is the selected workspace, while Docker and Squid enforce
the network path. User-supplied sandbox, approval, config, working-directory, additional-directory, and remote-execution
flags are refused.

Read the configuration. Run the check. Trust neither slogans nor shield badges.

## Requirements

- Docker Engine 28 or newer
- Docker Compose
- macOS with Docker Desktop, Linux with Docker Engine, or Windows with Docker Desktop in Linux-container mode

Docker 28 matters. The internal bridge uses `gateway_mode_ipv4: isolated`, which leaves the bridge without a host-side
gateway address.

## Install on macOS or Linux

Keep the bundle outside every project you plan to open:

```bash
git clone https://github.com/balyakin/codex-docker-sandbox.git \
    "$HOME/.local/share/codex-docker-sandbox"
chmod +x "$HOME/.local/share/codex-docker-sandbox/codex-docker.sh"
```

Add a short alias:

```bash
alias codex-docker="$HOME/.local/share/codex-docker-sandbox/codex-docker.sh"
```

Put that line in `~/.zshrc` or `~/.bashrc` if you want it to survive the terminal session.

Now move into a project. Not your home directory. Not the sandbox repository.

```bash
cd /path/to/project
codex-docker build
codex-docker check
codex-docker login
codex-docker
```

`login` uses device authentication, so the browser callback never needs to reach into the container.

## Install on Windows

Open PowerShell:

```powershell
$InstallDir = "$env:LOCALAPPDATA\codex-docker-sandbox"
git clone https://github.com/balyakin/codex-docker-sandbox.git $InstallDir
Unblock-File "$InstallDir\codex-docker.ps1"
Set-Alias codex-docker "$InstallDir\codex-docker.ps1" -Scope Global
```

To keep the alias, add the `Set-Alias` line to your PowerShell profile.

Then:

```powershell
Set-Location C:\path\to\project
codex-docker build
codex-docker check
codex-docker login
codex-docker
```

## API Key Login

ChatGPT login is not required when you use an API key:

```bash
export OPENAI_API_KEY="your-key"
codex-docker api-login
unset OPENAI_API_KEY
```

PowerShell:

```powershell
$env:OPENAI_API_KEY = "your-key"
codex-docker api-login
Remove-Item Env:OPENAI_API_KEY
```

The key is piped to `codex login --with-api-key`; it is not declared in `compose.yaml`.

## Commands

| Command | Purpose |
| --- | --- |
| `codex-docker` | Start an interactive Codex session |
| `codex-docker run ARGS...` | Start Codex and pass safe CLI arguments |
| `codex-docker login` | Sign in with a ChatGPT device code |
| `codex-docker api-login` | Read `OPENAI_API_KEY` and store API authentication |
| `codex-docker build [VERSION]` | Build the images; defaults to Codex CLI `0.146.0` |
| `codex-docker check` | Probe the network and filesystem boundary |
| `codex-docker status` | Show this workspace's Compose services |
| `codex-docker stop` | Stop the egress sidecar without deleting authentication |

Unknown first arguments are forwarded to Codex, so commands such as `codex-docker resume` still work. Policy-changing
arguments do not.

## What `check` Actually Checks

The check starts the egress proxy and creates a disposable Codex container. It then verifies:

- OpenAI is reachable through the proxy;
- unrelated domains, public IP literals, IPv6 literals, and metadata addresses are denied by the proxy;
- direct HTTPS and metadata access fail without proxy variables;
- external DNS resolution is unavailable;
- no direct default route or IPv6 interface is present;
- Docker reports isolated gateway mode, and any exposed gateway or `host.docker.internal` address is unreachable;
- no Docker socket is visible;
- the root filesystem is read-only;
- the persistent Codex home belongs to the mapped user and has mode `0700`;
- the selected workspace is writable.

Success ends with:

```text
PASS: proxy allowlist, direct route, DNS, mount, auth, and filesystem checks passed
```

If you do not get `PASS`, do not start a session. Stop there and inspect the failure.

## Network Policy

```text
selected project ── bind mount ──> codex
                                     │
                              internal bridge
                              no host gateway
                              no external DNS
                                     │
                                     ▼
                                 Squid :3128 ──> OpenAI / ChatGPT only
```

Squid accepts only `CONNECT` to port 443. Hostnames must match the allowlist without reverse-DNS guessing, raw IP
authorities are denied, and private or special-use IPv4 destinations are rejected before traffic is allowed.

## What This Does Not Do

The fence is real. It is not magic.

- This is not a VM. Docker Engine, Docker Desktop, Squid, and the host kernel remain trusted.
- This is not DLP. Codex can send workspace content to the allowed OpenAI and ChatGPT endpoints.
- Codex can alter source files, CI workflows, build scripts, and other executable project content. Review the diff
  before running changed code on the host.
- Codex credentials live inside the per-project volume and are available to the Codex process.
- An administrator or anyone controlling the Docker daemon can bypass these restrictions.
- Image builds use the regular internet to download Debian packages and the pinned Codex npm version.
- The image contains Node.js, Git, cURL, jq, and ripgrep. It does not contain Python, Go, Java, or your project's
  dependency stack.
- Path-based project separation means moving or renaming a project creates a fresh network and Codex home.

Use a VM, gVisor, Kata Containers, or a dedicated machine when your threat model needs a stronger kernel boundary.

## Project Layout

```text
.codex-container/
├── Dockerfile
├── compose.yaml
└── squid.conf
codex-docker.sh
codex-docker.ps1
```

There is no host daemon and no installation script. Clone, alias, run.

## Contributing

Small, reviewable patches are welcome. Network-policy changes need an accompanying probe in `check`; launcher changes
must keep the POSIX shell and PowerShell implementations aligned. See [CONTRIBUTING.md](CONTRIBUTING.md).

Security flaws should not begin life in a public issue. See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

## Development

This project was developed with AI assistance and is maintained by the author.

[badge-ci]: https://github.com/balyakin/codex-docker-sandbox/actions/workflows/ci.yml/badge.svg
[badge-codex]: https://img.shields.io/badge/Codex%20CLI-0.146.0-111827
[badge-docker]: https://img.shields.io/badge/Docker%20Engine-28%2B-2496ED?logo=docker&logoColor=white
[badge-platforms]: https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-blue
[badge-network]: https://img.shields.io/badge/egress-allowlist-brightgreen
[badge-license]: https://img.shields.io/badge/license-MIT-green.svg
[ci]: https://github.com/balyakin/codex-docker-sandbox/actions/workflows/ci.yml
[codex]: https://github.com/openai/codex
[docker-engine]: https://docs.docker.com/engine/network/port-publishing/#gateway-modes
[license]: https://github.com/balyakin/codex-docker-sandbox/blob/main/LICENSE
[network-policy]: #network-policy
[requirements]: #requirements
