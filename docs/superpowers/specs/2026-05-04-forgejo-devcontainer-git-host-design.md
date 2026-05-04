# Design: Forgejo as the devcontainer git host

**Status:** Proposed
**Date:** 2026-05-04
**Scope:** Add a shared, host-side Forgejo stack to `~/devlab/forgejo/` (Forgejo + Postgres) routed through the existing Traefik proxy at `forgejo.test`, and wire the rw devcontainer overlay so Claude Code inside it can use Forgejo as the git remote instead of github.com (or any other public git host).

## Problem

The rw devcontainer's egress is locked down: outbound HTTP/HTTPS goes through tinyproxy with a hostname allowlist. Today the canonical git host for projects worked on inside it (e.g. `rwdocs/rw`) is github.com — public, third-party, and external to the laptop. We want a private git host running locally on the laptop so that:

- Code, branches, and PRs stay on the device by default.
- The dev container talks to the git host over the Docker network, with no dependency on the public internet for git operations.
- Adding more devcontainer overlays in the future doesn't require giving each one its own github.com presence.

A shared Forgejo instance reachable at `forgejo.test` (over the existing Traefik routing convention) gives us this without inventing new infrastructure.

## Goals

- One Forgejo instance shared across all devlab devcontainer overlays, reachable at `http://forgejo.test` from both the host browser and from inside any overlay's dev container.
- Persistent storage for repos and Postgres data across `docker compose down`/`up` and host reboots.
- Postgres is fully isolated from the host and from devcontainer overlays — only the Forgejo container can reach it.
- The rw overlay's existing egress lockdown (tinyproxy on `internal:`/`egress:`) is preserved unchanged. Forgejo traffic does not pass through tinyproxy and does not require an allowlist entry.
- New overlays can use Forgejo by following the same Traefik convention they already follow; nothing Forgejo-specific is required of them.

## Non-goals

