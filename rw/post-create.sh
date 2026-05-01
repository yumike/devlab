#!/usr/bin/env bash
set -euo pipefail

# Defensive PATH — devpod's lifecycle hook runner doesn't reliably propagate
# the PATH set in compose.yml's `environment:` block, so /usr/local/cargo/bin
# (rustup, cargo) and /usr/local/share/nvm/current/bin (node, npm, npx) end
# up missing from PATH when this script runs. Hardcode here so each step can
# find the tools the prior step just installed.
export PATH="/home/vscode/.local/bin:/usr/local/cargo/bin:/usr/local/share/nvm/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 1. Fix ownership of named-volume mount points (root-owned by default)
sudo /usr/local/bin/devcontainer-prepare.sh

# 2. Wire apt through the proxy sidecar at runtime. We can't do this in the
#    Dockerfile because devcontainer features run as build-time RUN layers
#    (before the proxy is up), and pre-baking the proxy config would break
#    their apt-get calls. By the time post-create runs, the proxy is healthy.
sudo tee /etc/apt/apt.conf.d/01proxy >/dev/null <<'EOF'
Acquire::http::Proxy "http://proxy:8888";
Acquire::https::Proxy "http://proxy:8888";
EOF

cd /workspace

# 3. Bootstrap rustup if the cargo-cache volume shadowed it.
#    The rw-cargo-cache volume mounts at /usr/local/cargo. Docker copies the
#    image's /usr/local/cargo contents into a brand-new volume (preserving
#    rustup from the rust feature's build-time install), but on a re-used
#    empty volume (e.g. left behind by an earlier failed build) that copy
#    doesn't happen and rustup goes missing. Detect and reinstall — the
#    /usr/local/rustup toolchain dir is not volume-mounted so toolchains
#    installed at build time are still there.
if ! command -v rustup >/dev/null 2>&1; then
    echo "[post-create] rustup missing (cargo-cache volume shadowed it); bootstrapping..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --no-modify-path --default-toolchain none
fi

# 4. rust-toolchain.toml triggers rustup to install 1.95.0 lazily; make it
#    explicit so install errors surface here rather than at first cargo build
rustup show

# 5. cargo-llvm-cov needs the llvm-tools-preview component
rustup component add llvm-tools-preview

# 6. Cargo dev tools (lands in rw-cargo-cache volume, persists across rebuilds)
cargo install --locked cargo-llvm-cov cargo-edit

# 7. Node deps (lands in rw-node-modules volume).
#    `npm ci` instead of `npm install` because the latter rewrites
#    package-lock.json based on the workspace directory name (/workspace inside
#    the container vs the bind-mount source on the host), which would dirty
#    the working tree.
npm ci

# 8. Claude Code CLI via the official installer.
#    Direct install rather than the claude-code devcontainer feature: that
#    feature ships its own conflicting init-firewall.sh into /usr/local/bin/.
curl -fsSL https://claude.ai/install.sh | bash

# 9. Playwright: install chromium plus its OS package deps in one shot.
#    Covers both `chromium` and `chromium-embedded` projects (same browser binary).
#    Run as `vscode` (NOT prefixed with sudo) so the browser binary lands in
#    /home/vscode/.cache/ms-playwright. Playwright self-elevates internally to
#    sudo for the apt portion; the base image grants `vscode` passwordless sudo,
#    so this works without any extra sudoers entries.
npx playwright install --with-deps chromium
