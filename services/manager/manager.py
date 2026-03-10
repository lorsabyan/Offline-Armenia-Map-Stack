#!/usr/bin/env python3
"""Lightweight map update manager API.

Manages on-demand updates for OSRM and Photon via trigger files
on a shared Docker volume.  No Docker socket needed.

Photon uses blue-green deployment: two instances behind nginx.
The manager triggers them sequentially (rolling update) so one
is always serving traffic.

Endpoints:
  GET  /status    — JSON status of all services
  POST /update    — trigger update for specified services
  GET  /progress  — SSE stream of status changes
  GET  /metrics   — Prometheus exposition format metrics
"""

import hmac
import json
import os
import sys
import time
import threading
import tempfile
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

TRIGGER_DIR = os.environ.get("TRIGGER_DIR", "/triggers")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8000"))
UPDATE_TOKEN = os.environ.get("UPDATE_TOKEN", "")

UPDATABLE = {"osrm", "photon"}
PHOTON_INSTANCES = ["blue", "green"]
AUTO_SERVICES = {
    "tile_server": "Auto-updates via minutely diffs",
    "nominatim": "Auto-updates via replication URL",
}

# Rate limiting: min seconds between update requests per service
RATE_LIMIT_SECONDS = int(os.environ.get("RATE_LIMIT_SECONDS", "60"))
_last_trigger_time = {}  # service -> wall-clock timestamp (for persistence)
RATE_LIMIT_FILE = os.path.join(TRIGGER_DIR, "manager.rate_limits")

# Serializes the entire check-rate-limit → trigger → record-time path
# so two concurrent POST /update requests cannot both pass the rate limit
# check and double-trigger the same service.
_update_lock = threading.Lock()

# SSE connection limits
MAX_SSE_CONNECTIONS = int(os.environ.get("MAX_SSE_CONNECTIONS", "20"))
SSE_TIMEOUT_SECONDS = int(os.environ.get("SSE_TIMEOUT_SECONDS", "600"))
_sse_connection_count = 0
_sse_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Prometheus metrics counters (process-lifetime)
# ---------------------------------------------------------------------------
_metrics_lock = threading.Lock()
_metrics = {
    "http_requests_total": {},          # {method_path: count}
    "updates_triggered_total": {},      # {service: count}
    "updates_skipped_total": {},        # {service_reason: count}
    "update_errors_total": {},          # {service: count}
    "sse_connections_current": 0,
    "sse_connections_total": 0,
    "rate_limit_rejections_total": {},  # {service: count}
}


def inc_metric(key, labels="", amount=1):
    """Increment a counter metric."""
    with _metrics_lock:
        bucket = _metrics.get(key)
        if isinstance(bucket, dict):
            bucket[labels] = bucket.get(labels, 0) + amount
        else:
            _metrics[key] = _metrics.get(key, 0) + amount


def set_metric(key, value):
    """Set a gauge metric."""
    with _metrics_lock:
        _metrics[key] = value


# Known paths for metrics — everything else is bucketed as "other"
# to prevent unbounded cardinality from arbitrary request paths.
_KNOWN_PATHS = frozenset({"/status", "/update", "/progress", "/metrics"})

# Fixed skip-reason labels for Prometheus — prevents unbounded cardinality
_REASON_LABELS = {
    "not updatable": "not_updatable",
    "trigger already pending": "already_pending",
    "update in progress": "in_progress",
}


def _normalize_path(path):
    """Return path if known, else 'other'."""
    return path if path in _KNOWN_PATHS else "other"


def _normalize_skip_reason(reason):
    """Map dynamic skip reason to a fixed Prometheus label."""
    if reason.startswith("rate limited"):
        return "rate_limited"
    label = _REASON_LABELS.get(reason)
    if label:
        return label
    # Photon-specific: "blue trigger already pending" → "already_pending"
    for suffix, lbl in _REASON_LABELS.items():
        if reason.endswith(suffix):
            return lbl
    return "unknown"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def read_json(path):
    """Read a JSON file, return dict or None."""
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def write_json_atomic(path, data):
    """Write JSON data atomically using tmp file + rename."""
    dir_name = os.path.dirname(path)
    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".tmp")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp_path, path)
    except OSError as e:
        print(f"[manager] WARNING: atomic write failed for {path}: {e}", flush=True)
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        # Fallback to direct write
        with open(path, "w") as f:
            json.dump(data, f)


