#!/usr/bin/env bash
# Fix ownership of named-volume mount points. Volumes mount root-owned
# and empty by default; this lets the vscode user write to them.
#
# Takes the worktree slug as $1 (passed by post-create.sh from the WORKTREE
# env var). Positional rather than env-passthrough so the strict sudoers
# entry doesn't need a SETENV tag.
set -euo pipefail

worktree=${1:?worktree slug required as first argument}

paths=(
    "/work/${worktree}/target"
    "/work/${worktree}/node_modules"
    /usr/local/cargo/registry
    /usr/local/cargo/git
    /home/vscode/.claude
    /commandhistory
)

for p in "${paths[@]}"; do
    mkdir -p "$p"
    chown vscode:vscode "$p"
    chmod 755 "$p"
done
