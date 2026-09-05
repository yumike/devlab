# syntax=docker/dockerfile:1.27

# Thin overlay on top of the personal base image. Everything heavy
# (apt deps, rustup, node via nvm, gh, cargo-llvm-cov, cargo-edit, claude
# code) is baked into the base at GHA build time — this Dockerfile just
# adds the rw-specific helper scripts and sudoers entry.
ARG BASE_TAG=latest
FROM ghcr.io/yumike/devcontainer-base-image:${BASE_TAG}

USER root
COPY devcontainer-prepare.sh /usr/local/bin/devcontainer-prepare.sh
COPY post-create.sh          /usr/local/bin/rw-post-create.sh
RUN chmod +x /usr/local/bin/devcontainer-prepare.sh \
             /usr/local/bin/rw-post-create.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/devcontainer-prepare.sh" \
       > /etc/sudoers.d/devcontainer-helpers \
    && chmod 0440 /etc/sudoers.d/devcontainer-helpers \
    && visudo -cf /etc/sudoers.d/devcontainer-helpers
USER vscode