def load_rate_limits():
    """Load persisted rate-limit timestamps from disk on startup."""
    global _last_trigger_time
    data = read_json(RATE_LIMIT_FILE)
    if not data or not isinstance(data, dict):
        return
    now = time.time()
    restored = 0
    for svc, ts in data.items():
        if isinstance(ts, (int, float)) and now - ts < RATE_LIMIT_SECONDS:
            _last_trigger_time[svc] = ts
            restored += 1
    if restored:
        print(f"[manager] Restored {restored} rate-limit timestamp(s) from disk", flush=True)


def save_rate_limits():
    """Persist current rate-limit timestamps to the triggers volume."""
    write_json_atomic(RATE_LIMIT_FILE, dict(_last_trigger_time))


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_last_update(svc):
    path = os.path.join(TRIGGER_DIR, f"{svc}.last_update")
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def build_service_status(svc):
    """Build status for a single service (non-photon)."""
    status = read_json(os.path.join(TRIGGER_DIR, f"{svc}.status"))
    if status is None:
        status = {"state": "idle", "message": "No status yet"}
    if not status.get("last_update"):
        status["last_update"] = read_last_update(svc)
    trigger_path = os.path.join(TRIGGER_DIR, f"{svc}.trigger")
    status["trigger_pending"] = os.path.exists(trigger_path)
    return status


def build_photon_status():
    """Build aggregated photon status from blue/green instances."""
    instances = {}
    for inst in PHOTON_INSTANCES:
        key = f"photon-{inst}"
        status = read_json(os.path.join(TRIGGER_DIR, f"{key}.status"))
        if status is None:
            status = {"state": "idle", "message": "No status yet"}
        if not status.get("last_update"):
            lu = read_last_update(key)
            if lu:
                status["last_update"] = lu
        trigger_path = os.path.join(TRIGGER_DIR, f"{key}.trigger")
        status["trigger_pending"] = os.path.exists(trigger_path)
        instances[inst] = status

    # Aggregate: if any instance is updating, photon is updating
    # Use the most recent last_update across instances
    states = [inst["state"] for inst in instances.values()]
    if "updating" in states:
        agg_state = "updating"
        updating_inst = [k for k, v in instances.items() if v["state"] == "updating"]
        agg_msg = f"Rolling update ({', '.join(updating_inst)} updating)"
    elif "error" in states:
        agg_state = "error"
        error_inst = [k for k, v in instances.items() if v["state"] == "error"]
        agg_msg = f"Instance error ({', '.join(error_inst)})"
    else:
        agg_state = "idle"
        agg_msg = "Both instances serving"

    last_updates = [inst.get("last_update") for inst in instances.values() if inst.get("last_update")]
    latest = max(last_updates) if last_updates else None
    any_pending = any(inst.get("trigger_pending") for inst in instances.values())

    return {
        "state": agg_state,
        "message": agg_msg,
        "last_update": latest,
        "updated_at": now_iso(),
        "trigger_pending": any_pending,
        "instances": instances,
    }


def build_status():
    """Build aggregated status dict for all services."""
    result = {}

    # OSRM
    result["osrm"] = build_service_status("osrm")

    # Photon (blue-green aggregated)
    result["photon"] = build_photon_status()

    # Auto services
    for svc, msg in AUTO_SERVICES.items():
        result[svc] = {"state": "auto", "message": msg}

    return result


