# Traefik devcontainer routing — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared host-side Traefik stack at `~/devlab/traefik/` and wire the rw devcontainer overlay through it so services are reachable at `rw.localhost` instead of `localhost:7979`.

**Architecture:** Single Traefik container in its own compose stack, bound to host `:80`, configured with the Docker provider. An external Docker network `traefik` is created once; overlays opt in by joining it and adding routing labels. Rw is the first consumer; `dev` joins `traefik` (in addition to its existing `internal` network), gets four Traefik labels, and removes its `forwardPorts` entries.

**Tech Stack:** Docker, Docker Compose, Traefik v3.6, devpod (already used for rw).

**Spec:** `docs/superpowers/specs/2026-05-04-traefik-devcontainer-routing-design.md`

---

## File Structure

**New files:**
- `traefik/compose.yml` — Traefik service definition, dashboard router, external network declaration.
- `traefik/README.md` — Prerequisites, start/stop, dashboard URL, convention for new overlays, smoke tests, gotchas.

**Modified files:**
- `devcontainers/rw/compose.yml` — Add `name: rw` header, attach `dev` to the `traefik` network, add four Traefik labels on `dev`, declare the `traefik` external network at the bottom.
- `devcontainers/rw/devcontainer.json` — Remove `forwardPorts` entries for 7979, 8081, 8082.
- `devcontainers/rw/README.md` — Add a short "Access via rw.localhost" section noting the Traefik prerequisite.

Each file has one clear responsibility. `traefik/compose.yml` is shared infra and knows nothing about specific overlays. The rw overlay's three modifications are co-located in its existing folder.

---

## Verification approach

This is infrastructure config, not application code, so the spec's acceptance criteria stand in for unit tests. Each task uses a "baseline → change → verify" rhythm: first confirm the current behavior, then apply the change, then confirm the new behavior matches the spec. Where useful, the "baseline" step doubles as a failing-state check (e.g. `curl http://rw.localhost` fails *before* the labels exist; succeeds *after*).

---

## Task 1: Stand up the shared Traefik stack

**Files:**
- Create: `traefik/compose.yml`
- Test: `docker compose config`, `curl http://traefik.localhost/dashboard/`

- [ ] **Step 1.1: Confirm baseline — port 80 is free**

```bash
sudo lsof -i :80
```

Expected: empty output (no process listening on 80). If something is listening, stop it before continuing — Traefik must own port 80 for the design to work. Common culprits on macOS: another nginx/Caddy instance, a rogue Docker container.

- [ ] **Step 1.2: Confirm baseline — `traefik` network does not exist (or already exists from a prior attempt)**

```bash
docker network ls --filter name=^traefik$ --format '{{.Name}}'
```

