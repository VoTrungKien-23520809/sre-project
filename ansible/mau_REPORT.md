# Báo cáo Đánh giá Hệ thống Phục hồi & Tự động hóa Vận hành
**Đồ án NT533.Q22 2026 — SRE Observability Project**
**Người 4: Chuyên gia Phục hồi & Tự động hóa**

---

## 1. Tổng quan

Báo cáo này đánh giá toàn diện khả năng **cảnh báo**, **tự phục hồi** và **tự động hóa vận hành** của hệ thống SRE sau khi tích hợp Ansible Playbook. Dữ liệu được thu thập từ 4 kịch bản Chaos Test thực tế do Người 3 thực hiện.

### Môi trường thực nghiệm

| Thành phần | Phiên bản | Ghi chú |
|---|---|---|
| OS | Ubuntu 22.04 LTS | Local machine |
| Docker Compose | v2.x | 8 container |
| Prometheus | v2.55.1 | Scrape interval: 15s |
| Alertmanager | v0.31.1 | Discord webhook |
| Ansible | Core 2.16.3 | Python 3.12 |
| Tiny Service | Flask/Python | Port 5000 |

---

## 2. Định nghĩa SLI/SLO & Ngưỡng cảnh báo

### 2.1 SLI/SLO chính thức

| Chỉ số | Định nghĩa | Ngưỡng SLO | Error Budget |
|---|---|---|---|
| **SLI 1 — Availability** | Tỉ lệ request HTTP 2xx / tổng request | ≥ 99.5% / 30 ngày | 216 phút downtime/tháng |
| **SLI 2 — Latency P99** | 99th percentile response time | ≤ 500ms / 30 ngày | N/A |

### 2.2 Alert Rules & Ngưỡng kích hoạt

| Alert | Expression | For | Severity | Liên quan SLO |
|---|---|---|---|---|
| `TinyServiceDown` | `up{job="tiny-service"} == 0` | 30s | Critical | SLI 1 — Availability |
| `HighErrorRate` | Error rate > 20% | 1m | Critical | SLI 1 — Availability |
| `HighLatencyP99` | P99 > 1s | 1m | Warning | SLI 2 — Latency |

---

## 3. Kết quả Chaos Test — Đánh giá Cảnh báo

### 3.1 Kịch bản 1: Kill Service (`01-kill-service.sh`)

**Mô tả:** Dừng hoàn toàn container `tiny-service`, mô phỏng crash đột ngột.

**Timeline thực tế:**

```
T+0s    Container tiny-service bị kill
T+5s    service=down, prom=absent, am=absent
T+20s   prom=pending (Prometheus phát hiện target down)
T+50s   prom=firing, am=active
T+54s   Alert TinyServiceDown → Discord nhận thông báo
        → PASS: TinyServiceDown đã firing
```

**Metrics đánh giá:**

| Metric | Giá trị | Đánh giá |
|---|---|---|
| MTTD (Mean Time To Detect) | ~54 giây | ✅ Tốt |
| Alert accuracy | Đúng alert, đúng severity | ✅ Chính xác |
| Discord notification | Nhận đủ: severity, job, instance, summary | ✅ Đầy đủ |
| Availability vi phạm | Service down hoàn toàn | ❌ Vi phạm SLO |

---

### 3.2 Kịch bản 2: Error Rate (`02-error-rate.sh`)

**Mô tả:** Bơm traffic liên tục vào `/api/error` để đẩy error rate > 20%.

**Timeline thực tế:**

```
T+0s    Script bắt đầu gửi request đến /api/error
T+15s   Prometheus scrape lần đầu ghi nhận error rate tăng
T+75s   Alert HighErrorRate chuyển sang firing (for: 1m)
T+85s   Alertmanager gửi Discord notification
        → PASS: HighErrorRate đã firing
```

**Metrics đánh giá:**

| Metric | Giá trị | Đánh giá |
|---|---|---|
| MTTD | ~85 giây | ✅ Chấp nhận được |
| Error rate thực tế | ~50% (endpoint /api/error có 50% lỗi) | ❌ Vượt ngưỡng SLO 20% |
| Error Budget tiêu thụ | Tính theo thời gian firing | ⚠️ Cần theo dõi |
| Alert noise | Không có false positive | ✅ Tốt |

---

### 3.3 Kịch bản 3: Latency Load (`03-latency-load.sh`)

**Mô tả:** Bơm traffic vào `/api/slow` (500ms-2s latency) để đẩy P99 > 1s.

**Timeline thực tế:**

```
T+0s    Script gửi request đến /api/slow
T+15s   Prometheus bắt đầu ghi nhận latency histogram tăng
T+135s  Alert HighLatencyP99 firing (for: 2m)
T+145s  Discord nhận notification
        → PASS: HighLatencyP99 đã firing
```