- HTTPS / certificates. HTTP-only on `*.test`, matching the Traefik design.
- HTTP/HTTPS proxying *into* the Docker network. The Mac-side dnsmasq prerequisite (wildcard `*.test` → `127.0.0.1`) is a one-time host setup, documented in `~/devlab/traefik/README.md`. Without it, browsers and CLIs on the Mac get NXDOMAIN for `*.test`. With it, every `*.test` name resolves cleanly across all clients on the Mac (browsers, curl, native tools).
- SSH for git. Forgejo can serve SSH on a published port; we skip it because the rw overlay is HTTP-only by design (tinyproxy doesn't speak SSH) and an extra published port adds surface area for no current benefit.
- Forgejo Actions / CI runners. Adding a runner is a separate, additive change.
- Pull-mirroring from github.com. If/when we want a synced copy of an existing GitHub repo, we'll add a mirror configuration per-repo through Forgejo's UI or API.
- Multi-user / organizations / federation. Single-user, single-laptop only.
- LFS. Not configured. `LFS_JWT_SECRET` not set.
- Auth on the Traefik dashboard, loopback-only port binding, etc. — same trigger as the Traefik design.
- Migrating existing rw repo state to Forgejo. The infra is in place after this change; the actual `git remote set-url` for `rwdocs/rw` is a separate, manual operation.

## Architecture

```
                                   Mac host
   ┌──────────────────────────────────────────────────────────────────────┐
   │ browser hits forgejo.test                                            │
   │              ↓ (dnsmasq wildcard *.test → 127.0.0.1)                 │
   │         Traefik :80 (published)                                      │
   └──────────────────────┬───────────────────────────────────────────────┘
                          │  Docker network: traefik (external)
        ┌─────────────────┼──────────────────────┐
        │                 │                      │
   ┌────▼─────┐   ┌───────▼─────────────┐   ┌────────▼─────────────┐
   │ traefik  │   │  forgejo            │   │ rw dev (already on   │
   │          │   │  (declares alias    │   │ traefik for inbound) │
   │          │   │   forgejo.test │   │                      │
   │          │   │   on `traefik:`)    │   │                      │
   └──────────┘   └───────┬─────────────┘   └────────┬─────────────┘
                          │                     │
                          │ forgejo stack's     │ rw stack's
                          │ internal: (private) │ internal: (private)
                          │                     │
                     ┌────▼─────┐         ┌────▼─────────┐
                     │   db     │         │  proxy       │
                     │  (pg18)  │         │  (tinyproxy) │
                     └──────────┘         └──────────────┘
```

- A new shared compose stack at `~/devlab/forgejo/` runs **two** services: `forgejo` (the server) and `db` (Postgres 18). Each devcontainer overlay's `internal:` network is stack-local; the `db` is reachable only by the `forgejo` container in its own stack.
- `forgejo` joins both `internal:` (to reach `db`) and the external `traefik:` network (for inbound HTTP routing) — same shape as the rw `dev` service.
- `forgejo` declares a Docker network alias `forgejo.test` on the `traefik:` network. Containers on `traefik:` (e.g. rw's `dev`) resolve `forgejo.test` directly to Forgejo's container IP via Docker's internal DNS — no Traefik hop. From the host browser, the same hostname resolves via Mac-side dnsmasq (wildcard `*.test` → `127.0.0.1`), reaches Traefik on port 80, which routes to Forgejo by Host header. **The result: the same URL `http://forgejo.test` works in both contexts.** This wouldn't work with `*.localhost` because glibc 2.34+ hardcodes `*.localhost` to `127.0.0.1`/`::1` *before* consulting NSS, Docker DNS, or `/etc/hosts` — making Docker DNS aliases on `*.localhost` unreachable from libc-based clients (curl, git) inside containers. `*.test` is RFC 6761-reserved for testing but not loopback-hardcoded, so Docker DNS aliases work normally. The dnsmasq prerequisite on the Mac is the cost of admission.
- For the alias-on-port-80 path to work, Forgejo binds port **80** internally (not its 3000 default). Forgejo's image runs as the non-root `git` user; binding <1024 is enabled with the per-container sysctl `net.ipv4.ip_unprivileged_port_start=0`.
- The rw overlay's `internal:` and `egress:` networks are untouched. The egress lockdown is unchanged. The only rw delta is `.test` added to `NO_PROXY`/`no_proxy` so libcurl/git inside `dev` skips tinyproxy for `*.test` hostnames (otherwise it would try to forward via the proxy, which can't reach Forgejo because tinyproxy is on `internal:`/`egress:`, not `traefik:`).

### Why dev → Forgejo bypasses Traefik

A deliberate choice, not an oversight. To make `forgejo.test` resolve from inside the dev container, some service on a network the dev container is attached to must claim that name. Docker aliases are declared by the service that wants to be findable, so:

- **Forgejo claims the alias** (chosen): each overlay owns its own hostname. Traefik stack stays oblivious to specific overlays — preserves the rule from `~/devlab/traefik/README.md`. Dev → Forgejo direct, one fewer hop.
- **Traefik claims the alias** (rejected): would require listing every overlay's hostname in `traefik/compose.yml`, centralizing knowledge that the design explicitly pushes to overlays.
- **In-cluster DNS sidecar with wildcard** (rejected): bigger machinery than per-service aliases for the same outcome.

(The Mac-side dnsmasq is a separate, host-level concern — it gives the browser a way to find `*.test` at all. Docker DNS handles the in-container path independently.)

What's lost by bypassing Traefik on this hop? Nothing functional. Traefik isn't doing auth, rate-limiting, or routing transformations — just Host-based dispatch. From the host browser, traffic still goes through Traefik (the host has no Docker DNS), so Traefik remains the single ingress for *external* traffic. The alias short-circuits *intra-Docker* traffic only.

## Components

### New: `~/devlab/forgejo/`

```
~/devlab/forgejo/
├── compose.yml      # forgejo + db services, two networks, two named volumes
├── .env.example     # committed; documents required vars (FORGEJO_DB_PASSWORD)
└── README.md        # start/stop, .env bootstrap, first-run admin user, smoke tests, gotchas
```

`.env` (real file with the password) is gitignored at the repo root — see "New: `~/devlab/.gitignore`" below. `~/devlab/` is published on GitHub, so secrets must not live in tracked files.

`compose.yml` (sketch — exact text in the implementation plan):

```yaml
name: forgejo

services:
  forgejo:
    image: codeberg.org/forgejo/forgejo:15
    environment:
      FORGEJO__server__HTTP_PORT: 80
      FORGEJO__server__DOMAIN: forgejo.test
      FORGEJO__server__ROOT_URL: http://forgejo.test/
      FORGEJO__server__SSH_DOMAIN: forgejo.test
      FORGEJO__server__DISABLE_SSH: "true"
      FORGEJO__database__DB_TYPE: postgres
      FORGEJO__database__HOST: db:5432
      FORGEJO__database__NAME: forgejo
      FORGEJO__database__USER: forgejo
      FORGEJO__database__PASSWD: ${FORGEJO_DB_PASSWORD:?run via op run --env-file=.env}
      FORGEJO__security__INSTALL_LOCK: "true"
    sysctls:
      - net.ipv4.ip_unprivileged_port_start=0
    volumes:
      - forgejo-data:/data
    networks:
      internal:
      traefik:
        aliases:
          - forgejo.test
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik
      - traefik.http.routers.forgejo.rule=Host(`forgejo.test`)
      - traefik.http.services.forgejo.loadbalancer.server.port=80
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  db:
    image: postgres:18
    environment:
      POSTGRES_DB: forgejo
      POSTGRES_USER: forgejo
      POSTGRES_PASSWORD: ${FORGEJO_DB_PASSWORD:?run via op run --env-file=.env}
    volumes:
      # PG18+ expects the parent path; legacy /var/lib/postgresql/data
      # makes the entrypoint refuse to start. See Operational notes.
      - forgejo-db:/var/lib/postgresql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U forgejo -d forgejo"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 10s
    restart: unless-stopped

networks:
  internal:
    internal: true
  traefik:
    name: traefik
    external: true

volumes:
  forgejo-data:
  forgejo-db:
```

Notes on the choices encoded above:

- **Image tags**: floating-major (`forgejo:15`, `postgres:18`) — matches the Traefik stack's `v3.6` pattern. README documents pinning to a specific patch (`:15.0.1`) or `@sha256:` digest if bit-reproducibility becomes important.
- **Port 80 inside the container**: enables symmetric URLs (browser & dev container both use `http://forgejo.test`). The `sysctls` line allows the non-root `git` user (UID 1000) to bind <1024.
- **`INSTALL_LOCK=true`** with all DB / domain / URL settings pre-populated via env: skips Forgejo's install wizard. Admin user creation is a one-time CLI step (see Operational notes).
- **Postgres password is sourced from 1Password** via the `op` CLI. `forgejo/.env` (gitignored) holds a 1Password secret reference like `FORGEJO_DB_PASSWORD=op://Personal/Forgejo Devlab/password`. Bringing the stack up is `op run --env-file=.env -- docker compose up -d` — `op run` resolves the reference, sets the env var, and execs compose. Compose interpolates `${FORGEJO_DB_PASSWORD:?run via op run --env-file=.env}` into both services; the `:?` form fails loudly if `op run` was forgotten. The real password never lives on disk in cleartext; only the 1Password reference does. `~/devlab/` is on public GitHub, but `.env` is gitignored anyway so vault structure (`Personal/Forgejo Devlab/...`) doesn't leak.
- **No SSH**: `FORGEJO__server__DISABLE_SSH=true`; no SSH port published.

`.env.example` (committed, references-only template):

```
# Copy to .env (gitignored) and replace <your-vault> with your 1Password vault.
# Setup:
#   1. In 1Password, add a Login or Password item ("Forgejo Devlab")
#      with a generated password (32+ chars).
#   2. Right-click the password field → Copy Secret Reference.
#   3. Paste here as the value of FORGEJO_DB_PASSWORD.
# Bring the stack up with:
#   op run --env-file=.env -- docker compose up -d
FORGEJO_DB_PASSWORD="op://<your-vault>/Forgejo Devlab/password"
```

The real `.env` is created on first-run setup by the user; see Operational notes. 1Password references are not secrets per se (they identify a vault path), but `.env` stays gitignored anyway so vault names don't leak.

### New: `~/devlab/.gitignore`

A repo-root `.gitignore` is added as part of this change (none exists today). Initial contents:

```
.env
.env.local
```

Repo-root rather than per-stack so the same pattern works for any future stack that needs secrets. Patterns are kept minimal — adding broader entries (build artifacts, editor files) is out of scope here.

### Changed: `~/devlab/devcontainers/rw/compose.yml`

One delta on the `dev` service: extend `NO_PROXY` and `no_proxy` to include `.test`.

```yaml
NO_PROXY: localhost,127.0.0.1,proxy,.local,.test
no_proxy: localhost,127.0.0.1,proxy,.local,.test
```

Without this, libcurl-based clients (git, curl) inside `dev` would route `http://forgejo.test/...` through `HTTP_PROXY=http://proxy:8888`. Tinyproxy can't reach Forgejo (it's on `egress:`, not `traefik:`), and `proxy/filter` wouldn't allow `forgejo.test` even if reachable — both conditions fail, so the request fails. Adding `.test` to the no-proxy list makes the dev container skip the proxy entirely for `*.test` hostnames; libcurl suffix-matches the leading-dot entry against `forgejo.test`, `traefik.test`, and any future `*.test` overlay — which is what we want.

