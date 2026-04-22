# Ansible — Hướng dẫn sử dụng
**NT533.Q22 2026 | Người 4: Phục hồi & Tự động hóa**

---

## Cấu trúc thư mục

```
ansible/
├── README.md                 # File này
├── inventory.ini             # Khai báo host target
├── restart_service.yml       # Playbook tự động recovery
├── webhook_receiver.py       # HTTP server nhận alert → trigger Ansible
├── runbook.md                # On-call Runbook (2 alert: HighErrorRate, HighLatencyP99)
├── postmortem_template.md    # Template báo cáo sự cố chuẩn SRE
├── REPORT.md                 # Báo cáo đánh giá MTTR & Evaluation Metrics
└── EVALUATION.md             # Đánh giá khả năng tự phục hồi chi tiết
```

---

## Kiến trúc tự động hóa

```
tiny-service lỗi / vi phạm SLI
        ↓ (~15-50s)
Prometheus phát hiện → Alert firing
        ↓
Alertmanager nhận alert
        ↓
┌───────────────────────┬──────────────────────────────┐
│   Discord Webhook     │   Ansible Webhook Receiver   │
│   → Thông báo nhóm   │   http://localhost:5001       │
│   (mọi severity)      │   (chỉ Critical alerts)      │
└───────────────────────┴──────────────┬───────────────┘
                                        ↓
                          ansible-playbook restart_service.yml
                                        ↓
                          docker compose restart tiny-service
                                        ↓
                          Health check pass → Alert resolved
                          Log ghi vào /var/log/sre-recovery.log
```

**MTTR so sánh:**

| Phương thức | MTTR | Ghi chú |
|---|---|---|
| Thủ công | 10 – 20 phút | Chờ người on-call phản hồi |
| Ansible tự động | 30 – 60 giây | Chỉ Critical alerts |

---

## Yêu cầu

- Ubuntu 22.04+
- Ansible >= 2.14
- Python 3.x (có sẵn trên Ubuntu)
- Docker + Docker Compose đang chạy
- Stack SRE đang up (`docker compose ps` thấy 8 container)

Cài Ansible nếu chưa có:
```bash
sudo apt install ansible -y
ansible --version
```

---

## Hướng dẫn khởi động đầy đủ

### Bước 1 — Chuẩn bị log files
```bash
sudo touch /var/log/sre-recovery.log
sudo touch /var/log/sre-webhook-receiver.log
sudo chmod 666 /var/log/sre-recovery.log
sudo chmod 666 /var/log/sre-webhook-receiver.log
```

### Bước 2 — Khởi động Webhook Receiver
Mở **terminal riêng** và chạy:
```bash
cd /home/sangnn1908/SRE/sre-project
python3 ansible/webhook_receiver.py
```

Verify đang chạy:
```bash
curl http://localhost:5001/health
```
Kết quả mong đợi:
```json
{"status": "ok", "uptime": "running", "recovery_count": 0}
```

### Bước 3 — Cập nhật Alertmanager config
```bash
# Backup config cũ
cp alertmanager/alertmanager.yml alertmanager/alertmanager.yml.bak

# Restart alertmanager sau khi cập nhật config mới
docker compose up -d --force-recreate alertmanager
```

Verify config load thành công:
```bash
docker compose logs alertmanager | grep "Completed loading"
```

### Bước 4 — Test kết nối Ansible
```bash
ansible -i ansible/inventory.ini docker_host -m ping
```
Kết quả mong đợi: `localhost | SUCCESS`

---

## Alertmanager — Phân loại route

Config mới phân loại alert theo severity:

| Severity | Receiver | Hành động |
|---|---|---|
| `critical` | `discord-and-ansible` | Gửi Discord **+** trigger Ansible tự động |
| `warning` | `discord` | Chỉ gửi Discord, cần người điều tra |

Alert được xử lý tự động (Critical):

| Alert | Hành động Ansible |
|---|---|
| `TinyServiceDown` | Restart `tiny-service` |
| `HighErrorRate` | Restart `tiny-service` |

Alert chỉ notify (Warning):

| Alert | Lý do không tự động |
|---|---|
| `HighLatencyP99` | Cần người xác định nguyên nhân (chaos vs tải thật) |

---

## Chạy Ansible Playbook

### Tự động (khi webhook_receiver đang chạy)
Không cần làm gì — Alertmanager sẽ trigger tự động khi có Critical alert.

