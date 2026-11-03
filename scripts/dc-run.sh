#!/usr/bin/env bash
# Dispatch a command inside or outside the devcontainer.
#
# SPDX-License-Identifier: MIT
#
# Usage:
#   scripts/dc-run.sh [-w <workdir>] -- <command> [args...]
#   scripts/dc-run.sh [-w <workdir>] --shell        # interactive bash
#
# Options:
#   -w <workdir>   Working directory, relative to repo root (no abs paths, no '..').
#                  Defaults to repo root.
#   --shell        Exec interactive bash instead of a command.
#   -h, --help     Print this help.
#
# Detection (in order):
#   1. DC_RUN_REEXEC=1   set by this script when re-execing inside.
#   2. IN_DEVCONTAINER=1 set by .devcontainer/Dockerfile.
#
# Behavior:
#   Inside  : cd to <repo>/<workdir>, exec the command.
#   Outside : re-exec self via `devcontainer exec`, preserving argv.
#
# Argv is preserved end-to-end (no shell parsing). For multi-step shell
# logic (e.g. piping, &&), pass `bash -c '...'` explicitly.

set -euo pipefail

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

die() {
    echo "dc-run: $*" >&2
    exit 2
}

# ----- parse args -----
WORKDIR=""
SHELL_MODE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w)
            [[ $# -ge 2 ]] || die "-w requires a value"
            WORKDIR="$2"
            shift 2
            ;;
        --shell)
            SHELL_MODE=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1 (use -- before the command)"
            ;;
    esac
done

# Validate workdir: no absolute paths, no parent traversal.
if [[ -n "$WORKDIR" ]]; then
    case "$WORKDIR" in
        /*) die "workdir must be relative to repo root, got: $WORKDIR" ;;
    esac
    # Reject any '..' path component.
    IFS='/' read -ra _parts <<< "$WORKDIR"
    for _p in "${_parts[@]}"; do
        [[ "$_p" != ".." ]] || die "workdir must not contain '..', got: $WORKDIR"
    done
    unset _parts _p
fi

# ----- locate repo root -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_HOST="$(dirname "$SCRIPT_DIR")"
REPO_BASENAME="$(basename "$REPO_ROOT_HOST")"
REPO_ROOT_INSIDE="/workspaces/${REPO_BASENAME}"

inside_devcontainer() {
    [[ "${DC_RUN_REEXEC:-0}" = "1" ]] || [[ "${IN_DEVCONTAINER:-0}" = "1" ]]
}

if inside_devcontainer; then
    # Sanity-check the expected workspace path exists.
    if [[ ! -d "$REPO_ROOT_INSIDE" ]]; then
        die "expected repo path not found inside container: $REPO_ROOT_INSIDE
     (devcontainer.json may have changed workspaceFolder; update dc-run.sh)"
    fi

    target_dir="${REPO_ROOT_INSIDE}${WORKDIR:+/$WORKDIR}"
    [[ -d "$target_dir" ]] || die "workdir not found: $target_dir"
    cd "$target_dir"

    if [[ $SHELL_MODE -eq 1 ]]; then
        exec bash
    elif [[ $# -eq 0 ]]; then
        die "missing command (use --shell for interactive bash, or pass cmd after --)"
    else
        exec "$@"
    fi
fi

# ----- outside: re-exec via devcontainer exec -----
command -v devcontainer >/dev/null \
    || die "'devcontainer' CLI not found on PATH (install @devcontainers/cli)"

dc_flags=(
    --workspace-folder "$REPO_ROOT_HOST"
    --remote-env "GIT_COMMITTER_NAME=vscode"
    --remote-env "GIT_COMMITTER_EMAIL=vscode@example.com"
    --remote-env "DC_RUN_REEXEC=1"
    --remote-env "ARCH=${ARCH:-aarch64}"
)

inner=( "${REPO_ROOT_INSIDE}/scripts/dc-run.sh" )
[[ -n "$WORKDIR" ]] && inner+=( -w "$WORKDIR" )
if [[ $SHELL_MODE -eq 1 ]]; then
    inner+=( --shell )
else
    [[ $# -gt 0 ]] || die "missing command (use --shell or pass cmd after --)"
    inner+=( -- "$@" )
fi

exec devcontainer exec "${dc_flags[@]}" "${inner[@]}"