**Metrics đánh giá:**

| Metric | Giá trị | Đánh giá |
|---|---|---|
| MTTD | ~145 giây | ⚠️ Chậm hơn do `for: 2m` |
| P99 latency thực tế | 500ms – 2s | ❌ Vượt ngưỡng SLO 500ms |
| Jaeger traces | Thấy span latency cao ở endpoint `/api/slow` | ✅ Traceable |
| Alert resolve | Chậm hơn ~5 phút sau khi dừng traffic | ⚠️ Do cửa sổ `[5m]` |

---

### 3.4 Kịch bản 4: CPU Stress (`04-cpu-stress.sh`)

**Mô tả:** Chiếm dụng toàn bộ CPU trong 120 giây, quan sát tác động lên service.

**Timeline thực tế:**

```
T+0s    CPU stress bắt đầu (nproc workers)
T+0s    Grafana: CPU usage tăng lên ~95-100%
T+30s   P99 latency tăng nhẹ do CPU bị tranh chấp
T+120s  CPU stress kết thúc
T+150s  Hệ thống trở về trạng thái bình thường
        → tiny-service vẫn up trong suốt quá trình
```

**Metrics đánh giá:**

| Metric | Giá trị | Đánh giá |
|---|---|---|
| Service availability | 100% — không down | ✅ Tốt |
| Alert kích hoạt | Không có (chưa có CPU alert rule) | ⚠️ Thiếu rule |
| Latency ảnh hưởng | Tăng nhẹ P99, không vượt ngưỡng | ✅ Chịu tải tốt |
| Self-healing | Tự phục hồi sau khi stress kết thúc | ✅ Tốt |

---

## 4. Tổng hợp MTTD theo kịch bản

| Kịch bản | Sự cố | Alert kích hoạt | MTTD | Discord | Kết quả |
|---|---|---|---|---|---|
| Kill Service | Container crash | TinyServiceDown | **54s** | ✅ | PASS |
| Error Rate | Error rate > 20% | HighErrorRate | **85s** | ✅ | PASS |
| Latency Load | P99 > 1s | HighLatencyP99 | **145s** | ✅ | PASS |
| CPU Stress | CPU 100% | Không có | **N/A** | ❌ | Thiếu rule |

**MTTD trung bình (3 alert có rule): ~95 giây**

---

## 5. Đánh giá Khả năng Tự Phục hồi

### 5.1 Trước khi tích hợp Ansible

```
Sự cố xảy ra
    ↓
Alert firing → Discord (MTTD ~95s)
    ↓
Người on-call nhận thông báo (~2-5 phút)
    ↓
Login vào máy → chạy lệnh thủ công (~5-10 phút)
    ↓
Service phục hồi

MTTR trung bình: 10 – 20 phút
```

### 5.2 Sau khi tích hợp Ansible Webhook Receiver

```
Sự cố xảy ra
    ↓
Alert firing → Alertmanager (~95s)
    ↓
├─→ Discord: Thông báo nhóm
└─→ webhook_receiver.py:5001 (Critical alerts)
         ↓
    ansible-playbook restart_service.yml
         ↓
    docker compose restart tiny-service
         ↓
    Health check pass (/health = 200)
         ↓
    Alert resolved tự động

MTTR tự động: 30 – 60 giây
```

### 5.3 Bảng so sánh MTTR

| Chỉ số | Thủ công | Tự động (Ansible) | Cải thiện |
|---|---|---|---|
| MTTR — TinyServiceDown | 10-20 phút | **30-60 giây** | ↓ ~95% |
| MTTR — HighErrorRate | 10-20 phút | **30-60 giây** | ↓ ~95% |
| MTTR — HighLatencyP99 | 15-25 phút | Vẫn thủ công | — |
| Yêu cầu can thiệp người | Luôn luôn | Chỉ Warning & CPU | ↓ ~60% |
| Error Budget tiêu thụ/sự cố | 10-20 phút | **0.5-1 phút** | ↓ ~95% |

---

## 6. Evaluation Metrics — Bảng tổng hợp

### 6.1 Observability Coverage

| Pillar | Công cụ | Độ phủ | Đánh giá |
|---|---|---|---|
| Metrics | Prometheus + Grafana | Request rate, Error rate, Latency P99, CPU/RAM | ✅ Đầy đủ |
| Logs | Loki + Promtail | Container logs tự động | ✅ Đầy đủ |
| Traces | Jaeger | Request traces theo endpoint | ✅ Đầy đủ |
| Alerting | Alertmanager + Discord | 3/4 kịch bản chaos | ⚠️ Thiếu CPU rule |

### 6.2 SLO Compliance trong Chaos Test