def trigger_photon_rolling():
    """Trigger a rolling update of both Photon instances.

    Writes trigger for blue first.  A background thread waits for
    blue to finish (state goes back to idle) then triggers green.
    This guarantees at least one instance is always serving.
    """
    first, second = PHOTON_INSTANCES[0], PHOTON_INSTANCES[1]

    first_trigger = os.path.join(TRIGGER_DIR, f"photon-{first}.trigger")
    second_trigger = os.path.join(TRIGGER_DIR, f"photon-{second}.trigger")

    # Skip if either is already triggered or updating
    for inst in PHOTON_INSTANCES:
        trigger = os.path.join(TRIGGER_DIR, f"photon-{inst}.trigger")
        if os.path.exists(trigger):
            return [], [{"service": "photon", "reason": f"{inst} trigger already pending"}]
        st = read_json(os.path.join(TRIGGER_DIR, f"photon-{inst}.status"))
        if st and st.get("state") == "updating":
            return [], [{"service": "photon", "reason": f"{inst} update in progress"}]

    # Trigger the first instance
    write_json_atomic(first_trigger, {"requested_at": now_iso(), "requested_by": "rolling"})

    print(f"[manager] Rolling update: triggered photon-{first}", flush=True)

    # Background thread: wait for first to finish, then trigger second
    # SAFETY: never trigger second if first is still stuck — that would
    # take both instances down, causing total geocoding outage on 112.
    def _trigger_second():
        try:
            print(f"[manager] Rolling update: waiting for photon-{first} to finish...", flush=True)
            for _ in range(1800):  # up to 30 minutes
                time.sleep(1)
                st = read_json(os.path.join(TRIGGER_DIR, f"photon-{first}.status"))
                if st and st.get("state") in ("idle", "error") and not os.path.exists(first_trigger):
                    break
            else:
                # First instance is still stuck — do NOT trigger second
                print(f"[manager] CRITICAL: photon-{first} did not finish in 30 min, "
                      f"SKIPPING photon-{second} to protect service availability", flush=True)
                inc_metric("update_errors_total", "photon")
                return

            print(f"[manager] Rolling update: triggering photon-{second}", flush=True)
            write_json_atomic(second_trigger, {"requested_at": now_iso(), "requested_by": "rolling"})
        except Exception as e:
            print(f"[manager] ERROR: _trigger_second thread failed: {e}", flush=True)
            inc_metric("update_errors_total", "photon")

    threading.Thread(target=_trigger_second, daemon=True).start()

    return ["photon"], []


def check_rate_limit(service):
    """Check if enough time has passed since last trigger for this service."""
    now = time.time()
    last = _last_trigger_time.get(service, 0)
    if now - last < RATE_LIMIT_SECONDS:
        remaining = int(RATE_LIMIT_SECONDS - (now - last))
        return False, remaining
    return True, 0


