# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Offline Armenia Map Stack — a fully self-hosted, offline-capable mapping platform for Armenia's 112 emergency system. Seven coordinated Docker containers provide tile rendering, geocoding, routing, and a reverse proxy with autonomous zero-downtime updates.

## Commands

### Run the full stack
```bash
docker compose up --build        # first boot takes ~40-50 min for data imports
docker compose up --build -d     # detached
docker compose down              # stop all services
```

### Test app development (no Docker needed)
```bash
python3 -m http.server 3001 --directory test-app
# Opens at http://localhost:3001
```

### Trigger data updates
```bash
./update.sh status               # show service status
./update.sh all --follow         # update all services with SSE progress
./update.sh osrm                 # update routing only
./update.sh photon               # update geocoding only
```

### Check service health
```bash
curl http://localhost/health
curl http://localhost/manager/status
curl http://localhost/metrics      # Prometheus metrics (private networks only)
```

## Architecture

### Services (docker-compose.yml)

| Service | Role | Key Detail |
|---------|------|------------|
| **tile-server** | Raster tile rendering | Minutely OSM diff replication |
| **nominatim** | Geocoding database | Geofabrik replication, internal only |
| **photon-blue/green** | Geocoding API (blue-green pair) | Imports from Nominatim, nginx failover |
| **osrm** | Routing engine | Shared-memory serving, atomic dataset swap |
| **manager** | Update orchestration | Python 3.13, data-change monitor, Prometheus metrics |
| **nginx** | Reverse proxy | Tile caching (2GB), CORS, blue-green routing |

### Update Flow (autonomous)
1. Tile server pulls OSM minutely diffs
2. Nominatim pulls Geofabrik replication (~15 min lag)
3. Manager polls Nominatim `/status` every 5 min, detects data changes
4. Manager auto-triggers Photon rolling update (blue first, then green) and OSRM re-download
5. Per-service cooldowns (default 1 hour) prevent rapid re-triggers

### Inter-Service Communication — Trigger File Protocol
Services coordinate via files on a shared `update-triggers` volume (no Docker socket needed):
- `{service}.trigger` — request update
- `{service}.status` — JSON state
- `{service}.last_update` — ISO timestamp
- `manager.rate_limits` — persisted cooldowns

### API Routes (nginx port 80)
- `/tiles/{z}/{x}/{y}.png` — cached raster tiles
- `/photon/api?q=...` — forward geocoding (blue-green failover)
- `/photon/reverse?lon=...&lat=...` — reverse geocoding
- `/osrm/route/v1/driving/{coords}` — routing
- `/osrm/nearest/v1/driving/{lon},{lat}` — snap to road
- `/manager/status` — service status JSON
- `/manager/update` (POST) — trigger updates
- `/manager/progress` — SSE real-time progress
- `/metrics` — Prometheus (RFC 1918 restricted)

## Key Files

- `services/manager/manager.py` — update orchestration, data-change monitor, HTTP API, Prometheus metrics (~887 lines Python)
- `services/osrm/entrypoint.sh` — OSRM download/process/serve with shared-memory zero-downtime swap
- `services/photon/entrypoint.sh` — Photon import/serve with index backup and rollback
- `services/nginx/nginx.conf` — reverse proxy, tile cache, blue-green failover, security headers
- `test-app/index.html` — MapLibre GL JS app with search, routing, reverse geocoding, 230 OSM Carto icons
- `update.sh` — CLI wrapper for manager API
- `monitoring/zabbix/zbx_template_offline_map.yaml` — Zabbix 6.4+ monitoring template

## Development Notes

- All external Docker images are pinned by SHA256 digest (including nginx); Photon JAR verified by SHA256
- Dual Docker network: `map-internal` (no internet) + `map-egress` (for data downloads)
- Manager, OSRM, and Photon run as non-root users; shared trigger volume is 0777 (3 UIDs)
- Manager entrypoint runs as root to fix volume permissions, then drops to non-root via `su-exec`
- nginx has rate limiting (3 zones), CSP headers, `server_tokens off`, security headers on all locations
- `/manager/` and `/metrics` restricted to RFC 1918 networks in nginx
- CORS only on read-only endpoints; mutation endpoint (`/update`) has no CORS
- OSRM and Photon have crash counters with 60s stability windows and circuit breakers
- Photon default language is Armenian (`hy`), country filter is `am`
- The manager uses HMAC constant-time comparison for `UPDATE_TOKEN` auth
- OSRM uses MLD algorithm by default; supports car/bike/foot profiles
- Tile cache uses `stale-while-revalidate` for uninterrupted serving during updates
- Rate limit state is persisted to the trigger volume (survives restarts, uses atomic temp+rename writes)
- Route lines rendered via SVG overlay (not MapLibre GL layers) for reliable display over raster tiles
- The test app stores map position/zoom in localStorage and has keyboard shortcuts (`/` search, `R` routing, `S` snap mode)