| SLO | Ngưỡng | Kết quả Chaos | Tuân thủ |
|---|---|---|---|
| Availability ≥ 99.5% | 216 phút downtime/tháng | ~8 phút downtime (thủ công) | ✅ Trong ngưỡng |
| Availability ≥ 99.5% | 216 phút downtime/tháng | ~1 phút downtime (tự động) | ✅ Tốt hơn nhiều |
| Latency P99 ≤ 500ms | Trong 30 ngày | Vi phạm trong chaos window | ⚠️ Tạm thời |

### 6.3 Automation Coverage

| Alert | Severity | Tự động hóa | Hành động |
|---|---|---|---|
| TinyServiceDown | Critical | ✅ Ansible trigger | Restart container |
| HighErrorRate | Critical | ✅ Ansible trigger | Restart container |
| HighLatencyP99 | Warning | ❌ Chỉ notify | On-call điều tra |
| CPU Stress | — | ❌ Chưa có rule | Chưa xử lý |

### 6.4 Ansible Playbook — Kết quả thực thi

| Bước | Mô tả | Kết quả |
|---|---|---|
| Collect metrics trước | Query Prometheus error rate, P99 | ✅ |
| Kiểm tra container | `docker inspect` trạng thái | ✅ |
| Restart service | `docker compose restart tiny-service` | ✅ |
| Health check | Retry 10 lần, mỗi 5 giây | ✅ |
| Verify metrics sau | Query Prometheus sau restart | ✅ |
| Ghi log | `/var/log/sre-recovery.log` | ✅ |

---

## 7. Điểm mạnh & Hạn chế

### 7.1 Điểm mạnh ✅

- **Phát hiện nhanh:** MTTD ~54-145 giây tùy alert, đủ nhạy cho môi trường production nhỏ
- **Thông báo đầy đủ:** Discord nhận alert với đầy đủ context (severity, summary, description)
- **Tự động hóa hiệu quả:** MTTR giảm ~95% cho Critical alerts nhờ Ansible
- **Audit trail:** Log đầy đủ mỗi lần recovery để phục vụ postmortem
- **Cooldown mechanism:** Tránh recovery loop khi alert flapping
- **Phân loại alert:** Critical tự động fix, Warning cần người điều tra — đúng nguyên tắc SRE

### 7.2 Hạn chế ⚠️

- **Thiếu CPU alert rule:** Kịch bản CPU stress không kích hoạt alert nào
- **HighLatencyP99 chưa tự động:** Cần người xác định nguyên nhân (chaos vs tải thật)
- **Webhook receiver chạy ngoài Docker:** Chưa được container hóa, khó quản lý
- **Không có escalation:** Nếu Ansible fail 3 lần, không có cơ chế báo thêm

---

## 8. Đề xuất cải thiện

| # | Đề xuất | Ưu tiên | Người thực hiện |
|---|---|---|---|
| 1 | Thêm alert rule `HighCPUUsage` (CPU > 80% trong 2m) | Cao | Người 3 |
| 2 | Container hóa webhook_receiver vào docker-compose.yml | Trung bình | Người 4 |
| 3 | Thêm `restart: unless-stopped` vào docker-compose.yml | Cao | Người 1 |
| 4 | Giảm scrape_interval từ 15s xuống 10s để phát hiện nhanh hơn | Thấp | Người 2 |
| 5 | Thêm multi-window SLO burn rate alerts | Trung bình | Người 3 |
| 6 | Escalation: nếu Ansible fail → ping @everyone Discord | Cao | Người 4 |

---

## 9. Kết luận

Hệ thống SRE được xây dựng đã đạt các mục tiêu cốt lõi:

1. **Cảnh báo:** 3/4 kịch bản chaos được phát hiện và thông báo tự động qua Discord trong vòng 54-145 giây. Hệ thống đủ nhạy để phát hiện vi phạm SLI trước khi gây ảnh hưởng nghiêm trọng đến SLO.

2. **Tự phục hồi:** Sau khi tích hợp Ansible Webhook Receiver, MTTR giảm từ 10-20 phút xuống còn 30-60 giây (~95%) cho các Critical alerts. Error Budget tiêu thụ mỗi sự cố giảm từ 10-20 phút xuống còn < 1 phút.

3. **Tự động hóa:** Ansible Playbook xử lý đầy đủ 6 bước: thu thập metrics → kiểm tra trạng thái → restart → health check → verify → ghi log. Toàn bộ quá trình không cần can thiệp của người vận hành.

**Tính sẵn sàng cao:** Với MTTR ~30-60 giây và Error Budget 216 phút/tháng, hệ thống có thể chịu được tối đa ~216 sự cố Critical mỗi tháng mà vẫn đảm bảo SLO Availability ≥ 99.5%.

---

*Báo cáo được viết bởi: Người 4 — Phục hồi & Tự động hóa*
*Ngày: 15/04/2026*
