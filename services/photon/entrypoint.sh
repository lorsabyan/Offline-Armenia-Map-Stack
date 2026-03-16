#!/bin/bash
set -euo pipefail

NOMINATIM_HOST=${NOMINATIM_HOST:-nominatim}
NOMINATIM_PORT=${NOMINATIM_PORT:-5432}
NOMINATIM_DB=${NOMINATIM_DB:-nominatim}
NOMINATIM_USER=${NOMINATIM_USER:-nominatim}
NOMINATIM_PASSWORD=${NOMINATIM_PASSWORD:-nominatim}
# Warn if the password is a known insecure default
case "$NOMINATIM_PASSWORD" in
  nominatim|CHANGE_ME_BEFORE_FIRST_DEPLOY|"")
    echo "[photon-${PHOTON_INSTANCE:-?}] WARNING: NOMINATIM_PASSWORD is set to a default/placeholder value — change it for production!" >&2
    ;;
esac
PHOTON_LANGUAGES=${PHOTON_LANGUAGES:-en,hy,ru}
PHOTON_COUNTRY_CODES=${PHOTON_COUNTRY_CODES:-am}
PHOTON_DATA_DIR=${PHOTON_DATA_DIR:-/photon/photon_data}
TRIGGER_DIR=${TRIGGER_DIR:-/triggers}
POLL_INTERVAL=${POLL_INTERVAL:-30}
PHOTON_INSTANCE=${PHOTON_INSTANCE:-blue}
PHOTON_IMPORT_HEAP=${PHOTON_IMPORT_HEAP:-1g}
PHOTON_SERVE_HEAP=${PHOTON_SERVE_HEAP:-512m}

SERVER_PID=""
IMPORT_PID=""
UPDATE_IN_PROGRESS="${PHOTON_DATA_DIR}/.update-in-progress"
CRASH_COUNT=0
MAX_CRASH_RESTARTS=5

mkdir -p "$TRIGGER_DIR"

