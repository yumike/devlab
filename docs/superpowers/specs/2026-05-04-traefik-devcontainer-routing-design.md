# Design: Traefik reverse proxy for devcontainer hostnames

**Status:** Proposed
**Date:** 2026-05-04
**Scope:** Add a shared, host-side Traefik stack to `~/devlab/` and wire the existing `rw` devcontainer overlay through it so services are reachable at `rw.localhost` instead of `localhost:7979`. Establish a convention future overlays follow.

## Problem

Devcontainers in `~/devlab/devcontainers/` currently surface their services through VS Code's `forwardPorts`, which gives URLs like `localhost:7979`. As more overlays appear, ports collide, URLs are forgettable, and there is no consistent way to know which port belongs to which overlay. We want hostname-based access — `rw.localhost`, `<other-overlay>.localhost`, etc. — routed by a single reverse proxy on the host.

## Goals

- One memorable hostname per devcontainer overlay that exposes a service.
- Multiple overlays can run simultaneously without port-conflict gymnastics.
- New overlays opt in by adding labels; the shared infra never needs to know about them.
- Existing rw egress lockdown (tinyproxy on `internal`/`egress`) is preserved unchanged.

## Non-goals

- HTTPS / certificates. HTTP-only on `*.localhost`; browsers treat `localhost` as a secure context.
- DNS resolution outside browsers. Chrome/Firefox/Edge handle `*.localhost` via RFC 6761; Safari/curl/Node will not work without follow-on dnsmasq setup, which is documented but out of scope.
- Auth on the Traefik dashboard.
- Auto-discovery / auto-routing magic. Routing is explicit per overlay.
- Multi-overlay duplicate-hostname detection beyond Traefik's own warnings.

## Architecture

```
                       Mac host
   ┌─────────────────────────────────────────────────────┐
   │ browser hits rw.localhost / traefik.localhost       │
   │              ↓ (RFC 6761 → 127.0.0.1)               │
   │         Traefik :80 (published)                     │
   └────────────────┬────────────────────────────────────┘
                    │  Docker network: traefik (external)
       ┌────────────┼─────────────────────────────────────┐
       │            │                                     │
   ┌───▼────┐   ┌───▼────────┐                  ┌────────▼────────┐
   │traefik │   │rw dev svc  │   (future        │other overlay's  │
   │ stack  │   │(opted in   │    overlays      │primary service) │
   │        │   │ via labels)│    join here)    │                 │
   └────────┘   └─────┬──────┘                  └─────────────────┘
                      │ also on `internal` (egress-locked, unchanged)
                      ▼
                   tinyproxy
```

- A **single shared Traefik** lives in its own compose stack at `~/devlab/traefik/`, publishes `:80`, and reads container labels via the Docker provider.
- An **external Docker network `traefik`** is created once with `docker network create traefik`. Every overlay that wants to expose anything joins it (in addition to whatever internal networks it already uses).
- **Each overlay decides for itself** whether to expose a service. No labels = no routing, which is a valid configuration. Overlays that opt in declare a `Host(...)` rule and the target port via labels.
- The rw overlay's existing `internal` and `egress` networks are untouched. The `dev` service (currently on `internal` only) gains a second network attachment to `traefik`; the `proxy` service (on `internal` + `egress`) is unchanged. The egress lockdown via tinyproxy is unrelated to inbound routing and stays as-is.

## Components

### New: `~/devlab/traefik/`

```
~/devlab/traefik/
├── compose.yml      # traefik service, publishes :80, joins `traefik` network
└── README.md        # start/stop, dashboard URL, convention for new overlays, smoke tests
```

`compose.yml`:

```yaml
name: traefik

services:
  traefik:
    image: traefik:v3.6
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=traefik
      - --entrypoints.web.address=:80
      - --api.dashboard=true
    ports:
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [traefik]
    labels:
      - traefik.enable=true
      - traefik.http.routers.dashboard.rule=Host(`traefik.localhost`)
      - traefik.http.routers.dashboard.service=api@internal
    restart: unless-stopped

networks:
  traefik:
    name: traefik
    external: true
```