def record_trigger_time(service):
    """Record when a service was last triggered and persist to disk."""
    _last_trigger_time[service] = time.time()
    save_rate_limits()


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------
class ManagerHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        msg = fmt % args if args else fmt
        print(f"[manager] {msg}", flush=True)

    # -- CORS helpers --
    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def send_json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _check_auth(self):
        """Check bearer token if UPDATE_TOKEN is configured. Returns True if OK."""
        if not UPDATE_TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {UPDATE_TOKEN}"
        # Constant-time comparison to prevent timing side-channel attacks
        if hmac.compare_digest(auth.encode(), expected.encode()):
            return True
        self.send_json(401, {"error": "unauthorized", "message": "Invalid or missing Bearer token"})
        return False

    # -- Routes --
    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        inc_metric("http_requests_total", f"GET {_normalize_path(self.path)}")
        if self.path == "/status":
            self._handle_status()
        elif self.path == "/progress":
            self._handle_progress()
        elif self.path == "/metrics":
            self._handle_metrics()
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        inc_metric("http_requests_total", f"POST {_normalize_path(self.path)}")
        if self.path == "/update":
            if not self._check_auth():
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
            except (ValueError, TypeError):
                self.send_json(400, {"error": "invalid Content-Length header"})
                return
            if length < 0:
                self.send_json(400, {"error": "invalid Content-Length header"})
                return
            if length > 4096:
                self.send_json(413, {"error": "request body too large"})
                return
            try:
                body = json.loads(self.rfile.read(length)) if length else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self.send_json(400, {"error": "invalid JSON body"})
                return
            self._handle_update(body)
        else:
            self.send_json(404, {"error": "not found"})

    # -- GET /status --
    def _handle_status(self):
        self.send_json(200, build_status())

    # -- POST /update --
    def _handle_update(self, body):
        services = body.get("services", [])

        # Input validation
        if not isinstance(services, list):
            self.send_json(400, {"error": "'services' must be a list"})
            return
        if len(services) > 10:
            self.send_json(400, {"error": "too many services in request"})
            return
        for svc in services:
            if not isinstance(svc, str):
                self.send_json(400, {"error": "each service must be a string"})
                return

        if "all" in services:
            services = list(UPDATABLE)
        source = body.get("source", "api")
        if not isinstance(source, str):
            source = "api"

        triggered = []
        skipped = []

        # Serialize the entire check → trigger → record sequence so two
        # concurrent requests cannot both pass the rate limit for the
        # same service.  Critical for 112: prevents double-triggering
        # a rolling update that could take both Photon instances down.
        with _update_lock:
            for svc in services:
                if svc not in UPDATABLE:
                    skipped.append({"service": svc, "reason": "not updatable"})
                    continue

                # Rate limiting
                ok, remaining = check_rate_limit(svc)
                if not ok:
                    skipped.append({"service": svc, "reason": f"rate limited, retry in {remaining}s"})
                    inc_metric("rate_limit_rejections_total", svc)
                    continue

                if svc == "photon":
                    # Rolling update of blue-green pair
                    t, s = trigger_photon_rolling()
                    triggered.extend(t)
                    skipped.extend(s)
                    if t:
                        record_trigger_time(svc)
                    continue

                # Non-photon services (osrm)
                trigger_path = os.path.join(TRIGGER_DIR, f"{svc}.trigger")
                status_path = os.path.join(TRIGGER_DIR, f"{svc}.status")

                if os.path.exists(trigger_path):
                    skipped.append({"service": svc, "reason": "trigger already pending"})
                    continue

                st = read_json(status_path)
                if st and st.get("state") == "updating":
                    skipped.append({"service": svc, "reason": "update in progress"})
                    continue

                write_json_atomic(trigger_path, {"requested_at": now_iso(), "requested_by": source})
                triggered.append(svc)
                record_trigger_time(svc)

        for svc in triggered:
            inc_metric("updates_triggered_total", svc)
        for skip in skipped:
            label = _normalize_skip_reason(skip["reason"])
            inc_metric("updates_skipped_total", f'{skip["service"]}_{label}')

        code = 200 if triggered else 409
        self.send_json(
            code,
            {
                "triggered": triggered,
                "skipped": skipped,
                "message": (
                    f"Update triggered for {', '.join(triggered)}"
                    if triggered
                    else "No updates triggered"
                ),
            },
        )

    # -- GET /progress (SSE) --
    def _handle_progress(self):
        global _sse_connection_count

        with _sse_lock:
            if _sse_connection_count >= MAX_SSE_CONNECTIONS:
                self.send_json(429, {"error": "too many SSE connections",
                                     "max": MAX_SSE_CONNECTIONS})
                return
            _sse_connection_count += 1
            set_metric("sse_connections_current", _sse_connection_count)
            inc_metric("sse_connections_total")

        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self._cors_headers()
            self.end_headers()

            last_data = None
            deadline = time.monotonic() + SSE_TIMEOUT_SECONDS
            try:
                while time.monotonic() < deadline:
                    data = build_status()
                    data_str = json.dumps(data)
                    if data_str != last_data:
                        self.wfile.write(f"data: {data_str}\n\n".encode())
                        self.wfile.flush()
                        last_data = data_str
                    time.sleep(2)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
        finally:
            with _sse_lock:
                _sse_connection_count -= 1
                set_metric("sse_connections_current", _sse_connection_count)

    # -- GET /metrics (Prometheus exposition format) --
    def _handle_metrics(self):
        lines = []
        lines.append("# HELP manager_up Manager process is up.")
        lines.append("# TYPE manager_up gauge")
        lines.append("manager_up 1")

        with _metrics_lock:
            # HTTP request counters
            lines.append("")
            lines.append("# HELP manager_http_requests_total Total HTTP requests by method and path.")
            lines.append("# TYPE manager_http_requests_total counter")
            for label, count in sorted(_metrics["http_requests_total"].items()):
                method, path = label.split(" ", 1)
                lines.append(f'manager_http_requests_total{{method="{method}",path="{path}"}} {count}')

            # Update trigger counters
            lines.append("")
            lines.append("# HELP manager_updates_triggered_total Total updates triggered by service.")
            lines.append("# TYPE manager_updates_triggered_total counter")
            for svc, count in sorted(_metrics["updates_triggered_total"].items()):
                lines.append(f'manager_updates_triggered_total{{service="{svc}"}} {count}')

            # Update skip counters
            lines.append("")
            lines.append("# HELP manager_updates_skipped_total Total updates skipped by service.")
            lines.append("# TYPE manager_updates_skipped_total counter")
            for label, count in sorted(_metrics["updates_skipped_total"].items()):
                lines.append(f'manager_updates_skipped_total{{label="{label}"}} {count}')

            # Rate limit rejections
            lines.append("")
            lines.append("# HELP manager_rate_limit_rejections_total Rate limit rejections by service.")
            lines.append("# TYPE manager_rate_limit_rejections_total counter")
            for svc, count in sorted(_metrics["rate_limit_rejections_total"].items()):
                lines.append(f'manager_rate_limit_rejections_total{{service="{svc}"}} {count}')

            # SSE gauges
            lines.append("")
            lines.append("# HELP manager_sse_connections_current Current SSE connections.")
            lines.append("# TYPE manager_sse_connections_current gauge")
            lines.append(f'manager_sse_connections_current {_metrics["sse_connections_current"]}')

            lines.append("")
            lines.append("# HELP manager_sse_connections_total Total SSE connections opened.")
            lines.append("# TYPE manager_sse_connections_total counter")
            lines.append(f'manager_sse_connections_total {_metrics["sse_connections_total"]}')

            # Update error counters
            lines.append("")
            lines.append("# HELP manager_update_errors_total Update errors by service.")
            lines.append("# TYPE manager_update_errors_total counter")
            for svc, count in sorted(_metrics["update_errors_total"].items()):
                lines.append(f'manager_update_errors_total{{service="{svc}"}} {count}')

        # Service state from trigger files (as gauges for alerting)
        lines.append("")
        lines.append("# HELP manager_service_up Service state: 1=idle, 0.5=updating, 0=error.")
        lines.append("# TYPE manager_service_up gauge")
        status = build_status()
        state_map = {"idle": 1, "auto": 1, "updating": 0.5, "error": 0}
        for svc, info in status.items():
            state = info.get("state", "idle")
            val = state_map.get(state, 0)
            lines.append(f'manager_service_up{{service="{svc}",state="{state}"}} {val}')
            if svc == "photon" and "instances" in info:
                for inst, inst_info in info["instances"].items():
                    inst_state = inst_info.get("state", "idle")
                    inst_val = state_map.get(inst_state, 0)
                    lines.append(f'manager_service_up{{service="photon-{inst}",state="{inst_state}"}} {inst_val}')

        body = "\n".join(lines) + "\n"
        body_bytes = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)


