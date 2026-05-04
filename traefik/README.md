# Shared Traefik for devcontainer overlays

Single Traefik container that routes `*.localhost` to opted-in
devcontainer overlays. Each overlay declares its own hostname via
labels — this stack itself knows nothing about specific overlays.

## Prerequisite: create the external network (one time)

    docker network inspect traefik >/dev/null 2>&1 || docker network create traefik

Safe to re-run: the inspect short-circuits when the network already
exists, so the create only runs on a fresh machine. (Plain
`docker network create traefik` also works first time, but exits 1 with
`network with name traefik already exists` on subsequent runs — annoying
under `set -e`.) Compose stacks that declare `traefik` as `external: true`
will fail to start until this network exists.

## Start / stop

    cd ~/devlab/traefik
    docker compose up -d            # start
    docker compose down             # stop (network and overlays survive)
    docker compose logs -f traefik  # follow logs

The dashboard is at <http://traefik.localhost/dashboard/> (the
trailing slash matters — without it Traefik returns 404).

## How an overlay opts in

The convention. Any overlay's `compose.yml` that wants `<project>.localhost`:

1. Set the compose project name explicitly at the top of the file:

       name: <project>

2. Join the `traefik` external network on the service that should
   receive traffic. Other networks (e.g. `internal`) coexist:

       services:
         <service>:
           networks:
             - <existing>
             - traefik
       networks:
         traefik:
           name: traefik
           external: true

3. Add four Traefik labels on that service:

       labels:
         - traefik.enable=true
         - traefik.docker.network=traefik
         - traefik.http.routers.<project>.rule=Host(`<project>.localhost`)
         - traefik.http.services.<project>.loadbalancer.server.port=<port>

4. Don't `forwardPorts` the same port — Traefik replaces VS Code's
   port forwarding for that service.

When an overlay needs to expose more than one service, the primary
keeps `<project>.localhost`; secondaries use
`<name>.<project>.localhost`. Router/service names must remain
unique across all containers Traefik sees — use `<project>-<name>`.

Overlays that don't expose anything skip all of the above.

## Smoke tests

After `docker compose up -d` here:

- `curl -sv -L http://traefik.localhost/dashboard/` → 200, body
  contains "Traefik". (If your `curl` doesn't resolve `*.localhost`
  — see DNS note below — fall back to
  `curl --resolve traefik.localhost:80:127.0.0.1 …`.)
- `docker compose logs traefik` → no errors, no "network not found"
  warnings.
- `docker compose down && docker compose up -d` → cycles cleanly.

After bringing up an overlay (e.g. rw):

- `docker network inspect traefik` lists both the `traefik`
  container and the overlay's exposed service.
- `http://<project>.localhost` reaches the overlay's primary port
  (502 from Traefik when nothing is listening inside the
  container — that's correct).
- The dashboard shows a router named after the project with the
  expected `Host(...)` rule and backend.

## Operational notes

**DNS resolution.** Chrome, Firefox, Edge, and Arc resolve
`*.localhost` to 127.0.0.1 (RFC 6761). Safari, older `curl`, Node
`fetch`, and most native CLIs that go through libc do not. The
escape hatch is `brew install dnsmasq` plus `/etc/resolver/localhost`
mapping `.localhost` to `127.0.0.1`. Not configured by default.

**Port 80 conflicts.** `sudo lsof -i :80` before first start.
macOS doesn't normally listen on 80, but a stray nginx/Caddy or
Apple Web Sharing can. Don't move Traefik off 80 — that defeats
the point of clean URLs.

**Dashboard exposure.** `api@internal` is reachable unauthenticated
on the dashboard router. Acceptable for a single-developer laptop
on a trusted network. If that ever changes, switch the published
port binding to `127.0.0.1:80:80` or add a `BasicAuth` middleware.

**`v3.6` floats.** The image is pinned to the v3.6 minor track but
not a specific patch. For bit-reproducibility, replace `v3.6` with
`v3.6.15` or `@sha256:...` in `compose.yml`.

**Failure mode when Traefik is down.** `<project>.localhost`
returns connection refused. There is no `forwardPorts` fallback for
overlays that have committed to Traefik routing. Recovery:
`docker compose up -d` here.

**Cookies under `*.localhost`.** Apps should leave `Domain=` unset.
Some browsers refuse explicit `Domain=.localhost`.