- Image: `traefik:v3.6` — floating minor track is the default, matching the rw overlay's `BASE_TAG=latest` convention. Bit-reproducibility is the documented escape hatch: pin to `v3.6.15` (current latest) or a `@sha256:` digest. Implementation should ship the floating `v3.6` tag; the README documents how to pin.
- `exposedbydefault=false` so a stray container with the Docker label set doesn't accidentally get a route.
- `providers.docker.network=traefik` is the Traefik-side default; per-service `traefik.docker.network=traefik` labels on overlays remain authoritative when a container is on multiple networks.
- The `traefik` network is created once, by hand, before first `compose up`:

  ```bash
  docker network create traefik
  ```

### Changed: `~/devlab/devcontainers/rw/compose.yml`

Three deltas, all on the `dev` service plus the file header:

1. Add `name: rw` at the top so the compose project name is explicit (not directory-inferred).
2. `dev` joins the `traefik` network in addition to `internal`.
3. `dev` gains four Traefik labels exposing port 7979 as `rw.localhost`.

Sketch (only changed bits shown — every other key on `dev` stays identical):

```yaml
name: rw

services:
  dev:
    networks:
      - internal
      - traefik
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik
      - traefik.http.routers.rw.rule=Host(`rw.localhost`)
      - traefik.http.services.rw.loadbalancer.server.port=7979
    # ...rest unchanged

networks:
  internal:
    internal: true
  egress: {}
  traefik:
    name: traefik
    external: true
```

The `proxy` (tinyproxy) service stays on `internal` + `egress` only — it is not exposed via Traefik.

### Changed: `~/devlab/devcontainers/rw/devcontainer.json`

`forwardPorts` drops all three entries (7979, 8081, 8082). 7979 is now reached via `rw.localhost`. 8081 and 8082 are dropped from the overlay entirely; they were not actively used in a browser. If a future need surfaces, they can be added back as `forwardPorts` or as additional Traefik routers.

### Changed: `~/devlab/devcontainers/rw/README.md`

A short "Access via `rw.localhost`" section pointing to the Traefik stack and noting the prerequisite (`docker compose up -d` in `~/devlab/traefik/` and the `traefik` network must exist).

## Convention for future overlays

Documented in `~/devlab/traefik/README.md`. Any overlay that wants to expose a service follows these steps:

1. **Set compose `name:`** at the top of `compose.yml` (e.g. `name: foo`). Don't rely on directory-name inference.
2. **Join the `traefik` external network.** Add `traefik` to the service's `networks:` list and declare it at the bottom as `external: true, name: traefik`. Other networks coexist.
3. **Add four labels** on the service that should receive traffic:

   ```yaml
   - traefik.enable=true
   - traefik.docker.network=traefik
   - traefik.http.routers.<project>.rule=Host(`<project>.localhost`)
   - traefik.http.services.<project>.loadbalancer.server.port=<port>
   ```

   Router/service names are global across all containers Traefik sees, so naming them after the project keeps them unique.
4. **Don't `forwardPorts`** the same port — Traefik replaces VS Code's port forwarding for that service. Other ports (rare) can still be forwarded if direct access is genuinely needed.

When a single overlay needs to expose more than one service, the primary keeps `<project>.localhost`; secondaries use `<name>.<project>.localhost`. Router/service names must remain unique — use `<project>-<name>`.

Devcontainers that don't expose anything skip all of the above.

## Operational notes

These get baked into `~/devlab/traefik/README.md` so they're not folklore.

**DNS resolution.** Chrome, Firefox, Edge, Arc resolve `*.localhost` to 127.0.0.1 (RFC 6761). Safari, `curl` < 7.85, Node `fetch`, and most native CLIs that go through libc do not. The escape hatch is `brew install dnsmasq` + `/etc/resolver/localhost` mapping `.localhost` to `127.0.0.1`. Documented as a known limitation, not a defect.

