ARG VARIANT=ubuntu-24.04
FROM mcr.microsoft.com/devcontainers/base:${VARIANT}

# System deps: napi-rs build, devex.
# Playwright system deps are NOT installed here — `npx playwright install --with-deps`
# in post-create.sh installs the canonical set per Playwright version.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev \
    git curl ca-certificates zsh fzf less \
    && rm -rf /var/lib/apt/lists/*

# Configure apt to use the egress proxy at runtime. Written AFTER the build-time
# apt-get above intentionally — Docker build uses the host network so no proxy
# is needed during build; the dev container at runtime has no direct egress and
# every apt invocation (devcontainer features, playwright --with-deps, ad-hoc
# package installs) must go through the proxy sidecar.
RUN printf 'Acquire::http::Proxy "http://proxy:8888";\nAcquire::https::Proxy "http://proxy:8888";\n' \
    > /etc/apt/apt.conf.d/01proxy

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
