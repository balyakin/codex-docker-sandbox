# Contributing

## Local Setup

Install Docker Engine 28 or newer with Docker Compose. Clone this repository outside the workspace you use for testing.

Create a disposable project directory, enter it, then build through the launcher:

```bash
mkdir codex-sandbox-test
cd codex-sandbox-test
/path/to/codex-docker-sandbox/codex-docker.sh build
```

## Checks

Run the static checks first:

```bash
sh -n codex-docker.sh
shellcheck --exclude=SC2016 codex-docker.sh
CODEX_HOST_UID=1000 \
CODEX_HOST_GID=1000 \
CODEX_WORKSPACE=/tmp/codex-workspace \
COMPOSE_PROJECT_NAME=codex-check \
docker compose --project-directory . -f .codex-container/compose.yaml config --quiet
```

From the disposable project directory, run the live boundary probe:

```bash
/path/to/codex-docker-sandbox/codex-docker.sh check
/path/to/codex-docker-sandbox/codex-docker.sh stop
```

Windows changes must also parse cleanly in PowerShell:

```powershell
$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\codex-docker.ps1),
    [ref]$Tokens,
    [ref]$ParseErrors
)
if ($ParseErrors.Count -gt 0) {
    $ParseErrors | Format-List
    exit 1
}
```

## Expectations

- Keep changes tight. One security boundary or behavior per pull request.
- Keep `codex-docker.sh` and `codex-docker.ps1` behaviorally aligned.
- Add a failing probe before changing a network or filesystem guarantee.
- Do not broaden the domain allowlist without explaining the new data path and its threat impact.
- Keep base images pinned by digest and the Codex CLI version explicit.
- Update `README.md` when installation, commands, limits, or guarantees change.
- Do not commit credentials, local workspaces, generated archives, BookStack exports, or audit scratch files.

Report vulnerabilities through the private route described in [SECURITY.md](SECURITY.md), not through a public issue.
