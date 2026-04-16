#!/usr/bin/env bash
set -euo pipefail

CHAOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$CHAOS_DIR/.." && pwd)"
RUNS_DIR="$CHAOS_DIR/runs"
LATEST_FILE="$CHAOS_DIR/.latest_run"
CPU_PID_FILE="$CHAOS_DIR/.cpu_stress.pids"

PROM_URL="${PROM_URL:-http://localhost:9090}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"
APP_URL="${APP_URL:-http://localhost:5000}"
SERVICE_NAME="${SERVICE_NAME:-tiny-service}"

APP_HEALTH_PATH="${APP_HEALTH_PATH:-/health}"
APP_FALLBACK_PATH="${APP_FALLBACK_PATH:-/}"

DOWN_ALERT_NAME="${DOWN_ALERT_NAME:-TinyServiceDown}"
ERROR_ALERT_NAME="${ERROR_ALERT_NAME:-HighErrorRate}"
LATENCY_ALERT_NAME="${LATENCY_ALERT_NAME:-HighLatencyP99}"

ERROR_PATH="${ERROR_PATH:-/api/error}"
SLOW_PATH="${SLOW_PATH:-/api/slow}"
OBSERVE_PATH="${OBSERVE_PATH:-/}"

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-180}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-5}"

dc() {
  docker compose -f "$PROJECT_DIR/docker-compose.yml" --project-directory "$PROJECT_DIR" "$@"
}

require_tools() {
  command -v docker >/dev/null 2>&1 || { echo "Thiếu docker"; exit 1; }
  command -v curl >/dev/null 2>&1 || { echo "Thiếu curl"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "Thiếu python3"; exit 1; }
}

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

new_run() {
  local scenario="$1"
  mkdir -p "$RUNS_DIR"
  RUN_ID="$(date +%Y%m%d-%H%M%S)-$scenario"
  RUN_DIR="$RUNS_DIR/$RUN_ID"
  mkdir -p "$RUN_DIR"
  echo "$RUN_ID" > "$LATEST_FILE"
  export RUN_ID RUN_DIR
}

load_run() {
  if [[ ! -f "$LATEST_FILE" ]]; then
    echo "Chưa có run nào. Hãy chạy một script chaos trước."
    exit 1
  fi

  RUN_ID="$(cat "$LATEST_FILE")"
  RUN_DIR="$RUNS_DIR/$RUN_ID"

  if [[ ! -d "$RUN_DIR" ]]; then
    echo "Không tìm thấy run dir: $RUN_DIR"
    exit 1
  fi

  export RUN_ID RUN_DIR
}

log_line() {
  local msg="$1"
  echo "[$(timestamp)] $msg" | tee -a "$RUN_DIR/timeline.log"
}

save_json_pretty() {
  local url="$1"
  local outfile="$2"
  if curl -fsS "$url" | python3 -m json.tool > "$outfile" 2>/dev/null; then
    :
  else
    printf '{"error":"fetch_failed","url":"%s"}\n' "$url" > "$outfile"
  fi
}

save_compose_ps() {
  dc ps > "$RUN_DIR/docker-compose-ps.txt" 2>&1 || true
}

save_targets() {
  save_json_pretty "$PROM_URL/api/v1/targets" "$RUN_DIR/targets.json"
}

save_prom_alerts() {
  save_json_pretty "$PROM_URL/api/v1/alerts" "$RUN_DIR/prometheus-alerts.json"
}

save_am_alerts() {
  save_json_pretty "$ALERTMANAGER_URL/api/v2/alerts" "$RUN_DIR/alertmanager-alerts.json"
}

snapshot_all() {
  save_compose_ps
  save_targets
  save_prom_alerts
  save_am_alerts
}

http_code() {
  local path="$1"
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" "${APP_URL}${path}" 2>/dev/null || true)"
  [[ -n "$code" ]] || code="000"
  echo "$code"
}

http_time() {
  local path="$1"
  local t
  t="$(curl -s -o /dev/null -w "%{time_total}" "${APP_URL}${path}" 2>/dev/null || true)"
  [[ -n "$t" ]] || t="0"
  echo "$t"
}

app_health_code() {
  local code
  code="$(http_code "$APP_HEALTH_PATH")"
  if [[ "$code" == "200" ]]; then
    echo "$code"
  else
    http_code "$APP_FALLBACK_PATH"
  fi
}

target_health() {
  local job_name="$1"
  local tmpfile
  tmpfile="$(mktemp)"

  if ! curl -fsS "$PROM_URL/api/v1/targets" -o "$tmpfile"; then
    echo "unreachable"
    rm -f "$tmpfile"
    return
  fi

  python3 - "$job_name" "$tmpfile" <<'PY'
import json, sys

job = sys.argv[1]
path = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    for t in data["data"]["activeTargets"]:
        if t.get("labels", {}).get("job") == job:
            print(t.get("health", "unknown"))
            break
    else:
        print("missing")
except Exception:
    print("unreachable")
PY

  rm -f "$tmpfile"
}

