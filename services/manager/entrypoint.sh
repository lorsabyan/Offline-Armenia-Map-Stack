#!/bin/sh
# Fix shared trigger volume permissions before dropping to non-root user.
# Three different UIDs (manager, osrm, photon) need write access.
if [ -d "${TRIGGER_DIR:-/triggers}" ]; then
  chmod 777 "${TRIGGER_DIR:-/triggers}" 2>/dev/null || true
fi
exec su-exec manager python manager.py
