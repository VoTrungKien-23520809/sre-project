# On-Call Runbook — SRE Observability Project
**NT533.Q22 2026 | Người 4: Phục hồi & Tự động hóa**

---

## Tổng quan

Tài liệu này mô tả quy trình xử lý sự cố (on-call procedure) cho **4 kịch bản Chaos Test** tương ứng với 4 script trong folder `chaos/`. Mỗi kịch bản có runbook riêng với các bước xử lý cụ thể.

**Nguyên tắc chung:**
- Ưu tiên khôi phục dịch vụ trước, điều tra sau
- Mọi hành động phải được ghi lại vào log/postmortem
- Nếu không tự xử lý được sau 15 phút → escalate

---

## Danh sách kịch bản & Alert

| # | Chaos Script | Alert kích hoạt | Severity | Tự động hóa | Runbook |
|---|---|---|---|---|---|
| 1 | `01-kill-service.sh` | `TinyServiceDown` | 🔴 Critical | ✅ Ansible tự động | [Mục 1](#1-tinyservicedown) |
| 2 | `02-error-rate.sh` | `HighErrorRate` | 🔴 Critical | ✅ Ansible tự động | [Mục 2](#2-higherrorrate) |
| 3 | `03-latency-load.sh` | `HighLatencyP99` | 🟡 Warning | ❌ Thủ công | [Mục 3](#3-highlatencyp99) |
| 4 | `04-cpu-stress.sh` | Không có alert | ⚪ Manual | ❌ Thủ công | [Mục 4](#4-cpu-stress) |

---

## 1. TinyServiceDown — `01-kill-service.sh` {#1-tinyservicedown}

**Điều kiện kích hoạt:** `up{job="tiny-service"} == 0` trong 30 giây  
**Mức độ:** 🔴 Critical — service hoàn toàn không phản hồi  
**Tự động hóa:** ✅ Ansible Webhook Receiver tự trigger khi nhận alert  
**SLO ảnh hưởng:** Availability ≥ 99.5% (tiêu thụ Error Budget)

### Triệu chứng
- Discord nhận alert `[FIRING] TinyServiceDown` + thông báo `🤖 Auto Recovery đang chạy...`
- `curl http://localhost:5000/health` → `Connection refused`
- Prometheus: `up{job="tiny-service"} == 0`
- Grafana: Request rate về 0

### Quy trình xử lý

#### Bước 1 — Kiểm tra tự động hóa đã chạy chưa (30 giây)
```bash
# Xem webhook receiver có nhận alert không
curl http://localhost:5001/logs | python3 -m json.tool

# Xem log Ansible recovery
tail -20 /var/log/sre-recovery.log
```

Nếu thấy `[END] Recovery completed` → Ansible đã xử lý, chuyển sang **Bước 4 Verify**.  
Nếu chưa thấy → chuyển **Bước 2**.

#### Bước 2 — Xác nhận alert & trạng thái container
```bash
# Kiểm tra alert firing
curl http://localhost:9090/api/v1/alerts | python3 -m json.tool | grep -A5 "TinyServiceDown"

# Xem trạng thái container
docker compose ps

# Xem log container
docker compose logs --tail=30 tiny-service
```

#### Bước 3 — Khôi phục service
```bash
# Ưu tiên: chạy Ansible (có ghi log, có verify tự động)
cd ~/SRE/sre-project
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml

# Hoặc restart nhanh thủ công
docker compose up -d tiny-service
```

#### Bước 4 — Verify đã recovered
```bash
# Health check
curl http://localhost:5000/health

# Prometheus target up chưa
curl -s "http://localhost:9090/api/v1/query?query=up{job=\"tiny-service\"}" \
  | python3 -m json.tool

# Chờ ~1 phút → Alert tự resolved trên Discord
```

#### Bước 5 — Ghi nhận
- Điền `postmortem_template.md`
- Tính error budget tiêu thụ: thời gian từ `kill` đến `health check pass`
- Chụp ảnh Prometheus alert + Discord notification

---

## 2. HighErrorRate — `02-error-rate.sh` {#2-higherrorrate}

**Điều kiện kích hoạt:** Error rate > 20% trong 1 phút liên tục  
**Mức độ:** 🔴 Critical — vi phạm SLO Availability  
**Tự động hóa:** ✅ Ansible Webhook Receiver tự trigger khi nhận alert  
**SLO ảnh hưởng:** Availability ≥ 99.5%

### Triệu chứng
- Discord nhận alert `[FIRING] HighErrorRate` + `🤖 Auto Recovery đang chạy...`
- Grafana: HTTP 5xx rate tăng đột biến > 20%
- `/api/error` trả về 500 liên tục (~50% xác suất)

### Quy trình xử lý

#### Bước 1 — Kiểm tra tự động hóa đã chạy chưa
```bash
tail -20 /var/log/sre-recovery.log
curl http://localhost:5001/logs | python3 -m json.tool
```

#### Bước 2 — Xác nhận error rate thực tế
```bash
curl -s "http://localhost:9090/api/v1/query?query=sum(rate(http_requests_total{status=~\"5..\"}[1m]))/sum(rate(http_requests_total[1m]))" \
  | python3 -m json.tool
```
Kết quả > 0.20 → xác nhận alert đúng.

#### Bước 3 — Kiểm tra nguyên nhân
```bash
# Container bình thường không?
docker compose ps
docker compose logs --tail=50 tiny-service | grep -i "error\|500"

# Chaos script đang chạy?
ps aux | grep "02-error"
```

**Phân nhánh:**
- Container `Exited` → chạy Ansible restart (Bước 3A)
- Container `Up`, log bình thường, chaos script đang chạy → đây là lỗi có chủ ý (Bước 3B)
- Container `Up`, log có exception → rebuild (Bước 3C)

#### Bước 3A — Restart qua Ansible
```bash
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml
```

#### Bước 3B — Chaos test có chủ ý
```bash
# Chờ script kết thúc tự nhiên hoặc dừng thủ công
# Sau đó chạy recover
./chaos/05-recover.sh
```

#### Bước 3C — Rebuild service
```bash
docker compose build --no-cache tiny-service
docker compose up -d tiny-service
```

#### Bước 4 — Verify
```bash
# Sinh traffic bình thường
for i in $(seq 1 20); do
  curl -s http://localhost:5000/api/data > /dev/null
  sleep 0.3
done

# Kiểm tra error rate đã giảm
curl -s "http://localhost:9090/api/v1/query?query=sum(rate(http_requests_total{status=~\"5..\"}[1m]))/sum(rate(http_requests_total[1m]))" \
  | python3 -m json.tool
# Kỳ vọng: giá trị < 0.20
```

#### Bước 5 — Ghi nhận
- Điền `postmortem_template.md`
- Ghi rõ: lỗi do chaos test hay lỗi thật

---

## 3. HighLatencyP99 — `03-latency-load.sh` {#3-highlatencyp99}

**Điều kiện kích hoạt:** P99 latency > 1s trong 1 phút liên tục  
**Mức độ:** 🟡 Warning — có nguy cơ vi phạm SLO Latency  
**Tự động hóa:** ❌ Cần người điều tra (nguyên nhân đa dạng)  
**SLO ảnh hưởng:** Latency P99 ≤ 500ms

### Triệu chứng
- Discord nhận alert `[FIRING] HighLatencyP99`
- Grafana: đường P99 latency vượt ngưỡng 1s
- Jaeger: traces của `/api/slow` có duration cao

### Quy trình xử lý

#### Bước 1 — Xác nhận P99 hiện tại
```bash
curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket[1m]))" \
  | python3 -m json.tool
```

#### Bước 2 — Xác định nguyên nhân
```bash
# CPU có bị stress không?
top -bn1 | head -5
ps aux | grep stress
docker stats --no-stream

# Chaos script latency đang chạy?
ps aux | grep "03-latency"

# Endpoint nào chậm? (xem Jaeger)
# http://localhost:16686 → service: tiny-service → sort by duration
```

**Phân nhánh:**
- Latency script `03-latency-load.sh` đang chạy → Bước 3A
- CPU stress đang chạy → Bước 3B
- Không có script nào → Bước 3C (tải thật)

#### Bước 3A — Latency chaos đang chạy
```bash
# Chờ script kết thúc tự nhiên hoặc:
./chaos/05-recover.sh

# Lưu ý: alert resolve chậm hơn ~5 phút do cửa sổ [5m]
MAX_WAIT_SECONDS=420 ./chaos/05-recover.sh
```

#### Bước 3B — CPU stress gây latency tăng
```bash
pkill stress
# Latency sẽ giảm sau ~2 phút
```

#### Bước 3C — Tải thật sự cao
```bash
# Restart để clear pending requests
docker compose restart tiny-service
curl http://localhost:5000/health
```

#### Bước 4 — Verify
```bash
for i in $(seq 1 30); do
  curl -s http://localhost:5000/api/data > /dev/null
  sleep 0.3
done

# P99 phải về < 500ms sau ~2-5 phút
curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket[1m]))" \
  | python3 -m json.tool
```

#### Bước 5 — Ghi nhận
- Xem Jaeger trace: span nào trong request chậm nhất
- Chụp ảnh Grafana panel P99 latency trước/sau
- Điền postmortem nếu vi phạm SLO kéo dài > 5 phút

---

## 4. CPU Stress — `04-cpu-stress.sh` {#4-cpu-stress}

**Điều kiện kích hoạt:** Thủ công — chưa có Prometheus alert rule  
**Mức độ:** ⚪ Manual — phát hiện qua Grafana  
**Tự động hóa:** ❌ Không có  
**SLO ảnh hưởng:** Gián tiếp qua Latency P99 nếu CPU quá tải

### Triệu chứng
- **Không có Discord alert** (chưa có rule)
- Grafana panel `Host CPU Usage` tăng lên 90-100%
- P99 latency tăng nhẹ nhưng thường không vượt ngưỡng
- `tiny-service` vẫn `Up` và health check vẫn pass

### Phát hiện qua Grafana
```bash
# Xem CPU usage qua Prometheus query
curl -s "http://localhost:9090/api/v1/query?query=clamp_min(100*(1-avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m]))),0)" \
  | python3 -m json.tool

# Xem docker stats
docker stats --no-stream
```

### Quy trình xử lý

#### Bước 1 — Xác nhận CPU stress đang chạy
```bash
top -bn1 | head -10
ps aux | grep stress
ps aux | grep "04-cpu"
```

#### Bước 2 — Đánh giá tác động
```bash
# Service còn up không?
curl http://localhost:5000/health

# Latency có tăng vượt ngưỡng SLO không?
curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,rate(http_request_duration_seconds_bucket[1m]))" \
  | python3 -m json.tool
```

**Phân nhánh:**
- Latency < 500ms, service Up → **Theo dõi**, không cần can thiệp (chaos test đang quan sát)
- Latency > 1s → Có thể trigger `HighLatencyP99` → xem [Mục 3](#3-highlatencyp99)
- Service Down → xem [Mục 1](#1-tinyservicedown)

#### Bước 3 — Kết thúc CPU stress (nếu cần)
```bash
# Dừng stress process
pkill stress

# Hoặc chạy recover script
./chaos/05-recover.sh

# Verify CPU về bình thường sau ~1 phút
docker stats --no-stream
```

#### Bước 4 — Ghi nhận kết quả
- Chụp ảnh Grafana: CPU usage trước/trong/sau stress
- Ghi nhận: latency có bị ảnh hưởng không, bao nhiêu %
- Chụp ảnh Jaeger traces trong lúc CPU cao

> **Đề xuất cải thiện:** Thêm Prometheus alert rule `HighCPUUsage` để tự động phát hiện:
> ```yaml
> - alert: HighCPUUsage
>   expr: clamp_min(100*(1-avg(rate(node_cpu_seconds_total{mode="idle"}[1m]))),0) > 80
>   for: 2m
>   labels:
>     severity: warning
>   annotations:
>     summary: "CPU usage cao trên host"
>     description: "CPU usage > 80% trong 2 phút liên tục"
> ```

---

## Escalation Policy

| Thời gian | Hành động |
|---|---|
| T+0 | Nhận alert, bắt đầu runbook |
| T+5 phút | Chưa xác định nguyên nhân → ping nhóm Discord |
| T+10 phút | Chưa fix → tag cả nhóm, báo trạng thái |
| T+15 phút | Escalate lên giảng viên nếu cần |

---

## Liên hệ khẩn cấp

| Vai trò | Người | Liên hệ |
|---|---|---|
| Người 1 — Hạ tầng | TBD | Discord: @person1 |
| Người 2 — Observability | TBD | Discord: @person2 |
| Người 3 — SRE/Chaos | TBD | Discord: @person3 |
| Người 4 — Recovery | Sáng Nguyễn | Discord: @sangnn1908 |

---

## Checklist nhanh khi có alert

```
□ 1. Xác nhận alert thật (không phải false positive)
□ 2. Kiểm tra webhook receiver đã tự động trigger chưa
□ 3. Xem log: tail -20 /var/log/sre-recovery.log
□ 4. Nếu chưa tự động → chạy Ansible thủ công
□ 5. Verify health check pass: curl http://localhost:5000/health
□ 6. Xác nhận alert resolved trên Prometheus
□ 7. Chụp ảnh Grafana + Discord để làm báo cáo
□ 8. Điền postmortem_template.md nếu downtime > 5 phút
```