log() {
  echo "[photon-${PHOTON_INSTANCE}] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

write_status() {
  local state="$1" message="$2" progress="${3:-}"
  local ts last_update=""
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  last_update=$(cat "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.last_update" 2>/dev/null || true)
  local status_file="${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.status"
  local tmp_file="${status_file}.tmp.$$"
  # Use jq for proper JSON escaping; fall back to minimal JSON on failure
  # so a status-write error never crashes the service under set -e
  if ! jq -n --arg s "$state" --arg m "$message" --arg p "$progress" \
    --arg lu "$last_update" --arg ts "$ts" --arg inst "$PHOTON_INSTANCE" \
    '{state:$s,message:$m,progress:$p,last_update:$lu,updated_at:$ts,instance:$inst}' > "$tmp_file" 2>/dev/null; then
    printf '{"state":"%s","message":"status write degraded","updated_at":"%s","instance":"%s"}' \
      "${state//\"/\\\"}" "$ts" "${PHOTON_INSTANCE//\"/\\\"}" > "$tmp_file"
  fi
  mv -f "$tmp_file" "$status_file"
}

check_trigger() {
  [ -f "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.trigger" ]
}

consume_trigger() {
  rm -f "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.trigger"
}

wait_for_nominatim() {
  local max_attempts=180  # 180 × 10s = 30 min max wait
  local attempt=0
  log "Waiting for Nominatim at ${NOMINATIM_HOST}:8080 (max ${max_attempts} attempts)..."
  until curl -sf "http://${NOMINATIM_HOST}:8080/status" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_attempts" ]; then
      log "ERROR: Nominatim not available after ${max_attempts} attempts ($(( max_attempts * 10 ))s)"
      return 1
    fi
    log "Nominatim not ready yet, retrying in 10s (attempt ${attempt}/${max_attempts})..."
    sleep 10
  done
  log "Nominatim is ready"
}

do_import() {
  log "Starting Photon import from Nominatim"
  # Background + wait pattern allows cleanup trap to kill the import process
  java "-Xmx${PHOTON_IMPORT_HEAP}" "-Xms256m" -jar /photon/photon.jar import \
    -host "$NOMINATIM_HOST" \
    -port "$NOMINATIM_PORT" \
    -database "$NOMINATIM_DB" \
    -user "$NOMINATIM_USER" \
    -password "$NOMINATIM_PASSWORD" \
    -languages "$PHOTON_LANGUAGES" \
    -country-codes "$PHOTON_COUNTRY_CODES" \
    -data-dir "$PHOTON_DATA_DIR" &
  IMPORT_PID=$!
  wait "$IMPORT_PID"
  local rc=$?
  IMPORT_PID=""
  [ "$rc" -eq 0 ] || return 1
  log "Photon import complete"
}

start_server() {
  log "Starting Photon server on 0.0.0.0:2322"
  # CORS is handled by nginx; no -cors-any needed here
  java "-Xmx${PHOTON_SERVE_HEAP}" "-Xms128m" -jar /photon/photon.jar serve \
    -listen-ip 0.0.0.0 \
    -listen-port 2322 \
    -data-dir "$PHOTON_DATA_DIR" &
  SERVER_PID=$!
}

stop_server() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "Stopping Photon server (PID ${SERVER_PID})"
    kill "$SERVER_PID"
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

# Wait for server to become ready (polling loop with timeout)
wait_for_server() {
  local max_wait=${1:-60}
  local elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      return 1  # Process died
    fi
    if curl -sf "http://localhost:2322/api?q=test" >/dev/null 2>&1; then
      return 0  # Server is ready
    fi
  done
  return 1  # Timeout
}

cleanup() {
  log "Shutting down..."
  # Kill running import (if any) to avoid orphaned java process
  if [ -n "${IMPORT_PID:-}" ] && kill -0 "$IMPORT_PID" 2>/dev/null; then
    log "Killing running import (PID ${IMPORT_PID})"
    kill "$IMPORT_PID" 2>/dev/null
    wait "$IMPORT_PID" 2>/dev/null || true
    IMPORT_PID=""
  fi
  stop_server
  # If SIGTERM arrives mid-update, restore the backup so next start doesn't
  # trigger a slow full reimport.  This protects against `docker compose restart`
  # taking both instances offline while they reimport from scratch.
  if [ -f "$UPDATE_IN_PROGRESS" ]; then
    log "Update was in progress at shutdown"
    if [ ! -d "${PHOTON_DATA_DIR}/photon" ] && [ -d "${PHOTON_DATA_DIR}/photon.bak" ]; then
      log "Restoring index from backup (interrupted mid-update)"
      mv "${PHOTON_DATA_DIR}/photon.bak" "${PHOTON_DATA_DIR}/photon"
    fi
    rm -f "$UPDATE_IN_PROGRESS"
  fi
  exit 0
}
trap cleanup SIGINT SIGTERM

# ---------------------------------------------------------------------------
# Initial startup
# ---------------------------------------------------------------------------
# Clean up stale sentinel from previous unclean shutdown
if [ -f "$UPDATE_IN_PROGRESS" ]; then
  log "Detected stale update sentinel from previous run"
  if [ ! -d "${PHOTON_DATA_DIR}/photon" ] && [ -d "${PHOTON_DATA_DIR}/photon.bak" ]; then
    log "Restoring index from backup (previous update interrupted)"
    mv "${PHOTON_DATA_DIR}/photon.bak" "${PHOTON_DATA_DIR}/photon"
  fi
  rm -f "$UPDATE_IN_PROGRESS"
fi

wait_for_nominatim

if [ ! -d "${PHOTON_DATA_DIR}/photon" ]; then
  write_status "updating" "Initial import from Nominatim..." "importing"
  do_import
else
  log "Photon index already exists, skipping import"
fi

start_server
if wait_for_server 60; then
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.last_update"
  write_status "idle" "Serving queries"
else
  log "WARNING: Server did not become ready within 60s after startup"
  write_status "error" "Server not ready after startup"
fi

# ---------------------------------------------------------------------------
# Trigger polling loop
# On trigger: stop server → delete index → reimport → restart.
# nginx routes traffic to the other instance during this time
# (proxy_next_upstream), so zero requests are lost.
# ---------------------------------------------------------------------------
while true; do
  sleep "$POLL_INTERVAL"

  # Verify server is still alive (with crash counter and circuit breaker)
  if [ -n "${SERVER_PID:-}" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    CRASH_COUNT=$((CRASH_COUNT + 1))
    if [ "$CRASH_COUNT" -gt "$MAX_CRASH_RESTARTS" ]; then
      log "CRITICAL: Photon server crashed $CRASH_COUNT times, giving up (container will restart)"
      write_status "error" "Server crashed repeatedly, restarting container"
      exit 1
    fi
    log "ERROR: Photon server process died (attempt ${CRASH_COUNT}/${MAX_CRASH_RESTARTS}), restarting"
    write_status "error" "Server process died, restarting (attempt ${CRASH_COUNT})"
    stop_server  # Reap zombie if any
    start_server
    if wait_for_server 30; then
      write_status "idle" "Server restarted after crash"
      CRASH_COUNT=0
    else
      write_status "error" "Server failed to restart"
    fi
  fi

  # Check for manual update trigger
  if check_trigger; then
    log "Update triggered — reimporting (nginx failover active)"
    consume_trigger

    # Mark update in progress (sentinel for crash recovery)
    touch "$UPDATE_IN_PROGRESS"

    write_status "updating" "Stopping server for reimport..." "stopping"
    stop_server

    write_status "updating" "Waiting for Nominatim..." "importing"
    if ! wait_for_nominatim; then
      log "ERROR: Nominatim unavailable, aborting reimport"
      write_status "error" "Reimport aborted — Nominatim unavailable"
      rm -f "$UPDATE_IN_PROGRESS"
      start_server
      continue
    fi

    # Back up old index so we can restore on failure
    # Rename old .bak first (if exists) to avoid losing it between rm and mv
    write_status "updating" "Backing up old index..." "importing"
    if [ -d "${PHOTON_DATA_DIR}/photon" ]; then
      rm -rf "${PHOTON_DATA_DIR}/photon.bak"
      mv "${PHOTON_DATA_DIR}/photon" "${PHOTON_DATA_DIR}/photon.bak"
      log "Old index backed up to photon.bak"
    fi

    write_status "updating" "Reimporting from Nominatim..." "importing"
    if do_import; then
      start_server
      # Polling readiness check (up to 60 seconds) instead of fixed sleep
      if wait_for_server 60; then
        rm -rf "${PHOTON_DATA_DIR}/photon.bak"
        rm -f "$UPDATE_IN_PROGRESS"
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.last_update"
        write_status "idle" "Reimport complete, serving queries"
        log "Reimport complete, server verified and restarted"
      else
        # New index may be corrupt — restore backup
        log "WARNING: New index failed verification, restoring backup"
        stop_server
        rm -rf "${PHOTON_DATA_DIR}/photon"
        if [ -d "${PHOTON_DATA_DIR}/photon.bak" ]; then
          mv "${PHOTON_DATA_DIR}/photon.bak" "${PHOTON_DATA_DIR}/photon"
          log "Restored old index from backup after verification failure"
        fi
        rm -f "$UPDATE_IN_PROGRESS"
        start_server
        write_status "error" "Reimport produced bad index, restored previous"
      fi
    else
      # Restore old index from backup
      rm -rf "${PHOTON_DATA_DIR}/photon"
      if [ -d "${PHOTON_DATA_DIR}/photon.bak" ]; then
        mv "${PHOTON_DATA_DIR}/photon.bak" "${PHOTON_DATA_DIR}/photon"
        log "Restored old index from backup"
        write_status "error" "Reimport failed — restored previous index"
      else
        write_status "error" "Reimport failed — no index available"
      fi
      rm -f "$UPDATE_IN_PROGRESS"
      log "ERROR: Reimport failed, restarting with previous data"
      start_server
      # Error state persists until the next successful update
    fi
  fi
done
