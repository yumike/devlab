# rw personal devcontainer overlay

Sandboxed devcontainer for working on
[rwdocs/rw](https://github.com/rwdocs/rw) with Claude Code preinstalled.
Egress is locked down at the Docker network level: the dev container has no
route to the outside world and reaches the internet only via a tinyproxy
sidecar that allowlists by hostname. Built on top of the project's toolchain
(Rust 1.95, Node 20, gh, Playwright) but kept out of the project repo so other
contributors aren't paying for the extra capabilities and volumes.

## Architecture

```
┌─────────────────────────────┐         ┌────────────────────┐
│  dev (Ubuntu 24.04 +        │         │  proxy (alpine +   │
│       node, rust, gh,       │ ──CONNECT──▶│  tinyproxy)    │
│       claude code)          │         │                    │
│                             │         │  Hostname allowlist│
│  HTTPS_PROXY=http://proxy   │         │  in proxy/filter   │
└──────────┬──────────────────┘         └─────────┬──────────┘
           │                                      │
   ┌───────▼────────┐                    ┌───────▼────────┐
   │  internal:     │                    │  egress:       │
   │  internal=true │                    │  default       │
   └────────────────┘                    └────────────────┘
```

The dev container is attached only to the `internal:` network, which has
`internal: true` set so Docker installs no NAT/routing for it — there is
literally no path to the outside world. The proxy sits on both networks and
brokers requests, accepting only CONNECT/GET to hosts matching
`proxy/filter`.

## Usage

Install [devpod](https://devpod.sh) (`brew install devpod`), then from the
project workspace:

```bash
devpod up . --devcontainer-path ~/devcontainer-overlays/rw/devcontainer.json
```

Open in VS Code:

```bash
devpod up . --ide vscode --devcontainer-path ~/devcontainer-overlays/rw/devcontainer.json
```

devpod sets `LOCAL_WORKSPACE_FOLDER` for compose so the workspace bind-mount
resolves to the host project directory.

## Editing the allowlist

Hostnames live in `proxy/filter` (POSIX extended regex, anchored, one per
line). Comments start with `#`. To add a host:

```bash
echo '^example\.com$' >> ~/devcontainer-overlays/rw/proxy/filter
docker compose -f ~/devcontainer-overlays/rw/compose.yml restart proxy
```

Tail the proxy's denials to figure out what to add:

```bash
docker compose -f ~/devcontainer-overlays/rw/compose.yml logs -f proxy
```

A blocked request shows up as `Filtered connection ("...")` in the log.

## What's in the box

- `Dockerfile` — Ubuntu 24.04 base + build deps (gcc, pkg-config, libssl-dev),
  git, curl, ca-certs, zsh, fzf, less. apt is pre-configured to use the proxy
  at runtime.
- Devcontainer features: Node 20, Rust (minimal), GitHub CLI.
- `proxy/` — tinyproxy in alpine, hostname-allowlist filter.
- `compose.yml` — dev + proxy services, two networks, named volumes for
  cargo cache, target dir, node_modules, Claude config, bash history.
- `post-create.sh` — runs `rustup show`, installs `cargo-llvm-cov` /
  `cargo-edit`, `npm ci`, `claude.ai/install.sh`, `npx playwright install
  --with-deps chromium`. Everything goes through the proxy.
- `anthropic.claude-code` VS Code extension preinstalled.

## Caveats

- **HTTPS only.** The proxy only handles HTTP and HTTPS-via-CONNECT to ports
  80/443. SSH-based git URLs (`git@github.com:...`) won't work — use HTTPS
  remotes. Anything else (raw TCP, custom protocols) is dead.
- **Build-time is unsandboxed.** `docker compose build` uses the host network,
  so the base image, devcontainer features, and any `RUN apt-get ...` in the
  Dockerfile can reach anything. The sandbox is for runtime — including
  postCreate, so `claude.ai/install.sh` and `npx playwright install` are
  proxied.
- **Adding a host requires a proxy restart.** Editing `proxy/filter` and
  running `docker compose restart proxy` — the dev container keeps running.
- **Workspace credentials still readable.** The container bind-mounts the
  workspace, including any `private_key.pem` or `.env` files. Egress
  allowlisting prevents most exfil paths, but anything that can post to an
  allowlisted host (e.g. a gist or a GitHub issue) is still a possible
  channel. Don't mount host credentials (`~/.ssh`, cloud creds) into it.
- **Floating tags.** Base image (`mcr.microsoft.com/devcontainers/base:ubuntu-24.04`),
  `alpine:3.20`, and feature `:1` tags are not pinned by digest, so the build
  is "consistent" but not bit-reproducible across long time spans.

## Directory layout

```
~/devcontainer-overlays/rw/
├── README.md
├── compose.yml                # dev + proxy services, networks, volumes
├── devcontainer.json          # points to compose.yml, declares features + extensions
├── Dockerfile                 # dev container image
├── devcontainer-prepare.sh    # chowns named-volume mountpoints (called via sudo)
├── post-create.sh             # one-time setup: rustup, cargo, npm ci, claude, playwright
└── proxy/
    ├── Dockerfile             # alpine + tinyproxy
    ├── tinyproxy.conf         # listen on 8888, allowlist mode
    └── filter                 # hostname allowlist (regex, one per line)
```
