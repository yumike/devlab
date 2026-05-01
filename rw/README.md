# rw personal devcontainer overlay

Personal devcontainer for working on
[rwdocs/rw](https://github.com/rwdocs/rw) with Claude Code preinstalled and
an egress firewall on by default. Built on top of the project's toolchain
(Rust 1.95, Node 20, gh, Playwright) but kept out of the project repo so other
contributors aren't paying for the extra capabilities and volumes.

## Usage

Install [devpod](https://devpod.sh) (`brew install devpod`), then from the
project workspace:

```bash
# default: firewall on (sandboxed Claude session)
devpod up . --devcontainer-path ~/devcontainer-overlays/rw/devcontainer.json

# opt out of the firewall (e.g. to debug network issues)
RW_DEVCONTAINER_FIREWALL=0 \
  devpod up . --devcontainer-path ~/devcontainer-overlays/rw/devcontainer.json
```

Open in VS Code:

```bash
devpod up . --ide vscode --devcontainer-path ~/devcontainer-overlays/rw/devcontainer.json
```

## What's added on top of the project devcontainer

- `iptables`, `ipset`, `aggregate`, `dnsutils`, `jq` (firewall tooling)
- `init-firewall.sh` (allowlist for github, npm, crates.io, anthropic, kroki,
  playwright, vscode marketplace; see the script for the full list)
- `--cap-add=NET_ADMIN --cap-add=NET_RAW` (required for `iptables`)
- `RW_DEVCONTAINER_FIREWALL` env var passthrough (default `1` → firewall runs
  at every container start; set to `0` on the host to disable)
- Claude Code installed via `https://claude.ai/install.sh`
- Persistent named volume on `/home/vscode/.claude` so Claude auth survives
  rebuilds; persistent volume on `/commandhistory` for bash history
- `anthropic.claude-code` VS Code extension

## Caveats

- `NET_ADMIN`/`NET_RAW` are granted unconditionally — even when the firewall
  is off, the container has these caps. Live with it or add a non-firewall
  variant.
- `postCreateCommand` runs *before* the firewall (which only starts in
  `postStartCommand`), so the initial `claude.ai/install.sh` curl-pipe-bash
  always runs unfiltered. The firewall sandboxes subsequent Claude sessions,
  not the bootstrap.
- The container bind-mounts the workspace, including any `private_key.pem`
  (Confluence OAuth) or `.env` files. Don't run untrusted Claude prompts
  against this container without enabling the firewall, and don't mount
  host credentials (`~/.ssh`, cloud creds) into it.
- The base image (`mcr.microsoft.com/devcontainers/base:ubuntu-24.04`) and
  features (`:1`) are floating tags, so this is "consistent" but not
  bit-reproducible across long time spans.

## Directory layout

```
~/devcontainer-overlays/rw/
├── README.md
├── devcontainer.json        # extra mounts, runArgs, env, scripts
├── Dockerfile               # base + system deps + COPY scripts to /usr/local/bin
├── init-firewall.sh         # invoked by post-start when RW_DEVCONTAINER_FIREWALL=1
├── devcontainer-prepare.sh  # chowns the project + claude volumes (called via sudo)
├── post-create.sh           # one-time setup: rustup, cargo, npm ci, claude, playwright
└── post-start.sh            # per-start firewall toggle
```
