# Đánh giá Khả năng Tự Phục hồi & Cảnh báo
**NT533.Q22 2026 | Người 4: Phục hồi & Tự động hóa**

---

## 1. Tổng quan kiến trúc tự động hóa

```
┌─────────────────────────────────────────────────────────────┐
│                   Luồng tự động hóa                         │
│                                                             │
│  tiny-service lỗi                                           │
│       ↓ (30s)                                               │
│  Prometheus phát hiện vi phạm SLI                           │
│       ↓ (pending → firing)                                  │
│  Alertmanager nhận alert                                    │
│       ↓                                                     │
│  ┌────────────────────┐    ┌──────────────────────────┐    │
│  │  Discord Webhook   │    │  Ansible Webhook Receiver │    │
│  │  → Thông báo nhóm  │    │  :5001/webhook            │    │
│  └────────────────────┘    └──────────────┬───────────┘    │
│                                            ↓                │
│                              ansible-playbook               │
│                              restart_service.yml            │
│                                            ↓                │
│                              docker compose restart         │
│                              tiny-service                   │
│                                            ↓                │
│                              Health check pass              │
│                              → Alert resolved               │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Đánh giá khả năng cảnh báo

### 2.1 Kết quả thực tế từ Chaos Test

| Kịch bản | Alert kích hoạt | Thời gian phát hiện | Discord nhận | Đánh giá |
|---|---|---|---|---|
| Kill service | TinyServiceDown | ~50 giây | ✅ Có | ✅ Tốt |
| Error rate cao | HighErrorRate | ~60 giây | ✅ Có | ✅ Tốt |
| Latency P99 cao | HighLatencyP99 | ~120 giây | ✅ Có | ✅ Tốt |
| CPU stress | — | Không có rule | ❌ Không | ⚠️ Thiếu rule |

### 2.2 Phân tích thời gian phát hiện (MTTD)

```
TinyServiceDown:
  Service down lúc T+0s
  Prometheus scrape lỗi lúc T+15s (scrape interval)
  Alert pending lúc T+15s
  Alert firing lúc T+45s (for: 30s)
  Discord nhận lúc T+55s (group_wait: 10s)
  → MTTD ≈ 55 giây ✅

HighErrorRate:
  Error rate tăng lúc T+0s
  Alert pending lúc T+15s
  Alert firing lúc T+75s (for: 1m)
  Discord nhận lúc T+85s
  → MTTD ≈ 85 giây ✅

HighLatencyP99:
  Latency tăng lúc T+0s
  Alert firing lúc T+135s (for: 2m)
  Discord nhận lúc T+145s
  → MTTD ≈ 145 giây ⚠️ (chấp nhận được)
```

### 2.3 Điểm mạnh của hệ thống cảnh báo
- Alert message chi tiết: severity, job, instance, summary, description
- Gửi cả FIRING và RESOLVED → biết khi nào hệ thống tự phục hồi
- Phân loại severity (critical/warning) để ưu tiên xử lý
- Cooldown `repeat_interval` tránh spam alert

### 2.4 Điểm yếu & cải thiện đề xuất
| Vấn đề | Hiện tại | Đề xuất |
|---|---|---|
| Không có alert CPU | Không có rule | Thêm `HighCPUUsage` rule |
| MTTD còn chậm | 55-145 giây | Giảm `scrape_interval` xuống 10s |
| Không escalate | Chỉ 1 kênh | Thêm escalation sau 15 phút |
| Không có SLO burn rate | Chưa có | Thêm multi-window burn rate alert |

---

## 3. Đánh giá khả năng tự phục hồi

### 3.1 Trước khi tích hợp Ansible

| Tình huống | Hành động hệ thống | Kết quả |
|---|---|---|
| Container crash | Docker KHÔNG tự restart | ❌ Service down đến khi có người fix |
| Error rate cao | Chỉ gửi alert | ❌ Cần người vào restart thủ công |
| Latency cao | Chỉ gửi alert | ❌ Cần người điều tra thủ công |

**MTTR trung bình (thủ công):** 10-20 phút (thời gian từ alert → người nhận → login → fix)

### 3.2 Sau khi tích hợp Ansible Webhook Receiver

| Tình huống | Hành động tự động | Kết quả |
|---|---|---|
| TinyServiceDown (critical) | Alertmanager → webhook_receiver → Ansible restart | ✅ Tự phục hồi trong ~30 giây |
| HighErrorRate (critical) | Alertmanager → webhook_receiver → Ansible restart | ✅ Tự phục hồi trong ~30 giây |
| HighLatencyP99 (warning) | Chỉ gửi Discord, không auto-restart | ⚠️ Cần người điều tra |

**MTTR trung bình (tự động):** ~30-60 giây

### 3.3 So sánh MTTR

```
Thủ công:    Alert → Người nhận → Login → Fix
             |←──── 10-20 phút ────────────→|

