#!/bin/bash
set -euo pipefail

NOMINATIM_HOST=${NOMINATIM_HOST:-nominatim}
NOMINATIM_PORT=${NOMINATIM_PORT:-5432}
NOMINATIM_DB=${NOMINATIM_DB:-nominatim}
NOMINATIM_USER=${NOMINATIM_USER:-nominatim}
NOMINATIM_PASSWORD=${NOMINATIM_PASSWORD:-nominatim}
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

mkdir -p "$TRIGGER_DIR"

log() {
  echo "[photon-${PHOTON_INSTANCE}] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

write_status() {
  local state="$1" message="$2" progress="${3:-}"
  local ts last_update=""
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -f "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.last_update" ] && \
    last_update=$(cat "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.last_update")
  local status_file="${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.status"
  local tmp_file="${status_file}.tmp.$$"
  # Use jq for proper JSON escaping; fall back to minimal JSON on failure
  # so a status-write error never crashes the service under set -e
  if ! jq -n --arg s "$state" --arg m "$message" --arg p "$progress" \
    --arg lu "$last_update" --arg ts "$ts" --arg inst "$PHOTON_INSTANCE" \
    '{state:$s,message:$m,progress:$p,last_update:$lu,updated_at:$ts,instance:$inst}' > "$tmp_file" 2>/dev/null; then
    printf '{"state":"%s","message":"status write degraded","updated_at":"%s","instance":"%s"}' \
      "$state" "$ts" "$PHOTON_INSTANCE" > "$tmp_file"
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
  java "-Xmx${PHOTON_SERVE_HEAP}" "-Xms128m" -jar /photon/photon.jar serve \
    -listen-ip 0.0.0.0 \
    -listen-port 2322 \
    -cors-any \
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
  if [ ! -d "${PHOTON_DATA_DIR}/photon" ] && [ -d "${PHOTON_DATA_DIR}/photon.bak" ]; then
    log "Restoring index from backup (interrupted mid-update)"
    mv "${PHOTON_DATA_DIR}/photon.bak" "${PHOTON_DATA_DIR}/photon"
  fi
  exit 0
}
trap cleanup SIGINT SIGTERM

# ---------------------------------------------------------------------------
# Initial startup
# ---------------------------------------------------------------------------
wait_for_nominatim

if [ ! -d "${PHOTON_DATA_DIR}/photon" ]; then
  write_status "updating" "Initial import from Nominatim..." "importing"
  do_import
else
  log "Photon index already exists, skipping import"
fi

start_server
date -u +"%Y-%m-%dT%H:%M:%SZ" > "${TRIGGER_DIR}/photon-${PHOTON_INSTANCE}.last_update"
write_status "idle" "Serving queries"

# ---------------------------------------------------------------------------
# Trigger polling loop
# On trigger: stop server → delete index → reimport → restart.
# nginx routes traffic to the other instance during this time
# (proxy_next_upstream), so zero requests are lost.
# ---------------------------------------------------------------------------
while true; do
  sleep "$POLL_INTERVAL"

  # Verify server is still alive
  if [ -n "${SERVER_PID:-}" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log "ERROR: Photon server process died, restarting"
    write_status "error" "Server process died, restarting"
    start_server
    sleep 5
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      write_status "idle" "Server restarted after crash"
    else
      write_status "error" "Server failed to restart"
    fi
  fi

  # Check for manual update trigger
  if check_trigger; then
    log "Update triggered — reimporting (nginx failover active)"
    consume_trigger

    write_status "updating" "Stopping server for reimport..." "stopping"
    stop_server

    write_status "updating" "Waiting for Nominatim..." "importing"
    if ! wait_for_nominatim; then
      log "ERROR: Nominatim unavailable, aborting reimport"
      write_status "error" "Reimport aborted — Nominatim unavailable"
      start_server
      continue
    fi

    # Back up old index so we can restore on failure
    write_status "updating" "Backing up old index..." "importing"
    rm -rf "${PHOTON_DATA_DIR}/photon.bak"
    if [ -d "${PHOTON_DATA_DIR}/photon" ]; then
      mv "${PHOTON_DATA_DIR}/photon" "${PHOTON_DATA_DIR}/photon.bak"
      log "Old index backed up to photon.bak"
    fi

    write_status "updating" "Reimporting from Nominatim..." "importing"
    if do_import; then
      start_server
      sleep 5
      # Verify the new server is responding before removing backup
      if kill -0 "$SERVER_PID" 2>/dev/null && \
         curl -sf "http://localhost:2322/api?q=test" >/dev/null 2>&1; then
        rm -rf "${PHOTON_DATA_DIR}/photon.bak"
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
      log "ERROR: Reimport failed, restarting with previous data"
      start_server
      # Error state persists until the next successful update
    fi
  fi
done
