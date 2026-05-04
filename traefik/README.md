# Shared Traefik for devcontainer overlays

Single Traefik container that routes `*.test` to opted-in
devcontainer overlays. Each overlay declares its own hostname via
labels — this stack itself knows nothing about specific overlays.

## Prerequisites (one-time)

### 1. The external `traefik` Docker network

    docker network inspect traefik >/dev/null 2>&1 || docker network create traefik

Safe to re-run. Compose stacks that declare `traefik` as
`external: true` will fail to start until this network exists.

### 2. dnsmasq for `*.test` resolution on the Mac

`*.test` is reserved by RFC 2606 / RFC 6761 for testing — IANA will
never delegate it as a real public TLD — but unlike `*.localhost` it
is not hardcoded to loopback by browsers, glibc, or `getaddrinfo`.
That's the whole point of using it (Docker DNS aliases on `*.test`
work correctly from inside containers, where `*.localhost` did not).
The trade-off: `*.test` needs explicit Mac-side DNS, so:

    brew install dnsmasq
    echo 'address=/.test/127.0.0.1' >> "$(brew --prefix)/etc/dnsmasq.conf"
    sudo brew services start dnsmasq
    sudo mkdir -p /etc/resolver
    echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/test

After this, every `*.test` name on the Mac (any browser, any CLI,
any tool) resolves to `127.0.0.1` — which is Traefik's published
port. No `/etc/hosts` edits per project, no per-overlay setup.

Verify:

    dscacheutil -q host -a name forgejo.test   # any *.test name
    # name: forgejo.test, ip_address: 127.0.0.1

## Start / stop

    cd ~/devlab/traefik
    docker compose up -d            # start
    docker compose down             # stop (network and overlays survive)
    docker compose logs -f traefik  # follow logs

The dashboard is at <http://traefik.test/dashboard/> (the
trailing slash matters — without it Traefik returns 404).

## How an overlay opts in

The convention. Any overlay's `compose.yml` that wants
`<project>.test`:

1. Set the compose project name explicitly at the top of the file:

       name: <project>

2. Join the `traefik` external network on the service that should
   receive traffic. Other networks (e.g. `internal`) coexist:

       services:
         <service>:
           networks:
             <existing>:
             traefik:
               aliases:
                 - <project>.test
       networks:
         traefik:
           name: traefik
           external: true

   The `aliases` line registers `<project>.test` as a Docker DNS
   name pointing at this service's IP on the `traefik` network — so
   any other container on `traefik:` (e.g. another overlay's `dev`
   service) reaches `<project>` directly via the same hostname the
   browser uses, bypassing Traefik for intra-Docker traffic. Same
   URL works in both contexts.

3. Add four Traefik labels on that service:

       labels:
         - traefik.enable=true
         - traefik.docker.network=traefik
         - traefik.http.routers.<project>.rule=Host(`<project>.test`)
         - traefik.http.services.<project>.loadbalancer.server.port=<port>

4. Don't `forwardPorts` the same port — Traefik replaces VS Code's
   port forwarding for that service.

When an overlay needs to expose more than one service, the primary
keeps `<project>.test`; secondaries use `<name>.<project>.test`.
Router/service names must remain unique across all containers
Traefik sees — use `<project>-<name>`.

Overlays that don't expose anything skip all of the above.

## Smoke tests

After `docker compose up -d` here:

- `curl -sv -L http://traefik.test/dashboard/` → 200, body
  contains "Traefik". If you get `Could not resolve host`, dnsmasq
  isn't running or the resolver file isn't in place — see
  Prerequisites.
- `docker compose logs traefik` → no errors, no "network not found"
  warnings.
- `docker compose down && docker compose up -d` → cycles cleanly.

After bringing up an overlay (e.g. rw or forgejo):

- `docker network inspect traefik` lists both the `traefik`
  container and the overlay's exposed service.
- `http://<project>.test` reaches the overlay's primary port
  (502 from Traefik when nothing is listening inside the
  container — that's correct).
- The dashboard shows a router named after the project with the
  expected `Host(...)` rule and backend.

## Operational notes

**Why `.test` and not `.localhost`.** Browsers and modern glibc
hardcode `*.localhost` to `127.0.0.1`/`::1` per RFC 6761,
*before* consulting NSS, Docker DNS, or `/etc/hosts`. That makes
Docker network aliases on `.localhost` unreachable from CLI tools
(curl, git) inside containers. `*.test` is RFC-reserved for the
same testing-purpose niche but has no such hardcoding — it routes
through normal DNS / NSS / `/etc/hosts`, so Docker DNS aliases
work as expected. The cost is the dnsmasq prerequisite. See
Prerequisites.

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

**Failure mode when Traefik is down.** `<project>.test` returns
connection refused. There is no `forwardPorts` fallback for
overlays that have committed to Traefik routing. Recovery:
`docker compose up -d` here.

**Cookies under `*.test`.** Apps should leave `Domain=` unset.
Some browsers and frameworks reject explicit `Domain=` values
that don't match a publicly-resolvable suffix.