**Port 80 conflicts.** `sudo lsof -i :80` before first start. macOS doesn't normally listen on 80, but a stray nginx/Caddy or Apple Web Sharing can. Don't move Traefik off 80 — that defeats the point of clean URLs.

**Dashboard exposure.** `http://traefik.localhost/dashboard/` (trailing slash matters) reaches `api@internal` unauthenticated. Acceptable here because Docker Desktop binds published ports to `0.0.0.0` only by default and our threat model is a single-developer laptop. If the laptop ever lives on a hostile network or has multiple users, switch to `127.0.0.1:80:80` binding or add a `BasicAuth` middleware. Documented in README; not implemented now.

**`traefik` network creation.** Created once with `docker network create traefik`. If it doesn't exist, `compose up` on any overlay using `external: true` fails with a clear "network traefik declared as external, but could not be found" error. The README has the create command at the top.

**Don't put `rw`'s `proxy` (tinyproxy) on the `traefik` network.** It is inbound-only. The egress lockdown is orthogonal and stays via `internal` + `egress`.

**Devcontainer rebuild.** Because `traefik` is declared in `compose.yml` (not `runArgs`), `devpod up --recreate` reattaches automatically.

**Failure mode when Traefik is down.** `rw.localhost` returns connection refused. There is no `forwardPorts` fallback anymore. Recovery: `cd ~/devlab/traefik && docker compose up -d`.

**Cookies.** Apps under `*.localhost` should leave `Domain=` unset. Some browsers refuse explicit `Domain=.localhost`. Worth a one-liner in the README; nothing to configure on the Traefik side.

## Acceptance criteria

These also live in `~/devlab/traefik/README.md` as a smoke-test section.

**Traefik stack alone**

1. `docker network create traefik` succeeds (or already exists).
2. `cd ~/devlab/traefik && docker compose up -d` brings `traefik` up healthy.
3. `curl -sv http://traefik.localhost/dashboard/` returns 200 (or 308 then 200 with `-L`); HTML contains "Traefik".
4. `docker compose logs traefik` shows no errors and no warnings about missing networks.
5. `docker compose down && docker compose up -d` cycles cleanly.

**rw overlay end-to-end**

1. With Traefik up, `devpod up . --devcontainer-path .devcontainer-rw/devcontainer.json --recreate` succeeds.
2. `docker network inspect traefik` shows both the `traefik` container and the rw `dev` container attached.
3. From the host browser, `http://rw.localhost` reaches whatever runs on rw's primary port. With nothing listening inside the container, Traefik returns 502 — that's correct.
4. The Traefik dashboard shows a router named `rw` with rule `Host(\`rw.localhost\`)` and a backend pointing to the rw `dev` container on port 7979.
5. `http://localhost:7979` does **not** respond — confirms Traefik is the single path.

**Egress lockdown regression check**

1. Inside the dev container, `curl -v https://example.com` → blocked by tinyproxy (existing behavior).
2. `curl -v https://github.com` → succeeds (allowlisted).
3. `getent hosts proxy` resolves to an `internal` network address — confirms the existing dev↔proxy path on `internal` survived the network change.

**Negative tests**

1. Stop Traefik; `http://rw.localhost` fails with connection refused. Bring it back; works again. No hidden caching.
2. Bring up rw without first creating the `traefik` network — compose fails with the "external network not found" error. Failure is loud, not silent.
3. Two overlays declaring the same `Host(\`rw.localhost\`)` while both up — Traefik logs a duplicate-router warning and picks one. Documented as "don't do that"; no automated guard.

## Open questions / explicitly out of scope

- **HTTPS / mkcert.** Add when a concrete need surfaces (Secure cookies, service workers requiring `https://`, prod parity).
- **dnsmasq for Safari & native CLIs.** Add when Safari or a non-browser tool becomes necessary.
- **Dashboard auth.** Add if the laptop's network model changes.
- **Loopback-only port binding.** Same trigger as dashboard auth.
- **Multi-overlay hostname collision detection.** Traefik's logs are the only signal today.
