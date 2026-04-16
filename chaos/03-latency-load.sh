#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_tools
new_run "latency-load"

REQUESTS="${REQUESTS:-90}"
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"

log_line "=== Latency load test bắt đầu ==="

if ! precheck_basic; then
  echo "Precheck fail. Dừng test."
  exit 1
fi

BASELINE="$(http_time "$OBSERVE_PATH")"
echo "baseline_observe_path=$OBSERVE_PATH time_total=$BASELINE" | tee "$RUN_DIR/baseline-latency.log"

log_line "Bắn $REQUESTS requests tuần tự vào $SLOW_PATH với sleep=${SLEEP_SECONDS}s"

: > "$RUN_DIR/slow-requests.log"

for i in $(seq 1 "$REQUESTS"); do
  t="$(http_time "$SLOW_PATH")"
  printf 'request=%s path=%s time_total=%s\n' "$i" "$SLOW_PATH" "$t" | tee -a "$RUN_DIR/slow-requests.log"
  sleep "$SLEEP_SECONDS"
done

snapshot_all

if wait_for_alert "$LATENCY_ALERT_NAME"; then
  echo "PASS: $LATENCY_ALERT_NAME đã firing"
  echo "Run dir: $RUN_DIR"
else
  echo "FAIL: $LATENCY_ALERT_NAME chưa firing trong thời gian chờ"
  echo "Run dir: $RUN_DIR"
  exit 1
fi