### Thủ công khi cần
```bash
cd /home/sangnn1908/SRE/sre-project
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml
```

### Chỉ verify stack (không restart)
```bash
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml \
  --start-at-task "Check — Trạng thái tất cả container"
```

### Dry-run
```bash
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml --check
```

### Output chi tiết
```bash
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml -v
```

---

## Test toàn bộ luồng tự động hóa

```bash
# Terminal 1 — Webhook receiver
python3 ansible/webhook_receiver.py

# Terminal 2 — Chaos test
./chaos/01-kill-service.sh

# Terminal 3 — Theo dõi log realtime
tail -f /var/log/sre-webhook-receiver.log
tail -f /var/log/sre-recovery.log
```

Nếu hoạt động đúng, service sẽ tự restart mà không cần can thiệp.

---

## Xem lịch sử recovery

```bash
# Log Ansible recovery
cat /var/log/sre-recovery.log

# Lịch sử webhook receiver (20 lần gần nhất)
curl http://localhost:5001/logs | python3 -m json.tool

# Realtime
tail -f /var/log/sre-webhook-receiver.log
```

Ví dụ log:
```
[2026-04-15 15:30:00] [START] Recovery triggered for tiny-service
[2026-04-15 15:30:01] [INFO] Container status: exited
[2026-04-15 15:30:01] [METRICS] ErrorRate=1.0 P99=N/A
[2026-04-15 15:30:05] [ACTION] Restart result: 0
[2026-04-15 15:30:15] [VERIFY] Post-restart ErrorRate=0.02
[2026-04-15 15:30:15] [END] Recovery completed for tiny-service
```

---

## webhook_receiver.py

HTTP server Python (port 5001) nhận webhook từ Alertmanager và trigger Ansible.

| Endpoint | Method | Mô tả |
|---|---|---|
| `/webhook` | POST | Nhận alert từ Alertmanager |
| `/health` | GET | Kiểm tra receiver còn sống |
| `/logs` | GET | Xem lịch sử 20 lần recovery gần nhất |

**Cooldown:** 120 giây giữa 2 lần recovery cùng alert để tránh restart loop.

---

## Biến cấu hình trong restart_service.yml

| Biến | Mặc định | Mô tả |
|---|---|---|
| `service_name` | `tiny-service` | Tên container cần restart |
| `compose_dir` | `/home/sangnn1908/SRE/sre-project` | Thư mục docker-compose.yml |
| `prometheus_url` | `http://localhost:9090` | URL Prometheus |
| `health_check_url` | `http://localhost:5000/health` | Endpoint health check |
| `max_restart_attempts` | `3` | Số lần retry tối đa |
| `log_file` | `/var/log/sre-recovery.log` | File ghi log |

Override khi chạy:
```bash
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml \
  -e "service_name=prometheus"
```

---

## Adapt cho AKS (Kubernetes)

Khi deploy lên AWS EKS, thay task docker compose bằng kubectl:

```yaml
- name: Restart pod trên AKS
  shell: kubectl rollout restart deployment/tiny-service -n default
  environment:
    KUBECONFIG: /home/sangnn1908/.kube/config
```

Cấu hình kubeconfig:
```bash
aws eks update-kubeconfig --region ap-southeast-1 --name sre-cluster
```

Webhook receiver URL trong alertmanager.yml đổi từ `host.docker.internal` sang IP node thật.

---

## Troubleshooting

**Permission denied khi ghi log**
```bash
sudo touch /var/log/sre-recovery.log /var/log/sre-webhook-receiver.log
sudo chmod 666 /var/log/sre-recovery.log /var/log/sre-webhook-receiver.log
```

**Cannot connect to Docker daemon**
```bash
sudo usermod -aG docker $USER && newgrp docker
```

**Webhook receiver không nhận được alert**
```bash
# Test thủ công
curl -X POST http://localhost:5001/webhook \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"TinyServiceDown","severity":"critical"},"annotations":{}}]}'
```

**Ansible không tìm thấy inventory**
```bash
# Chạy từ đúng thư mục
cd /home/sangnn1908/SRE/sre-project
ansible -i ansible/inventory.ini docker_host -m ping
```

**Health check timeout sau restart**
```bash
docker compose logs --tail=30 tiny-service
# Tăng retry: retries: 15, delay: 10
```
