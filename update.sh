#!/bin/bash
set -euo pipefail

# On-demand map data update CLI
# Usage: ./update.sh [osrm|photon|all] [--follow]

MANAGER_URL="${MANAGER_URL:-http://localhost/manager}"
UPDATE_TOKEN="${UPDATE_TOKEN:-}"
SERVICE="all"
FOLLOW=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [SERVICE] [OPTIONS]

Trigger an on-demand map data update.

Services:
  osrm      Update routing data (download latest extract + reprocess)
  photon    Update geocoding index (reimport from Nominatim)
  all       Update both OSRM and Photon (default)
  status    Show current update status

Options:
  --follow  Stream progress updates after triggering

Environment:
  MANAGER_URL   Base URL of the manager API (default: http://localhost/manager)
  UPDATE_TOKEN  Bearer token for manager authentication (if configured)
EOF
  exit 0
}

# Parse args
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    --follow)  FOLLOW=true ;;
    status|osrm|photon|all) SERVICE="$arg" ;;
    *) echo "Unknown argument: $arg"; usage ;;
  esac
done

# Status command
if [ "$SERVICE" = "status" ]; then
  echo "Fetching update status..."
  response=$(curl -sf "${MANAGER_URL}/status") || {
    echo "Error: Could not reach manager at ${MANAGER_URL}"
    echo "Make sure the Docker stack is running: docker compose up -d"
    exit 1
  }
  printf '%s\n' "$response" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$response"
  exit 0
fi

# Build service list
case "$SERVICE" in
  all)    svc_json='["osrm","photon"]' ;;
  osrm)   svc_json='["osrm"]' ;;
  photon) svc_json='["photon"]' ;;
  *)
    echo "Error: Unknown service '$SERVICE'. Valid: osrm, photon, all, status"
    exit 1
    ;;
esac

echo "Triggering update for: $SERVICE"
CURL_ARGS=(-sf -X POST "${MANAGER_URL}/update" -H "Content-Type: application/json")
if [ -n "$UPDATE_TOKEN" ]; then
  CURL_ARGS+=(-H "Authorization: Bearer ${UPDATE_TOKEN}")
fi
CURL_ARGS+=(-d "{\"services\": ${svc_json}, \"source\": \"cli\"}")
response=$(curl "${CURL_ARGS[@]}") || {
  echo "Error: Could not reach manager at ${MANAGER_URL}"
  echo "Make sure the Docker stack is running: docker compose up -d"
  exit 1
}

printf '%s\n' "$response" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$response"

# Follow progress
if [ "$FOLLOW" = true ]; then
  echo ""
  echo "Following progress (Ctrl+C to stop)..."
  # Use process substitution to detect curl exit and capture PIPESTATUS
  curl -sf -N "${MANAGER_URL}/progress" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      data:*)
        ts=$(date +"%H:%M:%S")
        payload="${line#data: }"
        # Single python3 invocation to parse all fields at once
        read -r osrm_state photon_state osrm_msg photon_msg < <(
          printf '%s\n' "$payload" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(
        d.get('osrm',{}).get('state','?'),
        d.get('photon',{}).get('state','?'),
        d.get('osrm',{}).get('message',''),
        d.get('photon',{}).get('message',''),
    )
except Exception:
    print('? ? ? ?')
" 2>/dev/null
        ) || { osrm_state="?"; photon_state="?"; osrm_msg=""; photon_msg=""; }
        echo "[$ts] OSRM: $osrm_state — $osrm_msg | Photon: $photon_state — $photon_msg"

        # Exit when all idle
        if [ "$osrm_state" = "idle" ] && [ "$photon_state" = "idle" ]; then
          echo ""
          echo "All updates complete."
          break
        fi
        ;;
    esac
  done
  # Check if curl disconnected unexpectedly
  if [ "${PIPESTATUS[0]:-0}" -ne 0 ]; then
    echo "Warning: progress stream disconnected"
  fi
fi
