#!/bin/sh

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
test_dir=$(mktemp -d "$project_dir/.workspace-symlink-test.XXXXXX")
bundle_dir="$test_dir/bundle"
workspace_dir="$test_dir/workspace"
outside_dir="$test_dir/workspace-outside"
fake_bin="$test_dir/bin"
output_path="$test_dir/external-link-output"
trap 'rm -rf "$test_dir"' 0 HUP INT TERM

# ARRANGE
mkdir -p "$bundle_dir" "$workspace_dir/config" "$outside_dir" "$fake_bin"
cp "$project_dir/codex-docker.sh" "$bundle_dir/codex-docker.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/docker"
chmod +x "$fake_bin/docker"
printf '%s\n' 'internal' > "$workspace_dir/config/service.conf"
printf '%s\n' 'external' > "$outside_dir/service.conf"
ln -s config/service.conf "$workspace_dir/service.conf"

# ACT
(
    cd "$workspace_dir"
    PATH="$fake_bin:$PATH" "$bundle_dir/codex-docker.sh" build
)

# ASSERT
ln -s ../workspace-outside/service.conf "$workspace_dir/external.conf"
if (
    cd "$workspace_dir"
    PATH="$fake_bin:$PATH" "$bundle_dir/codex-docker.sh" build
) >"$output_path" 2>&1; then
    echo "External workspace symlink was accepted" >&2
    exit 1
fi
grep -F "symlink outside the workspace" "$output_path" >/dev/null
