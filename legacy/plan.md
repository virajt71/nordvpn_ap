# AP Manager — Rust API Spec

Replace `startup.sh` wizard w/ networked Rust API. Runs in Docker container. Remote mgmt over network (no local shell needed).

## Goal

Current: shell script, local-only, CLI wizard, tmpfile IPC.
Target: API/UI-driven, remote-controllable, Docker-native orchestrator for AP stacks (gluetun + hostapd + dnsmasq + AdGuard Home per stack).

## Architecture / Deployment

Rust backend = API server. Runs in own Docker container (orchestrator container). Exposes HTTP/WS port to host network → reachable from other machines on LAN.

```
[Remote machine] --HTTP/WS--> [Rust API container] --Docker socket--> [gluetun/hostapd/dnsmasq/adguard containers]
```

- Backend container: Rust binary only, minimal image (distroless or alpine + glibc shim)
- Docker socket (`/var/run/docker.sock`) mounted read-write into backend container → controls sibling containers via bollard, no shell exec needed
- Backend container joins host network mode (or bridge w/ published port) so API reachable externally
- Managed AP stacks (gluetun/hostapd/etc) remain separate containers, started/stopped by backend

## Stack

- **axum** — HTTP API + WS (log/status stream)
- **bollard** — Docker Engine API client (start/stop/inspect containers directly, no shell exec)
- **serde / serde_json** — config + API payloads
- **tokio** — async runtime
- **rusqlite** (or flat TOML) — stack state persistence
- **utoipa** (optional) — OpenAPI spec autogen
- **handlebars** or **askama** — Compose template rendering

Container = orchestrator sidecar. Controls other stacks via Docker socket. Does NOT embed gluetun/hostapd/dnsmasq itself.

## Data model

```rust
struct ApStack {
    id: String,              // stack identifier
    ssid: String,
    subnet: String,          // e.g. 10.10.x.0/24
    routing_table: u8,       // policy routing table id
    vpn_city: String,        // NordVPN location
    status: StackStatus,
    containers: Vec<String>, // gluetun, hostapd, dnsmasq, adguard container ids
}

enum StackStatus { Stopped, Starting, Running, Error(String) }
```

## API surface

```
GET    /stacks                    list all AP stacks + status
POST   /stacks                    create stack {ssid, subnet, vpn_city}
GET    /stacks/:id                stack detail (containers, IPs, uptime)
PATCH  /stacks/:id                update (e.g. change vpn_city → restart gluetun)
DELETE /stacks/:id                teardown stack, free subnet/routing table

POST   /stacks/:id/start
POST   /stacks/:id/stop
POST   /stacks/:id/restart

GET    /vpn/locations              NordVPN location list (replace fzf picker)
GET    /stacks/:id/clients          connected WiFi clients (dnsmasq leases)
GET    /stacks/:id/logs?tail=100    container logs
WS     /stacks/:id/logs/stream      live log tail

GET    /health                      API + Docker daemon reachability
```

## Shell script → Rust mapping

| shell script piece | Rust equivalent |
|---|---|
| fzf city picker | `GET /vpn/locations` → frontend dropdown |
| tmpfile IPC (`SELECTED_CITY`) | in-memory `Arc<Mutex<HashMap>>` or sqlite row, no file races |
| subshell env exports (SSID/subnet/table) | `ApStack` struct fields, validated on create (subnet/table collision check before allocate) |
| ESC-back nav | frontend routing concern only |
| Nord-themed terminal UI | optional web frontend, same API |

## Compose generation

Backend renders Compose YAML (or calls Docker Engine API per-container) from `ApStack` on `POST /stacks`. Templated via handlebars/askama — fill ssid/subnet/table/vpn_city. No static per-stack `docker-compose.yml` to maintain.

## Frontend

v1: skip custom UI. Ship OpenAPI spec, API usable via curl/httpie.
v2: single static HTML+JS file served by same axum instance at `/` — browser mgmt, no separate build step.

## Proposed workspace layout

```
ap-manager/
├── Cargo.toml            # workspace root
├── api/                  # axum server, routes, handlers
├── docker/               # bollard client wrapper, compose templating
├── templates/            # handlebars/askama compose templates
├── static/               # v2 web UI (single html/js)
├── Dockerfile
└── docker-compose.yml    # orchestrator's own container def
```

## Open items / next steps

- Dockerfile (multi-stage, Rust binary + docker CLI/socket mount)
- subnet/routing-table allocator (avoid collisions across stacks)
- auth on API (currently shell script had none — need at least token/basic auth since now network-exposed)