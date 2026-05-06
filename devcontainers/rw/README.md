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
                  ┌────────────────┐
                  │  traefik:      │
                  │  external      │
                  └───────┬────────┘
                          │ inbound HTTP
                          ▼
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

The dev container's outbound path is `internal:` only, which has
`internal: true` set so Docker installs no NAT/routing for it — there is
literally no outbound path to the outside world. Inbound HTTP comes in
over `traefik:`, an external network shared with the host-side Traefik
stack at `~/devlab/traefik/`; that direction doesn't bypass the egress
lockdown because outbound from `dev` still has to go through `proxy` via
`HTTP_PROXY`. The proxy sits on `internal:` and `egress:`, brokering
requests and accepting only CONNECT/GET to hosts matching `proxy/filter`.

## Access via `rw-<worktree>.test`

The dev container's primary port (7979) is reached at
`rw-<worktree>.test` (e.g. <http://rw-main.test>,
<http://rw-tables.test>) via the shared Traefik proxy at
`~/devlab/traefik/`. Each worktree gets its own host —
`<worktree>` is the `WORKTREE` value from the worktree's `.env`.
Bring the Traefik stack up before bringing the devcontainer up —
see `~/devlab/traefik/README.md` for the one-time `traefik`
network setup, then:

    cd ~/devlab/traefik
    docker compose up -d

If `rw-<worktree>.test` returns connection refused, Traefik isn't
running. If it returns 404, no devcontainer is up for that worktree
(or `WORKTREE` in its `.env` doesn't match the host you're hitting).
If it returns 502, Traefik is running and routing, but the dev
server inside the container isn't (start it with the usual project
command).

There are no `forwardPorts` for this overlay — Traefik is the only
path.

## Using Forgejo as the git remote

The rw dev container can use the shared Forgejo at
<http://forgejo.test> as its primary git remote (see
`~/devlab/forgejo/`). Bring that stack up first; if it isn't running,
clone/push from inside `dev` will fail with connection refused.

    cd ~/devlab/forgejo
    op run --env-file=.env -- docker compose up -d

Clone form (works from both the host and from inside `dev` —
same URL, same content, different network paths):

    git clone http://forgejo.test/<user>/<repo>.git

Push auth is via a Forgejo Personal Access Token. Create one at
**User Settings → Applications → Generate New Token** and store it
in 1Password. Inside `dev`:

    git config --global credential.helper store
    git push   # paste username + token when prompted; cached after

Or use a `~/.netrc` entry:

    machine forgejo.test
    login <user>
    password <PAT>

