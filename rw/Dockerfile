ARG VARIANT=ubuntu-24.04
FROM mcr.microsoft.com/devcontainers/base:${VARIANT}

# System deps: napi-rs build, devex.
# Playwright system deps are NOT installed here — `npx playwright install --with-deps`
# in post-create.sh installs the canonical set per Playwright version.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev \
    git curl ca-certificates zsh fzf less \
    && rm -rf /var/lib/apt/lists/*

# NOTE: apt is NOT pointed at the proxy here. Devcontainer feature installs
# run as build-time RUN layers, where the proxy sidecar doesn't exist yet —
# baking the proxy config in would break feature installation. Build-time apt
# uses the host network (fine). Runtime apt (e.g. `playwright install
# --with-deps`) is wired to the proxy in post-create.sh once the sidecar is up.

# Helper scripts: COPY into a known absolute path so postCreate can invoke them
# without depending on the workspace.
COPY devcontainer-prepare.sh /usr/local/bin/devcontainer-prepare.sh
COPY post-create.sh          /usr/local/bin/rw-post-create.sh
RUN chmod +x /usr/local/bin/devcontainer-prepare.sh \
             /usr/local/bin/rw-post-create.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/devcontainer-prepare.sh" \
       > /etc/sudoers.d/devcontainer-helpers \
    && chmod 0440 /etc/sudoers.d/devcontainer-helpers \
    && visudo -cf /etc/sudoers.d/devcontainer-helpers

USER vscode
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup
