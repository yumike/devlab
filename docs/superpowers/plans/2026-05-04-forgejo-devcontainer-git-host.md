# Forgejo devcontainer git host — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared host-side Forgejo + Postgres stack at `~/devlab/forgejo/` routed through Traefik at `forgejo.test`, sourcing the DB password from 1Password via `op run`, and wire the rw devcontainer overlay so Claude Code inside it can reach Forgejo as the git remote.

**Architecture:** Two-service compose stack (`forgejo`, `db`) with a stack-private `internal:` network for DB traffic and the shared external `traefik:` network for inbound HTTP. Forgejo binds port 80 internally (sysctl override allows non-root binding) and declares a Docker network alias `forgejo.test` on the `traefik:` network so the same URL works from both the host browser (via Traefik) and any container on the `traefik:` network (direct alias resolution). Secrets live in 1Password; only `op://` references touch disk.

**Tech Stack:** Docker, Docker Compose, Forgejo v15, Postgres 18, 1Password CLI (`op` 2.x), existing Traefik v3.6 stack, devpod (already used for rw).

**Spec:** `docs/superpowers/specs/2026-05-04-forgejo-devcontainer-git-host-design.md`

---

## Prerequisites

These must be in place before starting Task 1. The executor should verify each one and pause to ask the user if any are missing.

1. The shared Traefik stack from `~/devlab/traefik/` is up: `docker compose -f traefik/compose.yml ps` shows `running`. The external `traefik` Docker network exists: `docker network ls --filter name=^traefik$ -q` is non-empty.
2. Mac-side dnsmasq resolves `*.test` to `127.0.0.1`. Per the Traefik stack's README Prerequisites, this is a one-time setup: `brew install dnsmasq`, append `address=/.test/127.0.0.1` to dnsmasq.conf, `sudo brew services start dnsmasq`, drop `nameserver 127.0.0.1` into `/etc/resolver/test`. Verify with `dscacheutil -q host -a name forgejo.test` returning `127.0.0.1`. Without this, browsers and CLIs on the Mac can't reach `*.test` URLs at all.
3. `op` CLI installed (`command -v op` returns a path) and signed in (`op whoami` succeeds without prompting). On macOS Touch ID-based unlock is fine.
4. The user has created (or is willing to create) a 1Password Login/Password item with a generated 32+ character password. Recommended convention: a dedicated `devlab` vault holding `forgejo-db` (DB password) and `forgejo-admin` (admin login). Secret references (`op://devlab/forgejo-db/password`, etc.) go into `forgejo/.env` later.

---

## File Structure

**New files:**
- `.gitignore` — repo-root, excludes `.env` and `.env.local` so the secrets-in-`.env` pattern is reusable across stacks.
- `forgejo/compose.yml` — `forgejo` and `db` services, two networks (stack-local `internal:`, external `traefik:`), two named volumes (`forgejo-data`, `forgejo-db`), 1Password-backed env interpolation for the DB password.
- `forgejo/.env.example` — committed template documenting `FORGEJO_DB_PASSWORD=op://...` and the first-run flow.
- `forgejo/README.md` — prerequisites, first-run, daily operation with `op run`, smoke tests, backups, gotchas.

**Modified files:**
- `devcontainers/rw/compose.yml` — extend `NO_PROXY` and `no_proxy` on `dev` to include `.test`.
- `devcontainers/rw/README.md` — short "Using Forgejo as the git remote" section.

Each file has one clear responsibility. `forgejo/compose.yml` is shared infra and knows nothing about specific overlays. `forgejo/.env` (the real file) is created locally by the user during first-run and never tracked.

---

## Verification approach

This is infrastructure config, not application code, so the spec's acceptance criteria stand in for unit tests. Each task uses a "baseline → change → verify" rhythm: confirm the current behavior, apply the change, then confirm the new behavior matches the spec. Where useful, the baseline doubles as a failing-state check.

The `op run --env-file=.env --` prefix is required for any compose command that recreates containers; that prefix is included in every relevant step below.

---

## Task 1: Add the repo-root `.gitignore`

**Files:**
- Create: `.gitignore`

This goes first so anything we create later in `forgejo/.env` is automatically ignored — no risk of staging a real secret reference.

- [ ] **Step 1.1: Confirm baseline — no `.gitignore` yet**

```bash
test -f .gitignore && echo "exists" || echo "absent"
```

