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
  password. Examples below assume an item named "Forgejo Devlab" in a
  vault called `<your-vault>` — substitute your actual vault name.

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
   passes — typically 15–30 s on first start (initdb runs), under 5 s
   after.
5. Create the first admin user. Store the admin password in 1Password
   too (a separate item) so it never lives on disk:

       op item create --category=login --title=forgejo-admin \
           --vault='<your-vault>' \
           --generate-password='letters,digits,symbols,32' \
           --url=http://forgejo.test/ \
           username=yumike

   Then pass it to `forgejo admin user create` through a transient env
   var so it never appears in shell history or `ps` argv. Pass
   `--must-change-password=false` (Forgejo's CLI defaults this to
   true — see operational notes); Forgejo runs as the non-root `git`
   user, so `docker compose exec` needs `--user git`:

       ADMIN_PW="$(op read 'op://<your-vault>/forgejo-admin/password')" \
         docker compose exec -T --user git -e ADMIN_PW="$ADMIN_PW" forgejo \
           sh -c 'forgejo admin user create \
             --username yumike \
             --password "$ADMIN_PW" \
             --email mike.yumatov@gmail.com \
             --admin \
             --must-change-password=false'

   Log in at <http://forgejo.test/user/login>.

If `.env` is missing or the `op run` prefix is forgotten, `docker
compose up` fails with `required variable FORGEJO_DB_PASSWORD is
missing a value: run via op run --env-file=.env`. If the `op://`
reference is wrong, `op run` fails before compose is invoked.

## Daily operation

The `op run --env-file=.env --` prefix is only needed when *recreating*
containers (`up`, `down && up`, `pull` then `up -d`); env is baked into
container metadata at create time and survives Docker Desktop restarts
and host reboots. Plain `docker compose ps`, `logs`, `exec`, `stop`,
`start` work without `op run`. An alias smooths the recreate case:

    alias dcf='op run --env-file=.env -- docker compose'

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

The two named volumes (`forgejo_forgejo-data`, `forgejo_forgejo-db` —
project name prefixed by compose) are the entire state:

    docker run --rm -v forgejo_forgejo-data:/d -v "$PWD":/o alpine \
        tar -czf /o/forgejo-data.tgz -C /d .
    docker run --rm -v forgejo_forgejo-db:/d   -v "$PWD":/o alpine \
        tar -czf /o/forgejo-db.tgz   -C /d .

Stop the stack (`docker compose down`) before backing up
`forgejo_forgejo-db` to avoid a torn Postgres snapshot.
`forgejo_forgejo-data` can usually be backed up live; stop the stack
too for paranoid backups.

Restore: stop stack, `docker volume rm` both volumes, recreate them,
untar back into `/d` inside an alpine container, start.

## Operational notes

**Floating image tags.** Image tags track minor versions. Pin to a
patch version or `@sha256:...` digest in `compose.yml` for
bit-reproducibility.

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

**Password leaks into container metadata.** `op run` keeps cleartext
off the user-visible filesystem, but the resolved password ends up in
Docker's container metadata (`/var/lib/docker/containers/<id>/config.v2.json`
inside the Docker Desktop VM) — true of any compose-env approach short
of Docker swarm secrets / `_FILE` env vars. Threat model addressed:
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

**Traefik dependency.**
- *Missing `traefik` network:* `docker compose up` fails with
  `network traefik declared as external, but could not be found`.
  Fix: `docker network create traefik`.
- *Traefik container down:* host browser gets connection refused on
  `forgejo.test`. Overlays on the `traefik` network are unaffected —
  the alias path doesn't go through Traefik.