Expected: empty (network doesn't exist yet) or `traefik` (already created from a prior attempt — fine, skip 1.3).

- [ ] **Step 1.3: Create the external `traefik` network**

```bash
docker network create traefik
```

Expected: prints a 64-char container ID. Re-running gives `Error response from daemon: network with name traefik already exists` — that's fine.

- [ ] **Step 1.4: Create `traefik/compose.yml`**

Write this exact file at `traefik/compose.yml` (relative to the repo root):

```yaml
# Shared host-side Traefik for devcontainer overlay hostnames.
#
# Each overlay that wants to expose a service joins the external `traefik`
# network and adds Traefik labels. This stack itself knows nothing about
# specific overlays — the Docker provider discovers them by label.
#
# Created the `traefik` network once with `docker network create traefik`.
# See README.md for the full convention and operational notes.

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
    networks:
      - traefik
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

- [ ] **Step 1.5: Validate the compose file**

```bash
docker compose -f traefik/compose.yml config
```

Expected: prints the resolved YAML with no errors. If it complains about the external network, re-run step 1.3.

- [ ] **Step 1.6: Bring the stack up**

```bash
docker compose -f traefik/compose.yml up -d
```

Expected: `traefik-traefik-1` (or similar) goes to `Started`. Then:

```bash
docker compose -f traefik/compose.yml ps
```

Expected: state `running`, no restarts.

- [ ] **Step 1.7: Verify the dashboard responds**

```bash
curl -sv -L http://traefik.localhost/dashboard/ -o /dev/null -w '%{http_code}\n'
```

Expected: `200`. The trailing slash on `/dashboard/` matters — without it Traefik returns 404. If you get `Could not resolve host`, the tool's resolver doesn't honor RFC 6761 for `*.localhost` (macOS libc, Node, sometimes curl depending on version). Fall back to `curl --resolve traefik.localhost:80:127.0.0.1 http://traefik.localhost/dashboard/`, or test from Chrome/Firefox.

- [ ] **Step 1.8: Verify clean logs**

```bash
docker compose -f traefik/compose.yml logs traefik 2>&1 | grep -iE 'error|warn' || echo "clean"
```

Expected: `clean`, or only benign provider-discovery info lines. No "network not found", no "permission denied" on the docker socket.

- [ ] **Step 1.9: Commit**

```bash
git add traefik/compose.yml
git commit -m "Add shared Traefik stack at ~/devlab/traefik/"
```

---

## Task 2: Write the Traefik stack README

**Files:**
- Create: `traefik/README.md`

- [ ] **Step 2.1: Create `traefik/README.md`**

Write this exact file at `traefik/README.md`:

```markdown
# Shared Traefik for devcontainer overlays

Single Traefik container that routes `*.localhost` to opted-in
devcontainer overlays. Each overlay declares its own hostname via
labels — this stack itself knows nothing about specific overlays.

## Prerequisite: create the external network (one time)

    docker network create traefik

Re-running is a no-op error. Compose stacks that declare
`traefik` as `external: true` will fail to start until this exists.

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
  contains "Traefik".
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
```

- [ ] **Step 2.2: Verify the file is well-formed**

```bash
test -s traefik/README.md && echo ok
```

Expected: `ok`.

- [ ] **Step 2.3: Commit**

```bash
git add traefik/README.md
git commit -m "Document shared Traefik stack: convention, smoke tests, notes"
```

---

## Task 3: Wire rw's `dev` service into Traefik

**Files:**
- Modify: `devcontainers/rw/compose.yml`

- [ ] **Step 3.1: Confirm baseline — `rw.localhost` does not respond**

With Traefik up but rw not yet wired in:

```bash
curl -sv http://rw.localhost -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: HTTP `404` from Traefik (no router matches the host) — the failing baseline.

- [ ] **Step 3.2: Add `name: rw` header to `devcontainers/rw/compose.yml`**

Top of file, before any existing comments. The current file starts with `# Compose stack for the rw devcontainer overlay.` — insert `name: rw` followed by a blank line at the very top:

```yaml
name: rw

# Compose stack for the rw devcontainer overlay.
# ...existing comments...
```

- [ ] **Step 3.3: Add `traefik` to the `dev` service's networks**

Locate the `dev:` service block. Find its `networks:` key (currently `- internal` only) and add `- traefik`:

```yaml
  dev:
    # ...existing keys...
    networks:
      - internal
      - traefik
    # ...
```

- [ ] **Step 3.4: Add the four Traefik labels on `dev`**

Add a `labels:` block to the `dev` service (it doesn't have one today). Place it adjacent to `networks:` for readability:

```yaml
  dev:
    # ...existing keys...
    networks:
      - internal
      - traefik
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik
      - traefik.http.routers.rw.rule=Host(`rw.localhost`)
      - traefik.http.services.rw.loadbalancer.server.port=7979
    # ...
```

- [ ] **Step 3.5: Declare the external `traefik` network**

At the bottom of the file, in the existing top-level `networks:` block, add the `traefik` entry alongside `internal` and `egress`:

```yaml
networks:
  internal:
    internal: true
  egress: {}
  traefik:
    name: traefik
    external: true
```

- [ ] **Step 3.6: Validate the modified compose file**

```bash
docker compose -f devcontainers/rw/compose.yml config > /dev/null && echo ok
```

Expected: `ok`. If it errors with "network traefik declared as external, but could not be found", run `docker network create traefik` (Task 1, step 1.3).

- [ ] **Step 3.7: Recreate the rw devcontainer**

Run from the *project workspace* directory (e.g. `~/projects/oss/rwdocs/rw`), **not** from the devlab repo — the overlay is symlinked into the project as `.devcontainer-rw` per the rw README:

```bash
cd ~/projects/oss/rwdocs/rw   # or wherever the rw project lives
devpod up . --recreate --devcontainer-path .devcontainer-rw/devcontainer.json
```

Expected: completes without error. If devpod is not in use yet, you can equivalently bring rw up directly from the devlab repo:

```bash
docker compose -f devcontainers/rw/compose.yml up -d
```

- [ ] **Step 3.8: Verify `dev` is on the `traefik` network**

```bash
docker network inspect traefik --format '{{range .Containers}}{{.Name}} {{end}}'
```

Expected: includes `traefik-traefik-1` *and* the rw `dev` container (name typically `rw-dev-1` or whatever devpod assigns).

- [ ] **Step 3.9: Verify Traefik picked up the router**

```bash
curl -s http://traefik.localhost/api/http/routers | grep -o '"name":"rw@docker"'
```

Expected: `"name":"rw@docker"`. If empty, check the dev container has `traefik.enable=true` set:

```bash
docker inspect $(docker ps --filter name=rw -q) --format '{{json .Config.Labels}}' | tr ',' '\n' | grep traefik
```

- [ ] **Step 3.10: Verify routing works**

```bash
curl -sv http://rw.localhost -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: HTTP `502` (Traefik reaches the container but nothing is listening on 7979 yet — the rw dev server isn't running). That's the correct baseline.

If something is running on 7979 inside the container (e.g. `cargo run` for the docs site), expect `200`.

- [ ] **Step 3.11: Commit**

```bash
git add devcontainers/rw/compose.yml
git commit -m "Wire rw dev container into shared Traefik (rw.localhost)"
```

---

## Task 4: Drop `forwardPorts` from rw's devcontainer.json

**Files:**
- Modify: `devcontainers/rw/devcontainer.json`

- [ ] **Step 4.1: Confirm baseline — `forwardPorts` currently lists three ports**

```bash
grep -n forwardPorts devcontainers/rw/devcontainer.json
```

Expected: one match showing `"forwardPorts": [7979, 8081, 8082],`. We're about to remove all three: 7979 because Traefik replaces it, and 8081/8082 because they aren't browser-facing day-to-day (per the spec's scope decision).

- [ ] **Step 4.2: Remove `forwardPorts` from `devcontainers/rw/devcontainer.json`**

Delete the entire `"forwardPorts": [7979, 8081, 8082],` line (and the trailing comma — adjust the comma on the preceding line if needed to keep the JSON valid).

After the change the relevant section looks like:

```json
{
  "name": "rw-personal",

  "dockerComposeFile": "compose.yml",
  "service": "dev",
  "workspaceFolder": "/workspace",
  "shutdownAction": "stopCompose",

  "remoteUser": "vscode",

  "postCreateCommand": "/usr/local/bin/rw-post-create.sh",

  "customizations": { ... }
}
```

- [ ] **Step 4.3: Validate the JSON parses**

```bash
python3 -c "import json,sys; json.load(open('devcontainers/rw/devcontainer.json')); print('ok')"
```

Expected: `ok`. (devcontainer.json technically allows comments but this file is pure JSON.)

- [ ] **Step 4.4: Recreate the rw devcontainer**

```bash
devpod up . --recreate --devcontainer-path .devcontainer-rw/devcontainer.json
```

Expected: completes; the workspace VS Code panel no longer lists 7979/8081/8082 under "Ports".

- [ ] **Step 4.5: Verify `localhost:7979` does not respond on the host**

```bash
curl -sv http://localhost:7979 -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: `Connection refused` or similar. If you get a 200/502 it means devpod still has a port-forward active — recreate the container or restart devpod.

- [ ] **Step 4.6: Verify `rw.localhost` still works**

```bash
curl -sv http://rw.localhost -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected: same as Task 3 step 3.10 — 502 (no app yet) or 200 (app running). Confirms Traefik is now the *only* path.

- [ ] **Step 4.7: Commit**

```bash
git add devcontainers/rw/devcontainer.json
git commit -m "Remove forwardPorts from rw devcontainer (Traefik replaces them)"
```

---

## Task 5: Update rw's README

**Files:**
- Modify: `devcontainers/rw/README.md`

- [ ] **Step 5.1: Add a short access section to `devcontainers/rw/README.md`**

Insert a new section between the existing "## Architecture" and "## Usage" sections (or wherever fits the existing flow best — preserve surrounding prose):

```markdown
## Access via `rw.localhost`

The dev container's primary port (7979) is reached at
<http://rw.localhost> via the shared Traefik proxy at
`~/devlab/traefik/`. Bring that stack up before bringing the
devcontainer up:

    cd ~/devlab/traefik
    docker compose up -d

If `rw.localhost` returns connection refused, Traefik isn't running.
If it returns 502, Traefik is running but the dev server inside the
container isn't (start it with the usual project command).

There are no `forwardPorts` for this overlay — Traefik is the only
path.
```

- [ ] **Step 5.2: Verify**

Open the file in a viewer or `grep` for the new heading:

```bash
grep -n '^## Access via' devcontainers/rw/README.md
```

Expected: one match.

- [ ] **Step 5.3: Commit**

```bash
git add devcontainers/rw/README.md
git commit -m "Document rw.localhost access in rw overlay README"
```

---

## Task 6: Final acceptance pass

This task runs every spec acceptance criterion in sequence. No code changes; if anything fails, return to the relevant earlier task and fix.

- [ ] **Step 6.1: Traefik stack alone**

```bash
docker network create traefik 2>&1 | grep -E 'already exists|^[0-9a-f]{12,}'
docker compose -f traefik/compose.yml up -d
docker compose -f traefik/compose.yml ps
curl -sv -L http://traefik.localhost/dashboard/ -o /dev/null -w '%{http_code}\n'
docker compose -f traefik/compose.yml logs traefik 2>&1 | grep -iE 'error|warn' || echo clean
docker compose -f traefik/compose.yml down
docker compose -f traefik/compose.yml up -d
```

All expected: success, 200 on dashboard, `clean` (or only benign info), no errors on cycle.

- [ ] **Step 6.2: rw end-to-end**

```bash
# (devpod up was already done in Task 3.7 / 4.4)
docker network inspect traefik --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
curl -sv http://rw.localhost -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
curl -s http://traefik.localhost/api/http/routers/rw@docker | python3 -m json.tool
curl -sv http://localhost:7979 -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected:
- network inspect lists both `traefik` and rw `dev` containers
- `rw.localhost` returns 502 (no listener) or 200 (app running)
- `routers/rw@docker` response shows `rule: Host(\`rw.localhost\`)` and a backend pointing to dev:7979
- `localhost:7979` returns connection refused

- [ ] **Step 6.3: Egress lockdown regression check (run inside the rw dev container)**

```bash
# From a shell inside the rw dev container:
curl -v https://example.com 2>&1 | grep -iE 'filtered|denied|connection' | head -3
curl -sv https://github.com 2>&1 | grep -iE 'http/' | head -1
getent hosts proxy
```

Expected:
- `example.com` blocked by tinyproxy (filtered)
- `github.com` succeeds (allowlisted)
- `proxy` resolves to a private (RFC 1918) address — confirms the existing dev↔proxy path on `internal` survived the network change. Docker user-defined bridges allocate from any RFC 1918 range (typically 172.16.0.0/12 but can be 10.x.x.x or 192.168.x.x), so don't assert on a specific prefix

- [ ] **Step 6.4: Negative tests**

```bash
docker compose -f traefik/compose.yml down
curl -sv http://rw.localhost -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
docker compose -f traefik/compose.yml up -d
sleep 2
curl -sv http://rw.localhost -o /dev/null -w '%{http_code}\n' 2>&1 | tail -3
```

Expected:
- with Traefik down: connection refused
- after restart: 502 or 200 again — confirms no hidden caching

Then test missing-network failure mode (only run if you're willing to recreate networks):

```bash
# Bring rw down first, then:
docker network rm traefik
docker compose -f devcontainers/rw/compose.yml up -d 2>&1 | grep -i 'network traefik'
# Restore:
docker network create traefik
docker compose -f traefik/compose.yml up -d
```

Expected: rw `compose up` fails with "network traefik declared as external, but could not be found" or similar — loud failure, not silent.

- [ ] **Step 6.5: No commit**

This task is verification-only. If everything passes, the implementation is complete. If anything fails, return to the relevant earlier task and fix before re-running this one.

---

## Notes on style and discipline

- **Frequent commits:** five commits across Tasks 1–5, one per logical unit. Don't squash mid-implementation.
- **YAGNI:** the spec explicitly defers HTTPS, dnsmasq, dashboard auth, loopback-only binding, and collision detection. Don't add any of these "while we're at it."
- **DRY:** the convention lives in `traefik/README.md` only — don't duplicate the four-label recipe into individual overlay READMEs. Overlay READMEs reference the convention; they don't re-state it.
- **Existing patterns:** `devcontainers/rw/compose.yml` already comments its design rationale near the top; preserve that style. New `traefik/compose.yml` does the same.