No change to `proxy/filter` (tinyproxy allowlist). Forgejo traffic does not pass through tinyproxy.

### Changed: `~/devlab/devcontainers/rw/README.md`

A short "Using Forgejo as the git remote" section:

- Bring up `~/devlab/forgejo/` first (`docker compose up -d`).
- Clone URL form: `http://forgejo.test/<user>/<repo>.git`.
- Push auth: create a Personal Access Token in Forgejo's UI (User Settings → Applications), then either store via `git credential.helper=store` once or set `~/.netrc`.
- For CLI-driven PR / issue / release workflows, install [`forgejo-cli`](https://codeberg.org/forgejo-contrib/forgejo-cli) (binary name `fj`) inside the dev container — it's the Forgejo-contrib `gh`-equivalent for Forgejo, with prebuilt Linux binaries on its releases page. Not preinstalled. The `forgejo` binary's [CLI](https://forgejo.org/docs/next/admin/command-line/) is server-side admin only (runs inside the server container; we use it via `docker compose exec` for user creation), not a client.

## Operational notes

These get baked into `~/devlab/forgejo/README.md`.

**Prerequisites.** The 1Password CLI (`op`, version ≥ 2.x) installed on the host (`brew install --cask 1password-cli`) and signed into your account (`eval "$(op signin)"`). Touch ID-based unlock works fine; CLI-only unlock works too.

**Postgres 18+ volume mount path.** The `db` volume is mounted at `/var/lib/postgresql` (parent), not the legacy `/var/lib/postgresql/data`. Postgres 18+ uses major-version-specific subdirectories so `pg_upgrade --link` doesn't cross mount boundaries. The legacy path makes the PG18 entrypoint refuse to start with an upgrade-suggestion error.

**Forgejo 15 `--must-change-password` default-true gotcha.** `forgejo admin user create` defaults `--must-change-password` to true, and when set, also silently fails to apply the `--password` value, leaving the account in a no-password state that breaks basic-auth login. Always pass `--must-change-password=false` explicitly when bootstrapping admin users whose password is canonical in 1Password.

**First-run setup.** Four steps:

```bash
# 1. In 1Password (app or CLI), add a Login/Password item named "Forgejo Devlab"
#    with a generated 32+ char password. Right-click the password → Copy Secret Reference.

# 2. Set up forgejo/.env from the template:
cd ~/devlab/forgejo
cp .env.example .env
$EDITOR .env  # paste the secret reference, replacing op://<your-vault>/...

# 3. Bring up the stack with op resolving the reference:
op run --env-file=.env -- docker compose up -d

# 4. Create the first admin user (see below).
```

If `.env` is missing, `FORGEJO_DB_PASSWORD` is empty, or `op run` is omitted, `docker compose up` fails with `error while interpolating … run via op run --env-file=.env` from the `:?` substitution — loud and unambiguous. If the 1Password reference is wrong (typo'd vault, item not found), `op run` fails before compose is invoked, also loud.

**Daily operation.** `op run --env-file=.env --` is required for any command that recreates containers (`up`, `down && up`, `pull` followed by `up -d`). Containers with `restart: unless-stopped` survive Docker Desktop restarts and host reboots without re-resolving the reference, so the `op run` prefix is rarely needed in steady state. A shell alias smooths the rare cases:

```bash
alias dcf='op run --env-file=.env -- docker compose'
```

Plain `docker compose ps`, `logs`, `exec`, `stop`, `start` (without recreate) work fine without `op run` — env vars are baked into existing container metadata.

With `INSTALL_LOCK=true` and DB/URL config pre-set via env, Forgejo skips the install wizard. `SECRET_KEY` and `INTERNAL_TOKEN` are auto-generated on first start and persisted to `app.ini` inside the `forgejo-data` volume; wiping that volume causes Forgejo to generate new ones on the next start, invalidating existing 2FA secrets and active sessions. The first admin user is created via:

```bash
ADMIN_PW="$(op read 'op://devlab/forgejo-admin/password')" \
  docker compose exec -T --user git -e ADMIN_PW="$ADMIN_PW" forgejo \
    sh -c 'forgejo admin user create \
      --username yumike \
      --password "$ADMIN_PW" \
      --email mike.yumatov@gmail.com \
      --admin \
      --must-change-password=false'
unset ADMIN_PW
```

`--user git` because Forgejo refuses to run as root. `--must-change-password=false` because the help text's default is true (with the side effect that it also silently drops the `--password` value). The transient env var keeps the password out of shell history and `ps` argv. The admin password is canonical in 1Password — forcing first-login rotation would just stale that item.

**Postgres password is sourced from 1Password.** No cleartext secret on the host's user-visible filesystem. `forgejo/.env` (gitignored) holds only an `op://` reference; `op run --env-file=.env -- docker compose ...` resolves it at startup. The resolved password ends up in Docker's container metadata (`/var/lib/docker/containers/<id>/config.v2.json` inside the Docker Desktop VM) — that's true of any compose-env approach short of Docker swarm secrets / `_FILE` env vars. The threat model here is GitHub leakage and casual filesystem inspection; both are addressed. Future stacks should follow the same `.env` (gitignored, references) + `.env.example` (committed, template) + `op run --env-file=.env --` pattern.

**Backups.** The two named volumes are the entire state.

```bash
# back up
docker run --rm -v forgejo_forgejo-data:/d -v "$PWD":/o alpine tar -czf /o/forgejo-data.tgz -C /d .
docker run --rm -v forgejo_forgejo-db:/d   -v "$PWD":/o alpine tar -czf /o/forgejo-db.tgz   -C /d .

# restore: stop stack, recreate empty volumes, untar back into place, start.
```

Compose namespaces volumes under the project name (`name: forgejo`), so the bare `forgejo-data` / `forgejo-db` from `compose.yml`'s `volumes:` block are exposed to `docker run`/`docker volume` as `forgejo_forgejo-data` / `forgejo_forgejo-db`. Using the unprefixed names with `docker run -v` would silently create new empty volumes — the README backup section calls this out explicitly.

Stop the stack before backing up `forgejo_forgejo-db` (Postgres) to avoid a torn snapshot. `forgejo_forgejo-data` can usually be backed up live; for paranoid backups, stop the stack.

**`forgejo:15` and `postgres:18` are floating tags.** README documents the pin-for-reproducibility escape hatch — replace with `:15.0.1` / `:18.3` or `@sha256:...`.

**Failure modes.**
- **Forgejo down, Postgres up**: `http://forgejo.test/` returns 502 from the host (Traefik, no backend); from rw `dev` the Docker DNS for `forgejo.test` either still resolves (alias persists per network membership) and connects refused, or stops resolving if the container is gone.
- **Postgres down, Forgejo up**: Forgejo logs DB connection errors; the UI returns 500. `depends_on: db: condition: service_healthy` ordering means Forgejo won't start until DB is ready, so this only happens if DB falls over mid-flight.
- **Traefik down**: host browser gets connection refused on `forgejo.test`. rw `dev` is unaffected (it doesn't go through Traefik).
- **`traefik` external network missing**: `docker compose up` fails with "network traefik declared as external, but could not be found". Recovery: `docker network create traefik` (one-line in the Traefik stack's README).

**`.test` in `NO_PROXY` is a blanket skip.** Any future `*.test` overlay automatically bypasses tinyproxy from inside the rw dev container. That's what we want — these are all our own services on the `traefik:` network — but flagging it as an explicit consequence of the change.

**SSH for git is disabled.** If a future need surfaces (e.g. a tool that doesn't speak HTTP-with-PAT), enabling SSH means setting `FORGEJO__server__DISABLE_SSH=false`, picking a host port (e.g. `2222:22`), publishing it, and updating the rw overlay (which currently can't reach external SSH because tinyproxy doesn't proxy raw TCP). Out of scope.

**No `forwardPorts` for Forgejo.** Same convention as rw: Traefik is the path. Browser uses `http://forgejo.test`. If Traefik is down, recovery is `cd ~/devlab/traefik && docker compose up -d`.

## Acceptance criteria

These also live in `~/devlab/forgejo/README.md` as a smoke-test section.

**Forgejo stack alone**

0. `.env` is created from `.env.example` and `FORGEJO_DB_PASSWORD` is set to a working `op://` reference. `git status` shows `.env` as ignored (not in the untracked list). `op read "$FORGEJO_DB_PASSWORD"` (after sourcing the file) returns the resolved password without error.
1. `cd ~/devlab/forgejo && op run --env-file=.env -- docker compose up -d` brings both `forgejo` and `db` up. `db` reaches `healthy` first; `forgejo` starts after.
2. `docker compose logs forgejo` shows no errors. The first start logs note that `app.ini` was generated and `SECRET_KEY`/`INTERNAL_TOKEN` were written.
3. `curl -sv http://forgejo.test/` returns 200 (HTML containing "Forgejo"). The Forgejo dashboard / login page renders in a browser.
4. `forgejo admin user create` (run via the hardened invocation in `~/devlab/forgejo/README.md` step 5 — `--user git`, transient `ADMIN_PW` env var, `--must-change-password=false`) succeeds; login works in the browser.
5. From the host: `git clone http://forgejo.test/yumike/<seed-repo>.git` succeeds (after creating a seed repo via the UI and a PAT).
6. `docker compose down && op run --env-file=.env -- docker compose up -d` cycles cleanly. The seed repo and admin user survive. (The `op run` is required on the `up` half — `:?` interpolation re-runs on every `up`, so a bare `docker compose up -d` would fail loudly without it.)

**Postgres isolation**

1. From inside the `forgejo` container: `nc -z db 5432` succeeds. (The forgejo image is alpine-based and doesn't ship `pg_isready`/`psql`; `nc` is enough to confirm the TCP path.)
2. From the host: `nc -z localhost 5432` fails (no published port).
3. From the rw `dev` container: `getent hosts db` does not resolve (the rw stack's `internal:` and the forgejo stack's `internal:` are separate Docker networks). `curl http://db:5432/` fails at name resolution, not at TCP — there is no Docker DNS entry to find.

**rw overlay end-to-end**

1. With Forgejo and Traefik up, and `.test` added to `NO_PROXY`/`no_proxy`, `devpod up . --devcontainer-path .devcontainer-rw/devcontainer.json --recreate` succeeds.
2. From inside `dev`: `curl -sv http://forgejo.test/` returns 200, fetched directly (no `Via:` header, since it didn't traverse tinyproxy).
3. From inside `dev`: `git clone http://forgejo.test/yumike/<seed-repo>.git` succeeds. `git push` (with PAT in `~/.netrc` or via credential helper) succeeds.
4. Same URL `http://forgejo.test/yumike/<seed-repo>.git` works in both browser-on-host and inside `dev`.

**Egress lockdown regression check**

1. Inside `dev`: `curl -v https://example.com` → blocked by tinyproxy (existing allowlist behavior, unchanged).
2. `curl -v https://github.com` → succeeds (allowlisted, unchanged).
3. `getent hosts proxy` resolves to an `internal:` address (rw stack's `internal`, not forgejo's). Confirms the existing dev↔proxy path on rw `internal:` survived the `NO_PROXY` change.

**Negative tests**

1. Stop Forgejo (`docker compose down` in `~/devlab/forgejo/`); from host browser, `http://forgejo.test/` returns 502 (Traefik, no backend). From rw `dev`, `curl http://forgejo.test/` returns connection refused. Bring it back; works again.
2. Stop Traefik; from host, `http://forgejo.test/` connection refused. From rw `dev`, still works (alias-based path is unaffected by Traefik state).
3. Bring up the forgejo stack without first creating the `traefik` network — compose fails with "external network not found". Failure is loud, not silent.
4. Bring up the forgejo stack without the `op run` prefix — `docker compose up -d` (no env from `op run`) fails with the `:?` interpolation error message. No containers start. Loud, not silent. Same outcome with a missing/empty `.env` or a broken `op://` reference (`op run` fails before compose).
5. The `forgejo` container, given a fresh empty `forgejo-data` volume *without* `INSTALL_LOCK` set (default false), presents the install wizard at `/install`. With `INSTALL_LOCK=true` (default in our compose), the wizard is bypassed. (This is a setup-time check, not something to flip on a running stack — once `app.ini` is written, the runtime config is what governs.)

## Open questions / explicitly out of scope

- **HTTPS / mkcert for `forgejo.test`.** Add when something needs Secure cookies, service workers, or the user wants `https://` parity with production hosts. Same trigger as the Traefik design.
- **Forgejo Actions runners.** Out of scope. If we want CI on Forgejo pushes, we'd add a `runner` service in this stack with a registration token from Forgejo, and document a hostname allowlist update for the runner.
- **Pull-mirroring `rwdocs/rw` from github.com.** Configurable per-repo via Forgejo UI/API. We'll do this when we actually decide to migrate; not part of the infra change.
- **SSH for git.** Disabled here. Re-enabling means a published port, an updated rw overlay (tinyproxy doesn't proxy SSH), and is a one-overlay decision rather than infrastructure.
- **Docker secrets / `_FILE` env vars.** Both Postgres and Forgejo support `*_FILE` variants that read secrets from disk. Would eliminate the resolved password from Docker's container metadata (it'd live in a tmpfs-backed file inside the container instead). Worth doing if we ever care about other root processes on the laptop reading `docker inspect`. Out of scope; `op run` solves the on-disk-cleartext concern that motivated this round.
- **Multi-user / org / SSO.** Out of scope.
- **LFS.** Not configured. If a repo needs it, set `LFS_JWT_SECRET`, enable LFS in `app.ini`, and update README.