Tự động:     Alert → Ansible trigger → Restart → Healthy
             |←────── 30-60 giây ────────────→|

Cải thiện: Giảm MTTR ~95%
```

---

## 4. Kiến trúc tự động hóa đầy đủ

### 4.1 Các thành phần

| Thành phần | File | Vai trò |
|---|---|---|
| Ansible Playbook | `restart_service.yml` | Thực thi recovery |
| Webhook Receiver | `webhook_receiver.py` | Nhận alert → trigger Ansible |
| Alertmanager config | `alertmanager.yml` | Route alert đến đúng receiver |
| Inventory | `inventory.ini` | Khai báo host target |
| Log | `/var/log/sre-recovery.log` | Audit trail |

### 4.2 Phân loại alert theo mức độ tự động hóa

| Alert | Severity | Hành động tự động | Hành động thủ công |
|---|---|---|---|
| TinyServiceDown | Critical | ✅ Ansible restart ngay | Điền postmortem |
| HighErrorRate | Critical | ✅ Ansible restart ngay | Điều tra root cause |
| HighLatencyP99 | Warning | ❌ Chỉ notify | Xem Jaeger, kiểm tra CPU |

---

## 5. Hướng dẫn chạy hệ thống tự động hóa

### Bước 1 — Khởi động Webhook Receiver
```bash
# Mở terminal riêng
cd ~/SRE/sre-project
sudo touch /var/log/sre-webhook-receiver.log
sudo chmod 666 /var/log/sre-webhook-receiver.log
python3 ansible/webhook_receiver.py
```

Verify receiver đang chạy:
```bash
curl http://localhost:5001/health
```

### Bước 2 — Cập nhật Alertmanager config
```bash
# Backup config cũ
cp alertmanager/alertmanager.yml alertmanager/alertmanager.yml.bak

# Copy config mới (có thêm webhook receiver)
cp ansible/alertmanager.yml alertmanager/alertmanager.yml

# Restart alertmanager
docker compose up -d --force-recreate alertmanager
```

### Bước 3 — Test toàn bộ luồng tự động
```bash
# Chạy chaos test
./chaos/01-kill-service.sh

# Quan sát webhook receiver log (terminal khác)
tail -f /var/log/sre-webhook-receiver.log

# Xem lịch sử recovery
curl http://localhost:5001/logs | python3 -m json.tool
```

### Bước 4 — Verify tự động hóa hoạt động
```bash
# Kiểm tra service đã được restart tự động chưa
curl http://localhost:5000/health

# Xem log Ansible
cat /var/log/sre-recovery.log
```

---

## 6. Kết luận

### Điểm đạt được
- Hệ thống cảnh báo phản ứng trong 55-145 giây khi vi phạm SLI/SLO
- Tự động hóa recovery cho Critical alerts, giảm MTTR từ 10-20 phút xuống 30-60 giây
- Audit trail đầy đủ qua log file
- Cooldown mechanism tránh recovery loop

### Hạn chế
- Warning alerts (HighLatencyP99) vẫn cần can thiệp thủ công
- Chưa có alert cho CPU stress
- Webhook receiver chạy ngoài Docker, chưa được container hóa

### Đề xuất cải thiện
1. Thêm alerting rule cho CPU usage > 80%
2. Container hóa webhook_receiver vào docker-compose.yml
3. Thêm multi-window SLO burn rate alerts
4. Tích hợp PagerDuty/OpsGenie cho escalation