# ---------------------------------------------------------------------------
# Threaded server (so SSE streams don't block /status or healthchecks)
# ---------------------------------------------------------------------------
class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    os.makedirs(TRIGGER_DIR, exist_ok=True)
    # 0o777: shared volume between root (manager) and non-root users (osrm, photon)
    os.chmod(TRIGGER_DIR, 0o777)
    load_rate_limits()
    print(f"[manager] Listening on 0.0.0.0:{LISTEN_PORT}", flush=True)
    print(f"[manager] Trigger directory: {TRIGGER_DIR}", flush=True)
    print(f"[manager] Photon instances: {PHOTON_INSTANCES}", flush=True)
    print(f"[manager] Metrics endpoint: GET /metrics", flush=True)
    if UPDATE_TOKEN:
        print("[manager] API token authentication enabled", flush=True)
    else:
        print("[manager] WARNING: No UPDATE_TOKEN set — update endpoint is unprotected", flush=True)
    if RATE_LIMIT_SECONDS > 0:
        print(f"[manager] Rate limit: {RATE_LIMIT_SECONDS}s between updates per service", flush=True)
    else:
        print("[manager] WARNING: Rate limiting is DISABLED (RATE_LIMIT_SECONDS=0)", flush=True)
    server = ThreadedHTTPServer(("0.0.0.0", LISTEN_PORT), ManagerHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[manager] Shutting down", flush=True)
        server.shutdown()
