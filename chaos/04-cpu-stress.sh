#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_tools
new_run "cpu-stress"

CPU_WORKERS="${CPU_WORKERS:-2}"
CPU_DURATION="${CPU_DURATION:-60}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

log_line "=== CPU stress test bắt đầu ==="

if ! precheck_basic; then
  echo "Precheck fail. Dừng test."
  exit 1
fi

BASELINE="$(http_time "$OBSERVE_PATH")"
echo "baseline_observe_path=$OBSERVE_PATH time_total=$BASELINE" | tee "$RUN_DIR/cpu-baseline.log"

log_line "Start CPU burners: workers=$CPU_WORKERS duration=${CPU_DURATION}s"
start_cpu_burners "$CPU_WORKERS" "$CPU_DURATION"

elapsed=0
while (( elapsed <= CPU_DURATION )); do
  app_code="$(app_health_code)"
  observe_time="$(http_time "$OBSERVE_PATH")"

  echo "elapsed=${elapsed}s app_code=${app_code} observe_path=${OBSERVE_PATH} observe_time=${observe_time}" \
    | tee -a "$RUN_DIR/cpu-observe.log"

  sleep "$CHECK_INTERVAL"
  elapsed=$((elapsed + CHECK_INTERVAL))
done

stop_cpu_burners || true
snapshot_all

echo "PASS: CPU stress hoàn tất"
echo "Run dir: $RUN_DIR"
