#!/usr/bin/env python3
"""
webhook_receiver.py
-------------------
HTTP server nhận webhook từ Alertmanager và tự động chạy Ansible Playbook.

Luồng:
  Alertmanager firing
      → POST /webhook
      → webhook_receiver.py nhận alert
      → subprocess chạy ansible-playbook
      → tiny-service được restart tự động
      → Log ghi lại toàn bộ quá trình

Chạy:
  python3 ansible/webhook_receiver.py

Endpoint:
  POST http://localhost:5001/webhook   ← Alertmanager gửi vào đây
  GET  http://localhost:5001/health    ← Kiểm tra receiver còn sống
  GET  http://localhost:5001/logs      ← Xem lịch sử recovery
"""

import json
import subprocess
import logging
import os
import threading
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

# ── Cấu hình ──────────────────────────────────────────────────────────────────
PORT              = 5001
COMPOSE_DIR       = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PLAYBOOK_PATH     = os.path.join(os.path.dirname(__file__), "restart_service.yml")
INVENTORY_PATH    = os.path.join(os.path.dirname(__file__), "inventory.ini")
LOG_FILE          = "/var/log/sre-webhook-receiver.log"
RECOVERY_COOLDOWN = 120   # Giây chờ giữa 2 lần recovery (tránh loop)

# Alert nào sẽ trigger Ansible
HANDLED_ALERTS = {
    "TinyServiceDown",
    "HighErrorRate",
    "HighLatencyP99",
}

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_FILE, mode="a"),
    ],
)
log = logging.getLogger(__name__)

# ── State ─────────────────────────────────────────────────────────────────────
recovery_history = []          # Lịch sử các lần recovery
last_recovery_time = {}        # alertname → timestamp lần recovery gần nhất
lock = threading.Lock()


# ── Recovery logic ────────────────────────────────────────────────────────────
def run_ansible_recovery(alert_name: str, severity: str, labels: dict):
    """Chạy Ansible Playbook để tự động recover service."""
    now = datetime.now()

    # Cooldown check — tránh chạy liên tục
    with lock:
        last = last_recovery_time.get(alert_name)
        if last and (now - last).total_seconds() < RECOVERY_COOLDOWN:
            remaining = RECOVERY_COOLDOWN - (now - last).total_seconds()
            log.warning(
                f"[COOLDOWN] {alert_name} — bỏ qua, còn {remaining:.0f}s cooldown"
            )
            return

        last_recovery_time[alert_name] = now

    log.info(f"[TRIGGER] Alert={alert_name} Severity={severity} → Chạy Ansible")

    cmd = [
        "ansible-playbook",
        "-i", INVENTORY_PATH,
        PLAYBOOK_PATH,
        "-e", f"triggered_by_alert={alert_name}",
    ]

    record = {
        "timestamp": now.isoformat(),
        "alert":     alert_name,
        "severity":  severity,
        "labels":    labels,
        "status":    "running",
        "output":    "",
        "rc":        None,
    }

    with lock:
        recovery_history.append(record)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=COMPOSE_DIR,
            timeout=300,   # 5 phút timeout
        )
        record["rc"]     = result.returncode
        record["output"] = result.stdout[-3000:]   # Giữ 3000 ký tự cuối
        record["status"] = "success" if result.returncode == 0 else "failed"

        if result.returncode == 0:
            log.info(f"[SUCCESS] Ansible recovery hoàn tất cho {alert_name}")
        else:
            log.error(
                f"[FAILED] Ansible exit={result.returncode}\n{result.stderr[-500:]}"
            )

    except subprocess.TimeoutExpired:
        record["status"] = "timeout"
        log.error(f"[TIMEOUT] Ansible chạy quá 5 phút cho {alert_name}")
    except Exception as exc:
        record["status"] = "error"
        record["output"] = str(exc)
        log.error(f"[ERROR] {exc}")


# ── HTTP Handler ──────────────────────────────────────────────────────────────
class WebhookHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        # Tắt access log mặc định, dùng logger của mình
        log.debug(fmt % args)

    # POST /webhook ─────────────────────────────────────────────────────────
    def handle_webhook(self):
        length  = int(self.headers.get("Content-Length", 0))
        body    = self.rfile.read(length)

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._respond(400, {"error": "Invalid JSON"})
            return

        alerts  = payload.get("alerts", [])
        status  = payload.get("status", "")   # firing | resolved

        log.info(f"[WEBHOOK] status={status} alerts={len(alerts)}")

        fired = []
        for alert in alerts:
            alert_name = alert.get("labels", {}).get("alertname", "Unknown")
            severity   = alert.get("labels", {}).get("severity", "unknown")
            alert_status = alert.get("status", "")

            if alert_status == "firing" and alert_name in HANDLED_ALERTS:
                log.info(f"[MATCH] {alert_name} ({severity}) → trigger recovery")
                fired.append(alert_name)
                t = threading.Thread(
                    target=run_ansible_recovery,
                    args=(alert_name, severity, alert.get("labels", {})),
                    daemon=True,
                )
                t.start()

            elif alert_status == "resolved":
                log.info(f"[RESOLVED] {alert_name} — không cần recovery")

        self._respond(200, {
            "received": len(alerts),
            "triggered": fired,
        })

    # GET /health ────────────────────────────────────────────────────────────
    def handle_health(self):
        self._respond(200, {
            "status":           "ok",
            "uptime":           "running",
            "recovery_count":   len(recovery_history),
        })

    # GET /logs ──────────────────────────────────────────────────────────────
    def handle_logs(self):
        with lock:
            recent = recovery_history[-20:]   # 20 lần gần nhất
        self._respond(200, {"history": recent})

    # Router ─────────────────────────────────────────────────────────────────
    def do_POST(self):
        if self.path == "/webhook":
            self.handle_webhook()
        else:
            self._respond(404, {"error": "Not found"})

    def do_GET(self):
        if self.path == "/health":
            self.handle_health()
        elif self.path == "/logs":
            self.handle_logs()
        else:
            self._respond(404, {"error": "Not found"})

    def _respond(self, code: int, data: dict):
        body = json.dumps(data, indent=2, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)


# ── Main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    # Tạo log file nếu chưa có
    try:
        open(LOG_FILE, "a").close()
    except PermissionError:
        LOG_FILE = "/tmp/sre-webhook-receiver.log"
        logging.getLogger().handlers[-1] = logging.FileHandler(LOG_FILE, mode="a")

    log.info("=" * 60)
    log.info(f"SRE Webhook Receiver khởi động tại port {PORT}")
    log.info(f"Playbook  : {PLAYBOOK_PATH}")
    log.info(f"Inventory : {INVENTORY_PATH}")
    log.info(f"Handled alerts: {HANDLED_ALERTS}")
    log.info("=" * 60)

    server = HTTPServer(("0.0.0.0", PORT), WebhookHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Webhook receiver dừng.")
