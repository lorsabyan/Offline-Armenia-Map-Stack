#!/bin/bash
set -euo pipefail

OSRM_DATA_DIR=${OSRM_DATA_DIR:-/var/osrm}
OSM_DOWNLOAD_DIR=${OSM_DOWNLOAD_DIR:-/osm}
OSM_PBF_URL=${OSM_PBF_URL:-https://download.geofabrik.de/asia/armenia-latest.osm.pbf}
DATA_UPDATE_INTERVAL=${DATA_UPDATE_INTERVAL:-86400}
OSRM_PROFILE=${OSRM_PROFILE:-car}
OSRM_ALGORITHM=${OSRM_ALGORITHM:-mld}
OSRM_MAX_MATCHING_SIZE=${OSRM_MAX_MATCHING_SIZE:-100}
OSRM_MAX_TABLE_SIZE=${OSRM_MAX_TABLE_SIZE:-1000}
OSRM_PORT=${OSRM_PORT:-5000}
OSRM_DATASET_NAME=${OSRM_DATASET_NAME:-osrm_live}
TRIGGER_DIR=${TRIGGER_DIR:-/triggers}
POLL_INTERVAL=${POLL_INTERVAL:-30}

PBF_BASENAME=$(basename "$OSM_PBF_URL")
PBF_PATH="${OSM_DOWNLOAD_DIR}/${PBF_BASENAME}"
OSRM_BASENAME=${OSRM_BASENAME:-${PBF_BASENAME%%.osm.pbf}}
OSRM_BASE_PATH="${OSRM_DATA_DIR}/${OSRM_BASENAME}.osrm"

SERVER_PID=""
UPDATE_PID=""

mkdir -p "$OSRM_DATA_DIR" "$OSM_DOWNLOAD_DIR" "$TRIGGER_DIR"

log() {
  echo "[osrm] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

write_status() {
  local state="$1" message="$2" progress="${3:-}"
  local ts last_update=""
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -f "${TRIGGER_DIR}/osrm.last_update" ] && last_update=$(cat "${TRIGGER_DIR}/osrm.last_update")
  local status_file="${TRIGGER_DIR}/osrm.status"
  local tmp_file="${status_file}.tmp.$$"
  # Use jq for proper JSON escaping; fall back to minimal JSON on failure
  # so a status-write error never crashes the service under set -e
  if ! jq -n --arg s "$state" --arg m "$message" --arg p "$progress" \
    --arg lu "$last_update" --arg ts "$ts" \
    '{state:$s,message:$m,progress:$p,last_update:$lu,updated_at:$ts}' > "$tmp_file" 2>/dev/null; then
    printf '{"state":"%s","message":"status write degraded","updated_at":"%s"}' "$state" "$ts" > "$tmp_file"
  fi
  mv -f "$tmp_file" "$status_file"
}

check_trigger() {
  [ -f "${TRIGGER_DIR}/osrm.trigger" ]
}

consume_trigger() {
  rm -f "${TRIGGER_DIR}/osrm.trigger"
}

verify_pbf_md5() {
  # Geofabrik publishes .md5 files alongside PBF extracts
  local file="$1"
  local md5_url="${OSM_PBF_URL}.md5"
  local md5_file="${file}.md5"

  if curl -fsSL -o "$md5_file" "$md5_url" 2>/dev/null; then
    local expected actual
    expected=$(awk '{print $1}' "$md5_file")
    rm -f "$md5_file"
    # Validate MD5 hash format (must be 32 hex chars)
    if [ -z "$expected" ] || ! echo "$expected" | grep -qE '^[0-9a-fA-F]{32}$'; then
      log "WARNING: MD5 file has unexpected format, skipping verification"
      return 0
    fi
    actual=$(md5sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
      log "ERROR: MD5 mismatch — download corrupted (expected=$expected, got=$actual)"
      return 1
    fi
    log "MD5 checksum verified"
  else
    rm -f "$md5_file"
    log "WARNING: MD5 checksum not available from server, skipping verification"
  fi
  return 0
}

download_pbf() {
  local tmp_file="${PBF_PATH}.incoming"
  if [ -f "$PBF_PATH" ]; then
    log "Checking for newer extract"
    if curl -fsSL -z "$PBF_PATH" -o "$tmp_file" "$OSM_PBF_URL"; then
      if [ -s "$tmp_file" ]; then
        if verify_pbf_md5 "$tmp_file"; then
          mv "$tmp_file" "$PBF_PATH"
          log "Downloaded updated extract"
          return 0
        else
          rm -f "$tmp_file"
          log "ERROR: Downloaded extract failed integrity check"
          return 2
        fi
      else
        rm -f "$tmp_file"
        log "No newer extract available"
        return 1
      fi
    else
      rm -f "$tmp_file"
      log "Failed to refresh extract"
      return 2
    fi
  else
    log "Fetching first extract from $OSM_PBF_URL"
    if curl -fsSL -o "$tmp_file" "$OSM_PBF_URL"; then
      if verify_pbf_md5 "$tmp_file"; then
        mv "$tmp_file" "$PBF_PATH"
        return 0
      else
        rm -f "$tmp_file"
        log "ERROR: Initial extract failed integrity check"
        return 2
      fi
    else
      rm -f "$tmp_file"
      log "ERROR: Failed to download initial extract"
      return 2
    fi
  fi
}

prepare_osrm() {
  log "Preparing OSRM data using ${OSRM_PROFILE} profile (${OSRM_ALGORITHM})"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  # osrm-extract creates output files next to the input PBF, so copy PBF to tmp dir
  local tmp_pbf="${tmp_dir}/${OSRM_BASENAME}.osm.pbf"
  cp "$PBF_PATH" "$tmp_pbf"
  local tmp_base="${tmp_dir}/${OSRM_BASENAME}.osrm"

  nice -n 10 ionice -c 2 -n 7 osrm-extract -p "/opt/${OSRM_PROFILE}.lua" "$tmp_pbf"
  if [ "$OSRM_ALGORITHM" = "mld" ]; then
    nice -n 10 ionice -c 2 -n 7 osrm-partition "$tmp_base"
    nice -n 10 ionice -c 2 -n 7 osrm-customize "$tmp_base"
  else
    nice -n 10 ionice -c 2 -n 7 osrm-contract "$tmp_base"
  fi

  log "Switching active dataset"
  for artifact in "$tmp_dir"/"${OSRM_BASENAME}".osrm*; do
    [ -e "$artifact" ] || continue
    local name target
    name=$(basename "$artifact")
    target="${OSRM_DATA_DIR}/${name}"
    mv -f "$artifact" "${target}.next"
    mv -f "${target}.next" "$target"
  done
  touch "${OSRM_BASE_PATH}.timestamp"
  trap - RETURN
  rm -rf "$tmp_dir"
  log "OSRM dataset ready"
}

load_data() {
  log "Loading OSRM data into shared memory (dataset: ${OSRM_DATASET_NAME})"
  osrm-datastore "$OSRM_BASE_PATH" --dataset-name "$OSRM_DATASET_NAME"
  log "Shared memory loaded"
}

start_server() {
  log "Starting osrm-routed on port ${OSRM_PORT} (shared memory mode)"
  osrm-routed \
    --shared-memory \
    --dataset-name "$OSRM_DATASET_NAME" \
    --algorithm "$OSRM_ALGORITHM" \
    --max-matching-size "$OSRM_MAX_MATCHING_SIZE" \
    --max-table-size "$OSRM_MAX_TABLE_SIZE" \
    --port "$OSRM_PORT" \
    --ip 0.0.0.0 &
  SERVER_PID=$!
}

stop_server() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "Stopping osrm-routed"
    kill "$SERVER_PID"
    wait "$SERVER_PID" || true
  fi
}

schedule_updates() {
  (
    write_status "idle" "Waiting for next update cycle"

    while true; do
      # Poll every POLL_INTERVAL seconds; break early on manual trigger
      local elapsed=0
      local triggered=false
      while [ "$elapsed" -lt "$DATA_UPDATE_INTERVAL" ]; do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        if check_trigger; then
          log "Manual update triggered"
          consume_trigger
          triggered=true
          break
        fi
      done
      if [ "$triggered" = false ]; then
        log "Scheduled update interval reached"
      fi

      write_status "updating" "Downloading latest extract..." "downloading"
      local dl_result=0
      download_pbf || dl_result=$?

      if [ "$dl_result" -eq 0 ]; then
        # New data downloaded successfully
        write_status "updating" "Processing OSRM data..." "processing"
        if prepare_osrm; then
          write_status "updating" "Loading into shared memory..." "loading"
          if load_data; then
            date -u +"%Y-%m-%dT%H:%M:%SZ" > "${TRIGGER_DIR}/osrm.last_update"
            write_status "idle" "Update complete"
            log "OSRM data reloaded — zero-downtime update complete"
          else
            write_status "error" "Failed to load data into shared memory"
            log "ERROR: osrm-datastore failed, keeping previous dataset"
          fi
        else
          write_status "error" "Data preparation failed"
          log "ERROR: OSRM data preparation failed, keeping previous dataset"
        fi
      elif [ "$dl_result" -eq 1 ]; then
        # No newer data available — normal, not an error
        write_status "idle" "No newer extract available"
      else
        # Download failed — error
        write_status "error" "Download failed — check network connectivity"
        log "ERROR: Download failed (exit code $dl_result)"
      fi
    done
  ) &
  UPDATE_PID=$!
}

# Kill the update subshell's entire process group to avoid orphaning
# child processes (curl, osrm-extract, etc.) during docker compose restart
trap 'stop_server; [ -n "${UPDATE_PID:-}" ] && kill -- -"$UPDATE_PID" 2>/dev/null; wait; exit 0' SIGINT SIGTERM

download_pbf || true
if [ ! -s "$PBF_PATH" ]; then
  log "OSM extract not available at $PBF_PATH"
  exit 1
fi
if [ ! -f "$OSRM_BASE_PATH" ]; then
  prepare_osrm
fi

load_data
date -u +"%Y-%m-%dT%H:%M:%SZ" > "${TRIGGER_DIR}/osrm.last_update"
write_status "idle" "Service started, data loaded"
start_server
schedule_updates

# Monitor server; restart in-process on crash (faster than full container restart)
while true; do
  wait "$SERVER_PID" || true
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log "WARNING: osrm-routed crashed, restarting..."
    write_status "error" "Server crashed, restarting"
    start_server
    sleep 5
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      write_status "idle" "Server restarted after crash"
    fi
  fi
done
