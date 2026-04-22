# On-Call Runbook — SRE Observability Project
**NT533.Q22 2026 | Người 4: Phục hồi & Tự động hóa**

---

## Tổng quan

Tài liệu này mô tả quy trình xử lý sự cố (on-call procedure) khi nhận được alert từ hệ thống giám sát. Mỗi alert có một runbook riêng với các bước xử lý cụ thể.

**Nguyên tắc chung:**
- Ưu tiên khôi phục dịch vụ trước, điều tra sau
- Mọi hành động phải được ghi lại vào log/postmortem
- Nếu không tự xử lý được sau 15 phút → escalate

---

## Danh sách Alert & Runbook

| Alert | Severity | SLO ảnh hưởng | Runbook |
|---|---|---|---|
| HighErrorRate | Critical | Availability ≥ 99.5% | [Xem Mục 1](#1-highErrorRate) |
| HighLatencyP99 | Warning | Latency P99 ≤ 500ms | [Xem Mục 2](#2-highlatencyp99) |

---

## 1. HighErrorRate (Critical) {#1-highErrorRate}

**Điều kiện kích hoạt:** Error rate > 20% trong 1 phút liên tục  
**Mức độ:** 🔴 Critical — ảnh hưởng trực tiếp đến SLO Availability  
**Error Budget tương ứng:** 216 phút/tháng

### Triệu chứng
- Discord/Telegram nhận alert `HighErrorRate` firing
- Grafana dashboard: tỉ lệ HTTP 5xx tăng đột biến
- `/api/error` endpoint trả về 500 liên tục

### Quy trình xử lý

#### Bước 1 — Xác nhận alert (1-2 phút)
```bash
# Kiểm tra alert đang firing
curl http://localhost:9090/api/v1/alerts | python3 -m json.tool | grep -A5 "HighErrorRate"

# Xem error rate thực tế
curl -s "http://localhost:9090/api/v1/query?query=sum(rate(http_requests_total{status=~\"5..\"}[1m]))/sum(rate(http_requests_total[1m]))" \
  | python3 -m json.tool
```

**Kết quả mong đợi:** Thấy `"state": "firing"` và giá trị > 0.20

#### Bước 2 — Kiểm tra container (1 phút)
```bash
# Xem trạng thái các container
docker compose ps

# Xem log của tiny-service (30 dòng gần nhất)
docker compose logs --tail=30 tiny-service
```

**Dấu hiệu lỗi thường gặp:**
- Container ở trạng thái `Restarting` hoặc `Exited` → đi Bước 3A
- Container `Up` nhưng log có exception → đi Bước 3B
- Container `Up` và log bình thường → đi Bước 3C (chaos test đang chạy)

#### Bước 3A — Container bị crash: Restart
```bash
# Restart bằng Ansible (khuyến nghị — có ghi log tự động)
cd ~/SRE/sre-project
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml

# Hoặc restart thủ công
docker compose restart tiny-service

# Verify
curl http://localhost:5000/health
```

#### Bước 3B — Container Up nhưng có exception trong log
```bash
# Xem log chi tiết hơn
docker compose logs --tail=100 tiny-service | grep -i "error\|exception\|traceback"

# Rebuild và restart
docker compose build --no-cache tiny-service
docker compose up -d tiny-service
```

#### Bước 3C — Chaos test đang chạy (error bơm vào có chủ ý)
```bash
# Kiểm tra xem có chaos script nào đang chạy không
ps aux | grep chaos
ls chaos/

# Nếu là chaos test có chủ ý → ghi nhận vào postmortem, không cần fix
# Nếu không phải → tiếp tục điều tra
```

#### Bước 4 — Verify đã resolved (2-3 phút)
```bash
# Sinh traffic test
for i in $(seq 1 20); do
  curl -s http://localhost:5000/api/data > /dev/null
  sleep 0.3
done

# Kiểm tra error rate mới
curl -s "http://localhost:9090/api/v1/query?query=sum(rate(http_requests_total{status=~\"5..\"}[1m]))/sum(rate(http_requests_total[1m]))" \
  | python3 -m json.tool

# Alert tự resolve sau ~1 phút nếu error rate < 20%
```

#### Bước 5 — Ghi nhận sự cố
- Điền vào **postmortem_template.md**
- Ghi thời gian: alert firing → phát hiện → fix → resolved
- Tính error budget đã tiêu thụ

---

## 2. HighLatencyP99 (Warning) {#2-highlatencyp99}

**Điều kiện kích hoạt:** P99 latency > 1s trong 1 phút liên tục  
**Mức độ:** 🟡 Warning — có nguy cơ vi phạm SLO Latency  
**SLO tương ứng:** P99 ≤ 500ms/30 ngày

### Triệu chứng
- Discord/Telegram nhận alert `HighLatencyP99` firing
- Grafana: đường P99 latency vượt ngưỡng 1s
- `/api/slow` hoặc `/api/data` phản hồi chậm

### Quy trình xử lý

#### Bước 1 — Xác nhận alert (1-2 phút)
```bash
# Kiểm tra P99 hiện tại
curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket[1m]))" \
  | python3 -m json.tool

# Xem Jaeger traces để tìm request chậm
# Truy cập: http://localhost:16686 → chọn service tiny-service → tìm trace có duration cao
```

#### Bước 2 — Kiểm tra tải hệ thống
```bash
# CPU và RAM của host
top -bn1 | head -20

# CPU stress test đang chạy không?
ps aux | grep stress

# Container đang dùng bao nhiêu resource
docker stats --no-stream
```

**Nguyên nhân thường gặp:**
- CPU stress đang chạy (chaos test) → đợi kết thúc hoặc kill
- `/api/slow` endpoint bị gọi nhiều → bình thường nếu là test
- Tải thật sự cao → xem Bước 3

#### Bước 3 — Giảm tải
```bash
# Nếu có CPU stress process đang chạy từ chaos test
pkill stress

# Restart tiny-service để clear pending requests
docker compose restart tiny-service

# Verify latency sau khi restart
curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket[1m]))" \
  | python3 -m json.tool
```

#### Bước 4 — Verify resolved
```bash
# Sinh traffic bình thường
for i in $(seq 1 30); do
  curl -s http://localhost:5000/api/data > /dev/null
  sleep 0.3
done

# P99 phải trở về < 500ms sau ~2 phút
```

---

## Escalation Policy

| Thời gian | Hành động |
|---|---|
| 0 phút | Nhận alert, bắt đầu runbook |
| 5 phút | Nếu chưa xác định được nguyên nhân → ping nhóm trên Discord |
| 10 phút | Nếu chưa fix được → tag cả nhóm, báo cáo trạng thái |
| 15 phút | Escalate lên giảng viên/supervisor nếu cần |

---

## Liên hệ khẩn cấp

| Vai trò | Người | Liên hệ |
|---|---|---|
| Người 1 — Hạ tầng | TBD | Discord: @person1 |
| Người 2 — Observability | TBD | Discord: @person2 |
| Người 3 — SRE/Chaos | TBD | Discord: @person3 |
| Người 4 — Recovery | sangnn1908 | Discord: @person4 |

---

## Checklist nhanh khi có alert

```
□ 1. Xác nhận alert thật (không phải false positive)
□ 2. Kiểm tra docker compose ps
□ 3. Xem log: docker compose logs --tail=50 tiny-service
□ 4. Chạy Ansible playbook hoặc restart thủ công
□ 5. Verify health check pass
□ 6. Xác nhận alert resolved trên Prometheus
□ 7. Điền postmortem nếu downtime > 5 phút
```
