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

Install [devpod](https://devpod.sh) (`brew install devpod`).

devpod resolves `--devcontainer-path` *relative to the workspace folder*
even when you pass an absolute path, so the overlay needs a foothold
inside the project tree. One-time setup per project:

```bash
cd ~/projects/oss/rwdocs/rw                              # the actual code workspace
ln -s ~/devlab/devcontainers/rw .devcontainer-rw    # symlink the overlay in
echo '.devcontainer-rw' >> .git/info/exclude        # keep it out of git, locally
```

Then bring the workspace up:

```bash
devpod up . --devcontainer-path .devcontainer-rw/devcontainer.json
```

Or with VS Code:

```bash
devpod up . --ide vscode --devcontainer-path .devcontainer-rw/devcontainer.json
```

devpod sets `LOCAL_WORKSPACE_FOLDER` to the project directory (not the
overlay) for compose substitution, so the dev container's `/workspace`
binds to the actual code. The symlink only routes devpod to the overlay's
`devcontainer.json` + `compose.yml` + `proxy/` files.

If you need to rebuild from scratch (e.g. you've edited `compose.yml` or
`Dockerfile`):

```bash
devpod up . --recreate --devcontainer-path .devcontainer-rw/devcontainer.json
```

If a workspace is stuck in a bad state (e.g. previous run failed mid-up):

```bash
devpod list
devpod delete <name>
```

## Editing the allowlist

Hostnames live in `proxy/filter` (POSIX extended regex, anchored, one per
line). Comments start with `#`. To add a host:

```bash
echo '^example\.com$' >> ~/devlab/devcontainers/rw/proxy/filter
docker compose -f ~/devlab/devcontainers/rw/compose.yml restart proxy
```

Tail the proxy's denials to figure out what to add:

```bash
docker compose -f ~/devlab/devcontainers/rw/compose.yml logs -f proxy
```

A blocked request shows up as `Filtered connection ("...")` in the log.

## What's in the box

- `Dockerfile` — thin overlay on top of
  [`ghcr.io/yumike/devcontainer-base-image`](https://github.com/yumike/devcontainer-base-image),
  which already contains Ubuntu 24.04 + apt build deps, rustup with the
  default toolchain + clippy/rustfmt/llvm-tools, `cargo-llvm-cov`,
  `cargo-edit`, Node via nvm, `gh`, and Claude Code. The overlay just adds
  rw-specific helper scripts and the sudoers entry for the prepare script.
- `proxy/` — tinyproxy in alpine, hostname-allowlist filter.
- `compose.yml` — dev + proxy services, two networks, named volumes for the
  cargo registry / git caches, target dir, node_modules, Claude config,
  bash history.
- `post-create.sh` — runs `rustup show` (resolves any rust-toolchain.toml
  in the workspace), `npm ci`, `npx playwright install --with-deps
  chromium`. Heavy installs are baked into the base image so postCreate is
  fast.
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
- **Floating tags.** The personal base image is pulled by `:latest` (which
  rebuilds weekly via cron) and `alpine:3.20` for the proxy. Pin
  `BASE_TAG=YYYY-MM-DD` (or a `@sha256:` digest) in the dev `Dockerfile`
  via `--build-arg` if you want bit-reproducibility.

## Directory layout

```
~/devlab/devcontainers/rw/
├── README.md
├── compose.yml                # dev + proxy services, networks, volumes
├── devcontainer.json          # points to compose.yml, declares VS Code extensions
├── Dockerfile                 # thin overlay on the personal base image
├── devcontainer-prepare.sh    # chowns named-volume mountpoints (called via sudo)
├── post-create.sh             # one-time setup: rustup show, npm ci, playwright install
└── proxy/
    ├── Dockerfile             # alpine + tinyproxy
    ├── tinyproxy.conf         # listen on 8888, allowlist mode
    └── filter                 # hostname allowlist (regex, one per line)
```
