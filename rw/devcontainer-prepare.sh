#!/usr/bin/env bash
# Fix ownership of named-volume mount points. Volumes mount root-owned
# and empty by default; this lets the vscode user write to them.
set -euo pipefail

paths=(
    /workspace/target
    /workspace/node_modules
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