For CLI-driven PR / issue / release workflows, install
[`forgejo-cli`](https://codeberg.org/forgejo-contrib/forgejo-cli)
(binary name `fj`) — the Forgejo-contrib `gh`-equivalent for Forgejo,
with prebuilt Linux binaries on its releases page. Not preinstalled.

There is no SSH for git here: Forgejo has SSH disabled and the rw dev
container's tinyproxy doesn't speak SSH. Use HTTPS-style URLs.

## Layout: bare repo + sibling worktrees

This overlay assumes a **bare-repo + sibling-worktrees** layout on the host
so multiple worktrees can run in parallel containers without git-inside-
container breakage. The `.git` file in a worktree is a pointer (not a
directory) — naively bind-mounting only the worktree means git can't follow
the pointer to the shared object store and fails with "fatal: not a git
repository". Mounting the *parent* directory instead, with the bare repo
as a sibling, makes git Just Work.

```
~/projects/oss/rwdocs/rw/
├── bare.git/               ← bare repo (shared object store, all git data)
├── main/                   ← worktree on `main`
│   ├── .devcontainer ──→ ~/devlab/devcontainers/rw/
│   └── .env               (WORKTREE=main,   WORKTREE_PARENT=…/rw)
├── tables/                 ← worktree on e.g. `feat/tables`
│   ├── .devcontainer ──→ ~/devlab/devcontainers/rw/
│   └── .env               (WORKTREE=tables, WORKTREE_PARENT=…/rw)
└── <slug>/                 ← one dir per active branch
    └── …
```

**Slug rule for worktree dir names:** the `WORKTREE` value (= worktree dir
basename) is used as a path component (`/work/$WORKTREE`) and as part of
the Traefik host (`rw-$WORKTREE.test`). Keep it dash-separated and dot-free.
For branches with slashes, drop the prefix (`feat/tables` → `tables`) or
flatten with dashes (`feat-tables`); pick one convention and stick with it.

Each worktree is independent: its own container, its own `target/` and
`node_modules` named volumes, its own Traefik route at `rw-<worktree>.test`.
The cargo registry/git caches and Claude config are declared `external` in
`compose.yml` so they're shared across all worktrees.

### One-time host setup

Requires git ≥ 2.48 for `--relative-paths` (Jan 2025 release). Verify with
`git --version`.

```bash
mkdir -p ~/projects/oss/rwdocs/rw
cd ~/projects/oss/rwdocs/rw
git clone --bare https://github.com/rwdocs/rw.git bare.git
git -C bare.git worktree add --relative-paths ../main main
ln -s ~/devlab/devcontainers/rw main/.devcontainer
cat > main/.env <<EOF
WORKTREE=main
WORKTREE_PARENT=$PWD
EOF
for v in rw-cargo-registry rw-cargo-git rw-claude-config; do docker volume create "$v"; done
```

> Note: `~/projects/oss/rwdocs/rw/` may already exist as a regular checkout.
> Move it aside first (`mv rw rw.legacy`) and verify the new structure
> works before deleting the old one.

If you're migrating from a single-checkout layout, copy your existing
cargo cache contents into the new external volumes before deleting the
old containers:

```bash
# Adjust the source volume name based on `docker volume ls | grep cargo-registry`
docker run --rm \
  -v <old-volume>:/from -v rw-cargo-registry:/to \
  alpine sh -c 'cp -a /from/. /to/'
```

### Adding a new worktree

Pick a slug for the new worktree dir (matches the `WORKTREE` value below;
see slug rule in the layout section). Example uses `tables` for the
`feat/tables` branch.

```bash
cd ~/projects/oss/rwdocs/rw
git -C bare.git worktree add --relative-paths -b feat/tables ../tables main
ln -s ~/devlab/devcontainers/rw tables/.devcontainer
cat > tables/.env <<EOF
WORKTREE=tables
WORKTREE_PARENT=$PWD
EOF
```

`WORKTREE_PARENT` is the absolute host path of `rw/`; the container
bind-mounts it at `/work` so the worktree's relative `gitdir:` pointer
resolves into the bare repo. We use a dedicated env var (rather than
devpod's `LOCAL_WORKSPACE_FOLDER`) because `--workspace-env-file=.env`
replaces devpod's auto-set environment.

### Bringing the worktree's container up

Install [devpod](https://devpod.sh) (`brew install devpod`) once.

```bash
cd ~/projects/oss/rwdocs/rw/tables
devpod up . --id rw-tables \
  --workspace-env-file=.env \
  --devcontainer-path .devcontainer/devcontainer.json
```

- `--workspace-env-file=.env` makes `${WORKTREE}` and `${WORKTREE_PARENT}`
  substitute in `compose.yml` (drive Traefik host, volume names, bind-mount
  source) and `${WORKTREE}` in `devcontainer.json`'s `workspaceFolder`
  (`/work/${WORKTREE}`).
- `--id rw-tables` gives this devpod workspace a stable name so `devpod list`
  is readable across many worktrees.

With VS Code:

```bash
devpod up . --id rw-tables \
  --workspace-env-file=.env \
  --ide vscode \
  --devcontainer-path .devcontainer/devcontainer.json
```

To rebuild from scratch (after editing `compose.yml` or `Dockerfile`):

```bash
devpod up . --recreate --id rw-tables \
  --workspace-env-file=.env \
  --devcontainer-path .devcontainer/devcontainer.json
```

To delete a worktree's workspace (won't touch the worktree dir or git data):

```bash
devpod delete rw-tables
git -C ~/projects/oss/rwdocs/rw/bare.git worktree remove ../tables
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
- `compose.yml` — dev + proxy services, two networks, parameterized by
  `${WORKTREE}` so each worktree gets its own compose project, Traefik
  route, and per-worktree `target` / `node_modules` / `bash-history`
  volumes. Cargo registry/git and Claude config are external volumes
  shared across worktrees.
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
- **Sibling worktrees are visible.** Because the parent `rw/` is
  bind-mounted at `/work` (so git can resolve the worktree's `.git`
  pointer), the container can read other worktrees' files at
  `/work/<other>` and the bare repo at `/work/bare.git`. `workspaceFolder`
  keeps you scoped to one, but tooling that walks upward will see siblings.
  Don't put per-worktree secrets in one worktree expecting another not to
  see them.
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