Expected: `absent`. (If the file already exists from prior work, read it and either edit in the new patterns or skip to step 1.3 if they're already there.)

- [ ] **Step 1.2: Create `.gitignore` at the repo root**

Write this exact file at `.gitignore` (relative to the repo root):

```
# Per-stack secrets files. Real values live only in 1Password; the
# .env files in compose stacks hold op:// references resolved at
# startup by `op run --env-file=.env -- docker compose ...`.
# See forgejo/.env.example for the pattern.
.env
.env.local
```

- [ ] **Step 1.3: Verify the patterns work**

```bash
mkdir -p /tmp/devlab-gitignore-check && touch /tmp/devlab-gitignore-check/.env
git check-ignore -v .env 2>/dev/null || echo "would-be-tracked"
```

Expected: a line like `.gitignore:N:.env  .env` showing the rule and matched filename, *not* `would-be-tracked`. (The `git check-ignore` resolves against the repo's index, so it works even if `.env` doesn't exist yet — but creating a temp one in `/tmp` keeps anything with that name from accidentally staging.)

```bash
rm -rf /tmp/devlab-gitignore-check
```

- [ ] **Step 1.4: Commit**

```bash
git add .gitignore
git commit -m "Add repo-root .gitignore for per-stack .env secrets"
```

---

## Task 2: Create the Forgejo compose stack (compose.yml + .env.example)

**Files:**
- Create: `forgejo/compose.yml`
- Create: `forgejo/.env.example`

The `compose.yml` is the actual stack definition; `.env.example` is the committed template the user copies to `.env` during first-run. They are a single conceptual unit — `compose.yml`'s `${FORGEJO_DB_PASSWORD:?...}` interpolation is meaningless without `.env.example` documenting how to populate it — so they ship in the same commit.

- [ ] **Step 2.1: Confirm baseline — `~/devlab/forgejo/` doesn't exist yet**

```bash
test -d forgejo && echo "exists" || echo "absent"
```

Expected: `absent`. (If it exists, read its contents and decide whether to merge or restart cleanly.)

- [ ] **Step 2.2: Create `forgejo/compose.yml`**

Write this exact file at `forgejo/compose.yml`:

```yaml
# Shared host-side Forgejo + Postgres for devcontainer overlay git hosting.
#
# Architecture:
#   - `forgejo` runs the server. It binds port 80 internally (HTTP_PORT=80
#     plus a sysctl that lets the non-root `git` user bind <1024). Joins
#     `internal:` (private to this stack) to reach the DB and the external
#     `traefik:` network for inbound HTTP. Declares a network alias
#     `forgejo.test` on `traefik:` so any container on that network
#     resolves the hostname directly to forgejo's container IP.
#   - `db` runs Postgres 18, only on `internal:` (with `internal: true`,
#     so no NAT/routing). Reachable only by `forgejo` in this stack.
#
# Net effect: same URL `http://forgejo.test` works in browsers (via
# Traefik) and inside other overlays' containers (via the Docker DNS
# alias). DB is fully isolated.
#
# Secrets:
#   FORGEJO_DB_PASSWORD is sourced from 1Password. Bring the stack up
#   with `op run --env-file=.env -- docker compose up -d`. See
#   .env.example and README.md.

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
      # Postgres 18+ expects the volume at /var/lib/postgresql (the parent),
      # not /var/lib/postgresql/data. The image now uses major-version-
      # specific subdirectories (/var/lib/postgresql/18/docker/) so that
      # `pg_upgrade --link` doesn't cross mount boundaries. Mounting the
      # legacy /var/lib/postgresql/data path on PG18 makes the entrypoint
      # refuse to start with a long upgrade-suggestion error.
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

- [ ] **Step 2.3: Create `forgejo/.env.example`**

Write this exact file at `forgejo/.env.example`:

```
# Copy to .env (gitignored at repo root) and replace <your-vault> with
# your 1Password vault. Setup:
#
#   1. In 1Password, add a Login or Password item ("Forgejo Devlab")
#      with a generated password (32+ chars).
#   2. Right-click the password field -> Copy Secret Reference.
#   3. Paste here as the value of FORGEJO_DB_PASSWORD.
#
# Bring the stack up with:
#
#   op run --env-file=.env -- docker compose up -d
#
# 1Password references are not secrets per se (they identify a vault
# path), but .env stays gitignored anyway so vault names don't leak.

FORGEJO_DB_PASSWORD="op://<your-vault>/Forgejo Devlab/password"
```

- [ ] **Step 2.4: Validate compose's interpolation behavior — without env, it must fail loudly**

```bash
docker compose -f forgejo/compose.yml config 2>&1 | tail -3
```

Expected: error mentioning `FORGEJO_DB_PASSWORD` and the message `run via op run --env-file=.env` from the `:?` interpolation. If `config` succeeds with an empty value, the `:?` syntax is wrong — re-read step 2.2.

- [ ] **Step 2.5: Validate compose's interpolation behavior — with a dummy env, it must succeed**

```bash
FORGEJO_DB_PASSWORD=dummy docker compose -f forgejo/compose.yml config > /dev/null && echo ok
```

Expected: `ok`. (We don't bring the stack up here; that's Task 3, after the user populates real `.env`.)

- [ ] **Step 2.6: Commit**

```bash
git add forgejo/compose.yml forgejo/.env.example
git commit -m "Add Forgejo + Postgres stack (op://-backed secrets, port-80 + alias)"
```

---

## Task 3: Bring up the Forgejo stack and create the admin user

**Files:**
- Create (locally, not committed): `forgejo/.env`
- Test: `op run --env-file=.env -- docker compose up -d`, `curl http://forgejo.test/`, `forgejo admin user create`

This task includes manual user input (the 1Password reference). The executor should *pause and ask the user* at step 3.2 if running in a non-interactive context.

- [ ] **Step 3.1: Confirm prerequisites are good**

```bash
op whoami >/dev/null && echo "op signed in" || echo "RUN: eval \"\$(op signin)\""
docker network ls --filter name=^traefik$ -q | grep -q . && echo "traefik network OK" || echo "RUN: docker network create traefik"
docker compose -f traefik/compose.yml ps --status running | grep -q traefik && echo "Traefik running" || echo "RUN: docker compose -f traefik/compose.yml up -d"
```

Expected: three lines all starting `op signed in`, `traefik network OK`, `Traefik running`. Address any `RUN:` line before continuing.

- [ ] **Step 3.2: Create `forgejo/.env` from the example**

Manual step — pause for the user.

```bash
cd forgejo
cp .env.example .env
$EDITOR .env   # replace op://<your-vault>/... with your real 1Password reference
cd ..
```

Verification:

```bash
test -f forgejo/.env && grep -q '^FORGEJO_DB_PASSWORD=op://' forgejo/.env && echo ok
```

Expected: `ok`. If empty/missing or doesn't start with `op://`, re-edit.

- [ ] **Step 3.3: Verify the 1Password reference resolves**

```bash
( cd forgejo && set -a; . ./.env; set +a; op read "$FORGEJO_DB_PASSWORD" >/dev/null && echo "ref OK" )
```

Expected: `ref OK`. If `op read` fails, the reference is wrong (typo in vault/item/field, or the item doesn't exist) — fix `.env`. The output of `op read` is the actual password; we discard it via `>/dev/null` so it doesn't land in shell history or terminal scrollback.

- [ ] **Step 3.4: Confirm `.env` is gitignored**

```bash
git check-ignore -v forgejo/.env
```

Expected: a line like `.gitignore:5:.env  forgejo/.env`. If it prints nothing and exits 1, the gitignore from Task 1 isn't matching — verify the patterns.

- [ ] **Step 3.5: Bring the stack up**

```bash
cd forgejo
op run --env-file=.env -- docker compose up -d
cd ..
```

Expected: pulls images on first run, then `forgejo-db-1` reaches healthy, `forgejo-forgejo-1` starts after. No errors. If `op run` complains about not being signed in, run `eval "$(op signin)"` and retry.

- [ ] **Step 3.6: Verify both services are healthy**

```bash
docker compose -f forgejo/compose.yml ps
```

Expected: both `forgejo` and `db` in state `running`. `db` shows `(healthy)`; `forgejo` should not be in restart-loop.

- [ ] **Step 3.7: Verify Forgejo logs are clean**

```bash
docker compose -f forgejo/compose.yml logs forgejo 2>&1 | grep -iE 'error|fatal|panic' | head -5 || echo clean
```

Expected: `clean`, or only benign info lines about migrations / first-start. If you see DB connection errors, check the password by re-running step 3.3 — Forgejo and Postgres must agree on the same value.

- [ ] **Step 3.8: Verify HTTP from the host browser path**

```bash
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: `200`. If you get `Could not resolve host` from a libc-based curl, fall back to `curl --resolve forgejo.test:80:127.0.0.1 ...` or test from Chrome/Firefox.

- [ ] **Step 3.9: Verify the dashboard shows the forgejo router**

```bash
curl -s http://traefik.test/api/http/routers | grep -o '"name":"forgejo@docker"'
```

Expected: `"name":"forgejo@docker"`. If empty, the labels in compose.yml didn't take — `docker inspect $(docker ps --filter name=forgejo-forgejo -q) --format '{{json .Config.Labels}}'` should show all four `traefik.*` labels.

- [ ] **Step 3.10: Create the first admin user**

Manual step — pause for the user. Recommended pattern: store the admin password in 1Password (e.g. `op://devlab/forgejo-admin/password`), pass it through a transient env var to keep it out of shell history and `ps` argv, and explicitly set `--must-change-password=false` (Forgejo 15's default for that flag is *true*, which both forces first-login rotation AND silently fails to apply `--password`).

```bash
op item create \
  --category=login \
  --title="forgejo-admin" \
  --vault=devlab \
  --generate-password='letters,digits,symbols,32' \
  --tags=forgejo,admin \
  --url='http://forgejo.test/' \
  username=yumike

ADMIN_PW="$(op read 'op://devlab/forgejo-admin/password')" \
  docker compose -f forgejo/compose.yml exec -T --user git -e ADMIN_PW="$ADMIN_PW" forgejo \
    sh -c 'forgejo admin user create \
      --username yumike \
      --password "$ADMIN_PW" \
      --email mike.yumatov@gmail.com \
      --admin \
      --must-change-password=false'
```

`--user git` because Forgejo refuses to run as root. Expected: `New user 'yumike' has been successfully created!`. If it errors with a duplicate, the volume isn't fresh — either pick a different username or tear down and recreate (`docker compose down -v`; *destructive*, only run if you intend a clean slate).

- [ ] **Step 3.11: Verify login works**

Quick API check (no browser needed):

```bash
ADMIN_PW="$(op read 'op://devlab/forgejo-admin/password')"
curl -s -u "yumike:$ADMIN_PW" http://forgejo.test/api/v1/user | head -1
unset ADMIN_PW
```

Expected: a JSON object with `"login":"yumike"` and `"is_admin":true`. If you instead see `"user's password isn't set"` or `"You must change your password..."`, the `--must-change-password=false` was missed in step 3.10 — re-run with `forgejo admin user change-password --username yumike --password "$ADMIN_PW" --must-change-password=false` (same env-var pattern) to recover.

Optionally also confirm in the browser at <http://forgejo.test/user/login>.

- [ ] **Step 3.12: Verify a clean down/up cycle preserves state**

```bash
docker compose -f forgejo/compose.yml down
cd forgejo
op run --env-file=.env -- docker compose up -d
cd ..
sleep 5  # give db healthcheck a moment
curl -sv http://forgejo.test/user/login -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: `200`. The admin user from step 3.10 still works. Volumes survived.

- [ ] **Step 3.13: No commit**

This task is operational/setup; nothing in the repo changed. The local `forgejo/.env` is gitignored. Proceed to Task 4.

---

## Task 4: Write the Forgejo stack README

**Files:**
- Create: `forgejo/README.md`

- [ ] **Step 4.1: Create `forgejo/README.md`**

Write this exact file at `forgejo/README.md`:

````markdown
# Shared Forgejo + Postgres for devcontainer overlay git hosting

Single Forgejo instance reachable at `http://forgejo.test` from
both the host browser (via the shared Traefik proxy) and from inside
any devcontainer overlay on the `traefik` external network (via a
Docker DNS alias). Postgres 18 sidecar, fully isolated on a
stack-local `internal:` network.

Secrets live in 1Password — only `op://` references touch disk.

## Prerequisites

- The shared Traefik stack at `~/devlab/traefik/` is running and the
  external `traefik` Docker network exists. See `~/devlab/traefik/README.md`.
- 1Password CLI (`op`, version >= 2.x):
  `brew install --cask 1password-cli` and `eval "$(op signin)"`.
- A 1Password Login or Password item with a generated 32+ char
  password. This README assumes you've created one named "Forgejo
  Devlab" in your `Personal` vault, but the path is up to you.

## First-run setup

1. Create the 1Password item (if you haven't already). Right-click the
   password field and pick **Copy Secret Reference** — you'll paste
   that next.
2. Set up `forgejo/.env`:

       cd ~/devlab/forgejo
       cp .env.example .env
       $EDITOR .env   # paste the secret reference

3. Sanity-check the reference resolves:

       set -a; . ./.env; set +a
       op read "$FORGEJO_DB_PASSWORD" >/dev/null && echo OK

4. Bring up the stack:

       op run --env-file=.env -- docker compose up -d

   `db` reaches healthy first; `forgejo` starts after the healthcheck
   passes (typically < 15 s on first start, < 5 s after).
5. Create the first admin user. The cleanest pattern: store the
   admin password in 1Password too (a separate item, e.g.
   `op://devlab/forgejo-admin/password`). Create it now if you
   haven't already:

       op item create --category=login --title=forgejo-admin \
         --vault=devlab --generate-password='letters,digits,symbols,32' \
         --url=http://forgejo.test/ username=yumike

   Then pass it through a transient env var so it never appears in
   shell history or `ps` argv, and pass `--must-change-password=false`
   to disable Forgejo's change-on-first-login dance (the password is
   already canonical in 1Password — forcing rotation just makes the
   1Password item stale on first login). Forgejo runs as the non-root
   `git` user, so `docker compose exec` needs `--user git`:

       ADMIN_PW="$(op read 'op://devlab/forgejo-admin/password')" \
         docker compose exec -T --user git -e ADMIN_PW="$ADMIN_PW" forgejo \
           sh -c 'forgejo admin user create \
             --username yumike \
             --password "$ADMIN_PW" \
             --email mike.yumatov@gmail.com \
             --admin \
             --must-change-password=false'
       unset ADMIN_PW

   Log in at <http://forgejo.test/user/login>.

If `.env` is missing, `FORGEJO_DB_PASSWORD` is empty, or the `op run`
prefix is forgotten, `docker compose up` fails with
`error while interpolating ... run via op run --env-file=.env` —
loud and unambiguous. If the `op://` reference is wrong, `op run`
fails before compose is invoked.

## Daily operation

The `op run --env-file=.env --` prefix is required for any command
that *recreates* containers — `up`, `down && up`, `pull` followed by
`up -d`. Containers with `restart: unless-stopped` survive Docker
Desktop restarts and host reboots without re-resolving the reference,
so the prefix is rarely needed in steady state.

A shell alias smooths the rare cases:

    alias dcf='op run --env-file=.env -- docker compose'

Plain `docker compose ps`, `logs`, `exec`, `stop`, `start` (without
recreate) work fine *without* `op run` — env vars are baked into
existing container metadata.

## Smoke tests

After bringing the stack up:

- `curl -sv http://forgejo.test/` → 200, body contains "Forgejo".
- `docker compose ps` → both services running, `db` healthy.
- `docker compose logs forgejo` → no errors. First start logs note
  `app.ini` was generated and `SECRET_KEY`/`INTERNAL_TOKEN` written.
- `docker compose down && op run --env-file=.env -- docker compose up -d`
  → cycles cleanly, admin user and repos survive.

Postgres isolation:

- From inside `forgejo`: `nc -z db 5432` → ok. (alpine image, no Postgres client; `nc` confirms the TCP path.)
- From the host: `nc -z localhost 5432` → fails (no published port).
- From an overlay's dev container on `traefik`: `getent hosts db`
  does not resolve (the forgejo stack's `internal:` network is not
  shared).

## Backups

The two named volumes are the entire state.

```bash
# back up
docker run --rm -v forgejo_forgejo-data:/d -v "$PWD":/o alpine tar -czf /o/forgejo-data.tgz -C /d .
docker run --rm -v forgejo_forgejo-db:/d   -v "$PWD":/o alpine tar -czf /o/forgejo-db.tgz   -C /d .
```

Compose namespaces the bare `forgejo-data` / `forgejo-db` from
`compose.yml` under the project name (`name: forgejo`), so the actual
Docker volumes are `forgejo_forgejo-data` and `forgejo_forgejo-db`.
Using the unprefixed names here would silently create empty volumes
and tar up nothing — verify with `docker volume ls | grep forgejo`.

Stop the stack before backing up `forgejo_forgejo-db` to avoid a torn
Postgres snapshot. `forgejo_forgejo-data` can usually be backed up
live; for paranoid backups, stop the stack.

Restore: stop stack, `docker volume rm forgejo_forgejo-data forgejo_forgejo-db`,
`docker volume create forgejo_forgejo-data forgejo_forgejo-db`, untar
back into `/d` inside an alpine container, start.

## Operational notes

**Floating image tags.** `forgejo:15` and `postgres:18` track minor
versions. For bit-reproducibility pin to `:15.0.1` / `:18.3` or to
a `@sha256:...` digest.

**Postgres 18+ volume mount path.** The `db` volume is mounted at
`/var/lib/postgresql` (the parent), not the legacy `/var/lib/postgresql/data`.
Postgres 18+ images use major-version-specific subdirectories like
`/var/lib/postgresql/18/docker/` so that `pg_upgrade --link` works
without crossing mount boundaries. Mounting the legacy path on PG18+
makes the entrypoint refuse to start with a long upgrade-suggestion
error referring to `/var/lib/postgresql/data (unused mount/volume)`.

**Forgejo 15 `--must-change-password` default.** Forgejo's CLI defaults
this flag to **true**, despite what the help text suggests. Omitting
it on `forgejo admin user create` not only sets the must-change flag,
it also silently fails to apply the `--password` you supplied — so the
account is created in a no-password state and basic auth login is
broken until you run `forgejo admin user change-password
--must-change-password=false ...`. Always pass
`--must-change-password=false` explicitly when bootstrapping admin
users where the password is already canonical in 1Password.

**Postgres password is sourced from 1Password.** No cleartext on the
host's user-visible filesystem; only `op://` references in `.env`.
The resolved password ends up in Docker's container metadata
(`/var/lib/docker/containers/<id>/config.v2.json` inside the Docker
Desktop VM) — that's true of any compose-env approach short of
Docker swarm secrets / `_FILE` env vars. Threat model addressed:
GitHub leakage and casual filesystem inspection.

**SECRET_KEY / INTERNAL_TOKEN.** Auto-generated on first start and
persisted to `app.ini` inside the `forgejo-data` volume. Wiping the
volume regenerates them, which invalidates existing 2FA secrets and
active sessions. Back up `forgejo-data` if you want session
continuity across volume rebuilds.

**No SSH for git.** `FORGEJO__server__DISABLE_SSH=true` and no SSH
port published. The rw overlay is HTTP-only by design (tinyproxy
doesn't speak SSH), so no devcontainer can use SSH-based clone URLs
anyway. Push auth is via Personal Access Tokens (Forgejo UI →
User Settings → Applications) over HTTP.

**Failure modes.**
- *Forgejo down, Postgres up:* host browser → 502 from Traefik.
  From overlays on `traefik`, the alias may stop resolving once
  the container is gone; `connection refused` if it still does.
- *Postgres down, Forgejo up:* Forgejo logs DB connection errors;
  UI returns 500. `depends_on: condition: service_healthy` prevents
  this on cold start; only happens if DB falls over mid-flight.
- *Traefik down:* host browser → connection refused on
  `forgejo.test`. Overlays on the `traefik` network are
  unaffected (the alias path doesn't go through Traefik).
- *`traefik` external network missing:* `docker compose up` fails
  with `network traefik declared as external, but could not be found`.
  Recovery: `docker network create traefik`.

**Why dev-container traffic bypasses Traefik.** The Docker network
alias `forgejo.test` is declared on `forgejo` (not on
Traefik). Containers on `traefik:` resolve the alias directly to
forgejo's IP and connect to port 80. Traefik is bypassed for
intra-Docker traffic — but that's by design: it preserves the rule
"the Traefik stack knows nothing about specific overlays" and
removes a hop. From the host browser, traffic still goes through
Traefik (the host has no Docker DNS).
````

- [ ] **Step 4.2: Verify the file is well-formed**

```bash
test -s forgejo/README.md && echo ok
```

Expected: `ok`.

- [ ] **Step 4.3: Commit**

```bash
git add forgejo/README.md
git commit -m "Document Forgejo stack: setup, op run flow, smoke tests, backups"
```

---

## Task 5: Update rw `NO_PROXY` to skip the proxy for `*.test`

**Files:**
- Modify: `devcontainers/rw/compose.yml`

This is the one delta on the rw overlay. Without it, `git`/`curl` inside `dev` would route `http://forgejo.test/...` through tinyproxy, which can't reach Forgejo.

- [ ] **Step 5.1: Confirm baseline — current `NO_PROXY` does not include `.test`**

```bash
grep -nE 'NO_PROXY|no_proxy' devcontainers/rw/compose.yml
```

Expected: two lines (one for `NO_PROXY`, one for `no_proxy`), each ending in `,.local` *without* a trailing `,.test`.

- [ ] **Step 5.2: Edit `devcontainers/rw/compose.yml` — extend both env vars**

Find the two lines:

```yaml
      NO_PROXY: localhost,127.0.0.1,proxy,.local
      no_proxy: localhost,127.0.0.1,proxy,.local
```

Replace with:

```yaml
      NO_PROXY: localhost,127.0.0.1,proxy,.local,.test
      no_proxy: localhost,127.0.0.1,proxy,.local,.test
```

Both must change. libcurl reads `NO_PROXY`; some Go tools / envsubst-style readers honor `no_proxy` only. Both upper- and lower-case entries already exist for that reason — preserve the symmetry.

- [ ] **Step 5.3: Validate the modified compose file**

```bash
docker compose -f devcontainers/rw/compose.yml config > /dev/null && echo ok
```

Expected: `ok`.

- [ ] **Step 5.4: Recreate the rw devcontainer**

Run from the *project workspace* directory (typically `~/projects/oss/rwdocs/rw`), where the overlay is symlinked in as `.devcontainer-rw`:

```bash
cd ~/projects/oss/rwdocs/rw
devpod up . --recreate --devcontainer-path .devcontainer-rw/devcontainer.json
```

Expected: completes without error. If devpod isn't in use yet, `docker compose -f ~/devlab/devcontainers/rw/compose.yml up -d --force-recreate dev` works as a fallback.

- [ ] **Step 5.5: Verify the new env vars inside `dev`**

From a shell inside the rw `dev` container (devpod ssh, or `docker exec`):

```bash
echo "$NO_PROXY"
echo "$no_proxy"
```

Expected: both end in `,.test`. If they don't, the recreate didn't apply — try `--recreate` again, or `docker compose down dev && docker compose up -d dev`.

- [ ] **Step 5.6: Verify Forgejo is reachable from inside `dev`**

Inside the rw dev container:

```bash
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
curl -sv http://forgejo.test/ -o /dev/null -D - 2>&1 | grep -i '^Via:' || echo "no Via header — direct"
```

Expected: `200`, and `no Via header — direct`. The absence of `Via:` confirms the request did *not* traverse tinyproxy (which adds `Via:` by default).

If the first curl gives `connection refused` or hangs, `NO_PROXY` likely didn't apply — re-check step 5.5.

If it returns 200 *with* a `Via:` header, traffic *is* going through tinyproxy (which means `proxy/filter` happened to allow it, or tinyproxy was reconfigured) — that's the wrong behavior. Re-check `NO_PROXY` value and the curl version (`curl --version` should be ≥ 7.85 for full leading-dot suffix-match semantics; 7.74+ for basic).

- [ ] **Step 5.7: Verify egress lockdown still works (regression check)**

Inside the rw dev container:

```bash
curl -v https://example.com 2>&1 | grep -iE 'filter|denied|connection' | head -3
curl -sv https://github.com 2>&1 | grep -i '^HTTP/' | head -1
getent hosts proxy
```

Expected:
- `example.com` → blocked by tinyproxy (filtered)
- `github.com` → 200 or 301 (allowlisted, unchanged)
- `proxy` resolves to a private RFC 1918 address — confirms the dev↔proxy path on `internal:` survived

- [ ] **Step 5.8: Commit**

```bash
git add devcontainers/rw/compose.yml
git commit -m "rw overlay: extend NO_PROXY/.no_proxy to skip tinyproxy for *.test"
```

---

## Task 6: Update rw README with the Forgejo usage notes

**Files:**
- Modify: `devcontainers/rw/README.md`

- [ ] **Step 6.1: Add a "Using Forgejo as the git remote" section to `devcontainers/rw/README.md`**

Insert this section after the existing "Access via `rw.test`" section (or wherever fits the existing flow best — preserve surrounding prose). The convention in this README is sentence-case headings, terse paragraphs, fenced bash blocks for commands.

```markdown
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

The `forgejo` binary's [CLI](https://forgejo.org/docs/next/admin/command-line/)
is *server-side admin only* and runs inside the server container
(`docker compose exec forgejo forgejo admin ...` for things like user
creation). It is not a client and won't help with day-to-day PR work.

There is no SSH for git here: Forgejo has SSH disabled, the rw dev
container's tinyproxy doesn't speak SSH, and the spec considers SSH
out of scope. Use HTTPS-style URLs.
```

- [ ] **Step 6.2: Verify the new heading exists and renders**

```bash
grep -n '^## Using Forgejo' devcontainers/rw/README.md
```

Expected: one match.

- [ ] **Step 6.3: Commit**

```bash
git add devcontainers/rw/README.md
git commit -m "Document Forgejo as the rw dev container git remote"
```

---

## Task 7: Final acceptance pass

This task runs every spec acceptance criterion in sequence. No code changes; if anything fails, return to the relevant earlier task and fix.

- [ ] **Step 7.1: Forgejo stack alone**

```bash
git check-ignore -v forgejo/.env
( cd forgejo && set -a; . ./.env; set +a; op read "$FORGEJO_DB_PASSWORD" >/dev/null && echo "ref OK" )

cd forgejo
op run --env-file=.env -- docker compose up -d
cd ..
sleep 5
docker compose -f forgejo/compose.yml ps
docker compose -f forgejo/compose.yml logs forgejo 2>&1 | grep -iE 'error|fatal|panic' | head -3 || echo clean
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected:
- gitignore matches `.env`; `op read` succeeds
- both services `running`; `db` healthy
- forgejo logs: `clean` (or only benign info)
- `forgejo.test/` returns `200`

Cycle test:

```bash
docker compose -f forgejo/compose.yml down
cd forgejo
op run --env-file=.env -- docker compose up -d
cd ..
sleep 5
curl -sv http://forgejo.test/user/login -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: `200`. The admin user from Task 3 still works.

- [ ] **Step 7.2: Postgres isolation**

```bash
docker compose -f forgejo/compose.yml exec -T forgejo nc -z db 5432 && echo "db reachable"
nc -z localhost 5432 2>&1 || echo "host port closed (good)"
```

Expected:
- `db:5432 - accepting connections` from inside the forgejo container
- "host port closed" — confirms no port published to the host

From the rw `dev` container:

```bash
getent hosts db    # expect: empty / exit 2
curl -sv http://db:5432/ 2>&1 | grep -iE 'could not resolve|name' | head -1
```

Expected: `db` does not resolve. Failure is at name resolution, not TCP — the forgejo stack's `internal:` is a different Docker network from rw's `internal:`, and Docker DNS only resolves names within attached networks.

- [ ] **Step 7.3: rw overlay end-to-end**

(Run from inside the rw `dev` container.)

```bash
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
curl -sv http://forgejo.test/ -o /dev/null -D - 2>&1 | grep -i '^Via:' || echo "no Via header — direct"
```

Expected: `200`, `no Via header — direct`.

Then create a seed repo through the Forgejo UI (any browser tab, logged in as the admin user) — name it e.g. `seed`. Back inside `dev`:

```bash
git clone http://forgejo.test/yumike/seed.git /tmp/seed-clone
cd /tmp/seed-clone
git config user.email yumike@example.com
git config user.name yumike
echo hello > README.md
git add README.md
git commit -m "init"
git push   # paste username + PAT when prompted
```

Expected: clone, commit, and push all succeed. The same URL works from the host browser when you visit
<http://forgejo.test/yumike/seed>.

- [ ] **Step 7.4: Egress lockdown regression check**

Inside the rw `dev` container:

```bash
curl -v https://example.com 2>&1 | grep -iE 'filter|denied|connection' | head -3
curl -sv https://github.com 2>&1 | grep -i '^HTTP/' | head -1
getent hosts proxy
```

Expected:
- `example.com` → blocked by tinyproxy
- `github.com` → 200/301
- `proxy` resolves to an RFC 1918 address

- [ ] **Step 7.5: Negative tests**

Forgejo stopped:

```bash
docker compose -f forgejo/compose.yml down
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected from the host: `502` (Traefik, no backend).

From inside the rw dev container:

```bash
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: connection refused (Docker DNS for the alias may still resolve, but nothing is listening).

Bring it back:

```bash
cd forgejo
op run --env-file=.env -- docker compose up -d
cd ..
sleep 5
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: `200`.

Traefik stopped:

```bash
docker compose -f traefik/compose.yml down
# from the host:
curl -sv http://forgejo.test/ -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: connection refused. Inside the rw `dev` container, `curl -sv http://forgejo.test/` should still return 200 (alias path is unaffected).

```bash
docker compose -f traefik/compose.yml up -d
```

Missing-env failure mode:

```bash
docker compose -f forgejo/compose.yml config 2>&1 | grep -i 'run via op run'
```

Expected: the `:?` interpolation error message — confirms `compose up` without `op run` fails loudly. (Don't actually try to `up` without `op run`; the error path is verified at the `config` stage.)

Missing-network failure mode (only run if you're willing to recreate networks):

```bash
docker compose -f forgejo/compose.yml down
docker compose -f traefik/compose.yml down
docker network rm traefik
cd forgejo
op run --env-file=.env -- docker compose up -d 2>&1 | grep -i 'network traefik'
cd ..
# Restore:
docker network create traefik
docker compose -f traefik/compose.yml up -d
cd forgejo
op run --env-file=.env -- docker compose up -d
cd ..
```

Expected: forgejo `compose up` fails with `network traefik declared as external, but could not be found` — loud, not silent. After restore, both stacks come back up cleanly.

- [ ] **Step 7.6: No commit**

This task is verification-only. If everything passes, the implementation is complete. If anything fails, return to the relevant earlier task and fix before re-running this one.

---

## Notes on style and discipline

- **Frequent commits:** five commits across Tasks 1, 2, 4, 5, 6. Tasks 3 and 7 are operational and don't change repo files. Don't squash mid-implementation.
- **YAGNI:** the spec explicitly defers HTTPS, dashboard auth, Forgejo Actions runners, pull-mirroring from GitHub, SSH for git, Docker secrets / `_FILE` env vars, multi-user/SSO, and LFS. Don't add any of these "while we're at it." (dnsmasq for `*.test` resolution *is* required and lives in `~/devlab/traefik/README.md` Prerequisites.)
- **DRY:** the `op run --env-file=.env --` pattern is documented in `forgejo/README.md` only; `devcontainers/rw/README.md` references the Forgejo README rather than restating it.
- **Existing patterns:** the rw and Traefik compose files have a comment block at the top explaining the design — `forgejo/compose.yml` follows the same convention. The `~/devlab/.gitignore` was kept intentionally minimal (only `.env*`); broader entries (build artifacts, editor files) are out of scope.
- **Secrets:** never echo `op read` output, never paste a real password into the plan or commit messages, never check in `forgejo/.env`. The repo-root `.gitignore` is the safety net; `git check-ignore -v` is the proof.
