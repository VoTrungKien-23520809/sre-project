#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_tools
new_run "error-rate"

REQUESTS="${REQUESTS:-120}"
SLEEP_SECONDS="${SLEEP_SECONDS:-0.2}"

log_line "=== Error rate test bắt đầu ==="

if ! precheck_basic; then
  echo "Precheck fail. Dừng test."
  exit 1
fi

log_line "Bắn $REQUESTS requests tuần tự vào $ERROR_PATH với sleep=${SLEEP_SECONDS}s"

: > "$RUN_DIR/error-requests.log"

for i in $(seq 1 "$REQUESTS"); do
  code="$(http_code "$ERROR_PATH")"
  printf 'request=%s code=%s path=%s\n' "$i" "$code" "$ERROR_PATH" | tee -a "$RUN_DIR/error-requests.log"
  sleep "$SLEEP_SECONDS"
done

snapshot_all

if wait_for_alert "$ERROR_ALERT_NAME"; then
  echo "PASS: $ERROR_ALERT_NAME đã firing"
  echo "Run dir: $RUN_DIR"
else
  echo "FAIL: $ERROR_ALERT_NAME chưa firing trong thời gian chờ"
  echo "Run dir: $RUN_DIR"
  exit 1
fi