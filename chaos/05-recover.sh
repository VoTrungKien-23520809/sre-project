#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_tools
load_run

log_line "=== Recover bắt đầu ==="

stop_cpu_burners || true
dc start "$SERVICE_NAME" >/dev/null 2>&1 || true

elapsed=0
while (( elapsed <= MAX_WAIT_SECONDS )); do
  app_code="$(app_health_code)"
  service_health="$(target_health "$SERVICE_NAME")"

  down_prom="$(prom_alert_state "$DOWN_ALERT_NAME")"
  error_prom="$(prom_alert_state "$ERROR_ALERT_NAME")"
  latency_prom="$(prom_alert_state "$LATENCY_ALERT_NAME")"

  down_am="$(am_alert_state "$DOWN_ALERT_NAME")"
  error_am="$(am_alert_state "$ERROR_ALERT_NAME")"
  latency_am="$(am_alert_state "$LATENCY_ALERT_NAME")"

  echo "elapsed=${elapsed}s app_code=${app_code} service=${service_health} down_prom=${down_prom} error_prom=${error_prom} latency_prom=${latency_prom} down_am=${down_am} error_am=${error_am} latency_am=${latency_am}" \
    | tee -a "$RUN_DIR/recover.log"

  if [[ "$app_code" == "200" && "$service_health" == "up" ]]; then
    if all_alerts_clear; then
      snapshot_all
      log_line "Hệ thống đã recover sạch"
      echo "PASS: Recovery thành công"
      echo "Run dir: $RUN_DIR"
      exit 0
    fi
  fi

  sleep "$INTERVAL_SECONDS"
  elapsed=$((elapsed + INTERVAL_SECONDS))
done

snapshot_all
echo "FAIL: Recovery chưa sạch sau thời gian chờ"
echo "Run dir: $RUN_DIR"
exit 1
