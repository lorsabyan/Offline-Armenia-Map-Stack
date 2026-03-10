#!/bin/bash
set -euo pipefail

# On-demand map data update CLI
# Usage: ./update.sh [osrm|photon|all] [--follow]

MANAGER_URL="${MANAGER_URL:-http://localhost/manager}"
UPDATE_TOKEN="${UPDATE_TOKEN:-}"
SERVICE="${1:-all}"
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
  response=$(curl -sf "${MANAGER_URL}/status" 2>&1) || {
    echo "Error: Could not reach manager at ${MANAGER_URL}"
    echo "Make sure the Docker stack is running: docker compose up -d"
    exit 1
  }
  echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
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
response=$(curl "${CURL_ARGS[@]}" 2>&1) || {
  echo "Error: Could not reach manager at ${MANAGER_URL}"
  echo "Make sure the Docker stack is running: docker compose up -d"
  exit 1
}

echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"

# Follow progress
if [ "$FOLLOW" = true ]; then
  echo ""
  echo "Following progress (Ctrl+C to stop)..."
  curl -sf -N "${MANAGER_URL}/progress" 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
      ts=$(date +"%H:%M:%S")
      payload="${line#data: }"
      # Extract states for display
      osrm_state=$(echo "$payload" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('osrm',{}).get('state','?'))" 2>/dev/null || echo "?")
      photon_state=$(echo "$payload" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('photon',{}).get('state','?'))" 2>/dev/null || echo "?")
      osrm_msg=$(echo "$payload" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('osrm',{}).get('message',''))" 2>/dev/null || echo "")
      photon_msg=$(echo "$payload" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('photon',{}).get('message',''))" 2>/dev/null || echo "")
      echo "[$ts] OSRM: $osrm_state — $osrm_msg | Photon: $photon_state — $photon_msg"

      # Exit when all idle
      if [ "$osrm_state" = "idle" ] && [ "$photon_state" = "idle" ]; then
        echo ""
        echo "All updates complete."
        break
      fi
    fi
  done
fi
