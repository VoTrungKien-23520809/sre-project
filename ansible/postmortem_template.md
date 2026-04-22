# Post-Mortem Report

**NT533.Q22 2026 — SRE Observability Project**

---

## Thông tin sự cố

| Trường | Nội dung |
|---|---|
| **Tiêu đề** | [Mô tả ngắn gọn — VD: Tiny Service Down do CPU Stress Chaos Test] |
| **Ngày xảy ra** | DD/MM/YYYY |
| **Thời gian bắt đầu** | HH:MM (ICT, UTC+7) |
| **Thời gian kết thúc** | HH:MM (ICT, UTC+7) |
| **Tổng thời gian downtime** | X phút |
| **Severity** | Critical / Warning |
| **Alert kích hoạt** | HighErrorRate / HighLatencyP99 / Cả hai |
| **Người phát hiện** | Tên + vai trò |
| **Người xử lý** | Tên + vai trò |

---

## Tóm tắt (Executive Summary)

> Viết 3-5 câu mô tả: sự cố là gì, xảy ra lúc nào, ảnh hưởng ra sao, đã được fix như thế nào.

**Ví dụ:**  
Vào lúc 14:30 ngày XX/XX/2026, alert `HighErrorRate` firing do chaos script của Người 3 kill container `tiny-service`. Dịch vụ không phản hồi trong 8 phút. Hệ thống tự phục hồi một phần nhờ Docker restart policy, và được xử lý hoàn toàn bằng Ansible playbook lúc 14:38. Tổng error budget tiêu thụ: 8 phút / 216 phút (3.7%).

---

## SLO Impact

| SLO | Ngưỡng | Thực tế trong sự cố | Vi phạm? |
|---|---|---|---|
| Availability | ≥ 99.5% | XX% | ✅ / ❌ |
| Latency P99 | ≤ 500ms | XXXms | ✅ / ❌ |
| Error Budget còn lại | 216 phút/tháng | Tiêu thụ thêm X phút | XX phút còn lại |

---

## Timeline sự cố

| Thời gian | Sự kiện |
|---|---|
| HH:MM | Chaos test bắt đầu (người 3 chạy script) |
| HH:MM | Alert `HighErrorRate` firing trên Prometheus |
| HH:MM | Thông báo Discord nhận được |
| HH:MM | Người 4 bắt đầu điều tra |
| HH:MM | Xác định nguyên nhân: [mô tả] |
| HH:MM | Chạy Ansible playbook restart |
| HH:MM | Container healthy trở lại |
| HH:MM | Alert resolved tự động |
| HH:MM | Verify metrics bình thường |

---

## Nguyên nhân gốc rễ (Root Cause Analysis)

### Nguyên nhân trực tiếp (Immediate Cause)
> Điều gì trực tiếp gây ra sự cố?

**Ví dụ:** Script chaos `chaos/kill_pod.sh` dừng container `tiny-service`, khiến tất cả request trả về connection refused (HTTP 502/503).

### Nguyên nhân gốc rễ (Root Cause)
> Tại sao nguyên nhân trực tiếp đó xảy ra?

**Ví dụ:** Chaos test được thiết kế để kill pod nhằm kiểm tra khả năng self-healing của hệ thống. Đây là hành động có chủ ý trong khuôn khổ đồ án.

### Contributing Factors (Yếu tố góp phần)
- [ ] Không có liveness probe / readiness probe tự động restart
- [ ] Docker restart policy chưa được cấu hình (`restart: unless-stopped`)
- [ ] Alerting delay (thời gian từ khi lỗi đến khi alert firing)
- [ ] Khác: ___

---

## Metrics & Evidence

### Grafana Screenshots
> Chèn ảnh chụp màn hình Grafana dashboard lúc sự cố xảy ra

- [ ] Error rate spike chart
- [ ] P99 latency chart  
- [ ] CPU/RAM usage (nếu có stress test)

### Prometheus Queries dùng để điều tra
```promql
# Error rate tại thời điểm sự cố
sum(rate(http_requests_total{status=~"5.."}[1m])) / sum(rate(http_requests_total[1m]))

# P99 latency
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[1m]))

# Request rate tổng
sum(rate(http_requests_total[1m]))
```

### Jaeger Traces
> Mô tả trace nào bất thường, latency cao ở span nào

---

## Quy trình xử lý đã thực hiện

```bash
# Lệnh đã chạy theo thứ tự:
# 1. Kiểm tra trạng thái
docker compose ps

# 2. Xem log
docker compose logs --tail=50 tiny-service

# 3. Chạy Ansible recovery
ansible-playbook -i ansible/inventory.ini ansible/restart_service.yml

# 4. Verify
curl http://localhost:5000/health
```

**Thời gian từ khi phát hiện đến khi fix:** X phút  
**MTTR (Mean Time To Recovery):** X phút

---

## Lessons Learned

### Điều làm tốt ✅
- Alert kích hoạt đúng và kịp thời
- Ansible playbook hoạt động đúng như thiết kế
- Log recovery đầy đủ để trace lại

### Điều cần cải thiện ⚠️
- Cần thêm `restart: unless-stopped` vào `docker-compose.yml`
- Cần cấu hình liveness probe để tự restart nhanh hơn
- Alert delay X giây cần giảm xuống

---

## Action Items (Việc cần làm sau sự cố)

| # | Hành động | Người phụ trách | Deadline | Trạng thái |
|---|---|---|---|---|
| 1 | Thêm `restart: unless-stopped` vào docker-compose.yml | Người 1 | DD/MM | 🔲 |
| 2 | Cấu hình health check interval ngắn hơn trong Prometheus | Người 2 | DD/MM | 🔲 |
| 3 | Viết thêm chaos scenario cho network latency | Người 3 | DD/MM | 🔲 |
| 4 | Cập nhật runbook dựa trên kinh nghiệm sự cố này | Người 4 | DD/MM | 🔲 |

---

## Kết luận

> Viết 2-3 câu tổng kết: hệ thống phản ứng như thế nào, công cụ observability có đủ nhạy không, điểm cần cải thiện cho lần sau.

---

*Post-mortem được viết bởi: Người 4 — Phục hồi & Tự động hóa*  
*Ngày viết: DD/MM/YYYY*  
*Review bởi: [Tên người review]*