prom_alert_state() {
  local alert_name="$1"
  local tmpfile
  tmpfile="$(mktemp)"

  if ! curl -fsS "$PROM_URL/api/v1/alerts" -o "$tmpfile"; then
    echo "unreachable"
    rm -f "$tmpfile"
    return
  fi

  python3 - "$alert_name" "$tmpfile" <<'PY'
import json, sys

name = sys.argv[1]
path = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    for a in data["data"]["alerts"]:
        if a.get("labels", {}).get("alertname") == name:
            print(a.get("state", "unknown"))
            break
    else:
        print("absent")
except Exception:
    print("unreachable")
PY

  rm -f "$tmpfile"
}

am_alert_state() {
  local alert_name="$1"
  local tmpfile
  tmpfile="$(mktemp)"

  if ! curl -fsS "$ALERTMANAGER_URL/api/v2/alerts" -o "$tmpfile"; then
    echo "unreachable"
    rm -f "$tmpfile"
    return
  fi

  python3 - "$alert_name" "$tmpfile" <<'PY'
import json, sys

name = sys.argv[1]
path = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    for a in data:
        if a.get("labels", {}).get("alertname") == name:
            print(a.get("status", {}).get("state", "unknown"))
            break
    else:
        print("absent")
except Exception:
    print("unreachable")
PY

  rm -f "$tmpfile"
}

precheck_basic() {
  snapshot_all

  local app_code service_health prom_health
  app_code="$(app_health_code)"
  service_health="$(target_health "$SERVICE_NAME")"
  prom_health="$(target_health "prometheus")"

  cat > "$RUN_DIR/precheck.txt" <<EOT
run_id=$RUN_ID
app_health_code=$app_code
service_name=$SERVICE_NAME
service_target_health=$service_health
prometheus_target_health=$prom_health
EOT

  log_line "Precheck app_health_code=$app_code"
  log_line "Precheck service_target_health=$service_health"
  log_line "Precheck prometheus_target_health=$prom_health"

  [[ "$app_code" == "200" ]] || return 1
  [[ "$service_health" == "up" ]] || return 1
  [[ "$prom_health" == "up" ]] || return 1
}

wait_for_alert() {
  local alert_name="$1"
  local elapsed=0

  while (( elapsed <= MAX_WAIT_SECONDS )); do
    local service_health prom_state am_state
    service_health="$(target_health "$SERVICE_NAME")"
    prom_state="$(prom_alert_state "$alert_name")"
    am_state="$(am_alert_state "$alert_name")"

    echo "elapsed=${elapsed}s service=${service_health} prom=${prom_state} am=${am_state}" \
      | tee -a "$RUN_DIR/wait-alert.log"

    if [[ "$prom_state" == "firing" && "$am_state" == "active" ]]; then
      log_line "Alert $alert_name đã firing"
      snapshot_all
      return 0
    fi

    sleep "$INTERVAL_SECONDS"
    elapsed=$((elapsed + INTERVAL_SECONDS))
  done

  snapshot_all
  return 1
}

all_alerts_clear() {
  local prom_state am_state name
  for name in "$DOWN_ALERT_NAME" "$ERROR_ALERT_NAME" "$LATENCY_ALERT_NAME"; do
    prom_state="$(prom_alert_state "$name")"
    am_state="$(am_alert_state "$name")"
    if [[ "$prom_state" == "firing" || "$prom_state" == "pending" || "$am_state" == "active" ]]; then
      return 1
    fi
  done
  return 0
}

send_requests() {
  local path="$1"
  local requests="$2"
  local concurrency="$3"
  local outfile="$4"

  : > "$outfile"

  local active=0
  local i
  for i in $(seq 1 "$requests"); do
    (
      code="$(http_code "$path")"
      printf 'request=%s code=%s path=%s\n' "$i" "$code" "$path"
    ) >> "$outfile" &

    active=$((active + 1))
    if (( active >= concurrency )); then
      wait
      active=0
    fi
  done

  wait
}

start_cpu_burners() {
  local workers="$1"
  local duration="$2"
  local pidfile="$RUN_DIR/cpu-stress.pids"

  : > "$pidfile"

  local i
  for i in $(seq 1 "$workers"); do
    python3 - "$duration" >/dev/null 2>&1 <<'PY' &
import sys, time
duration = int(sys.argv[1])
end = time.time() + duration
x = 0
while time.time() < end:
    x = (x * 3 + 7) % 10000019
PY
    echo $! >> "$pidfile"
  done

  cp "$pidfile" "$CPU_PID_FILE"
}

stop_cpu_burners() {
  if [[ -f "$CPU_PID_FILE" ]]; then
    while read -r pid; do
      [[ -n "${pid:-}" ]] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done < "$CPU_PID_FILE"
    rm -f "$CPU_PID_FILE"
  fi
}