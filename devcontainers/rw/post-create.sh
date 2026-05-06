#!/usr/bin/env bash
set -euo pipefail

# Defensive PATH — devpod's lifecycle hook runner doesn't reliably propagate
# the PATH set in compose.yml's `environment:` block, so /usr/local/cargo/bin
# (rustup, cargo) and /usr/local/share/nvm/current/bin (node, npm, npx) end
# up missing from PATH when this script runs. Hardcode here so each step can
# find the tools the prior step just installed.
export PATH="/home/vscode/.local/bin:/usr/local/cargo/bin:/usr/local/share/nvm/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# WORKTREE is set in the container via compose.yml's `environment:` block,
# sourced from the worktree's host-side .env via `devpod up --workspace-env-file`.
: "${WORKTREE:?WORKTREE not set in container env (check compose.yml + worktree .env)}"

# 1. Fix ownership of named-volume mount points (root-owned by default).
#    Pass WORKTREE positionally — sudoers pins the exact command, no SETENV.
sudo /usr/local/bin/devcontainer-prepare.sh "$WORKTREE"

# 2. Wire apt through the proxy sidecar at runtime. Build-time apt (in the
#    base image's Dockerfile) used host network, so this isn't pre-baked.
#    Runtime apt (e.g. `playwright install --with-deps`) needs it.
sudo tee /etc/apt/apt.conf.d/01proxy >/dev/null <<'EOF'
Acquire::http::Proxy "http://proxy:8888";
Acquire::https::Proxy "http://proxy:8888";
EOF

cd "/work/${WORKTREE}"

# 3. rust-toolchain.toml in the workspace may pin a version different from the
#    base image's `stable` default; `rustup show` triggers an install of the
#    pinned toolchain on first invocation.
rustup show

# 4. Workspace npm deps (lands in the per-worktree node_modules named volume).
#    `npm ci` instead of `npm install` because the latter rewrites
#    package-lock.json based on the workspace directory name (/work/$WORKTREE
#    inside the container vs the bind-mount source on the host), which would
#    dirty the working tree.
npm ci

# 5. Playwright: install chromium plus its OS package deps in one shot.
#    Run as `vscode` (NOT prefixed with sudo) so the browser binary lands in
#    /home/vscode/.cache/ms-playwright. Playwright self-elevates internally to
#    sudo for the apt portion; the base image grants `vscode` passwordless
#    sudo, so this works without any extra sudoers entries.
npx playwright install --with-deps chromium
