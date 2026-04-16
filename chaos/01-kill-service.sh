#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_tools
new_run "kill-service"

log_line "=== Kill service test bắt đầu ==="

if ! precheck_basic; then
  echo "Precheck fail. Dừng test."
  exit 1
fi

log_line "Snapshot trước khi kill"
snapshot_all

log_line "Kill service: $SERVICE_NAME"
dc kill "$SERVICE_NAME"

sleep 2
snapshot_all

if wait_for_alert "$DOWN_ALERT_NAME"; then
  echo "PASS: $DOWN_ALERT_NAME đã firing"
  echo "Run dir: $RUN_DIR"
else
  echo "FAIL: $DOWN_ALERT_NAME chưa firing trong thời gian chờ"
  echo "Run dir: $RUN_DIR"
  exit 1
fi
