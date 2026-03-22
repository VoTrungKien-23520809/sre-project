# SLI / SLO Definition — Tiny Web Service

## Service Overview
- **Service**: tiny-service (Python Flask Web API)
- **Owner**: NT533.Q22 Group
- **Last updated**: 2026-03-22

---

## SLI 1 — Availability (Request Success Rate)

**Definition**: Tỉ lệ HTTP requests trả về status code 2xx trên tổng số requests.

**PromQL**:
```promql
sum(rate(http_requests_total{status_code=~"2.."}[5m]))
/
sum(rate(http_requests_total[5m]))
```

**Rationale**: Đây là chỉ số trực tiếp nhất đo lường service có "sống" và hoạt động đúng không từ góc độ người dùng.

---

## SLI 2 — Latency (P99 Response Time)

**Definition**: 99th percentile của thời gian xử lý HTTP request, đo theo endpoint.

**PromQL**:
```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le, endpoint)
)
```

**Rationale**: P99 thay vì average vì average che giấu outliers — 1% user bị chậm 5 giây vẫn là vấn đề nghiêm trọng.

---

## SLO — Service Level Objective

| Mục tiêu | Chỉ số | Ngưỡng | Window |
|---|---|---|---|
| Availability SLO | SLI 1 — Success Rate | ≥ 99.5% | 30 ngày rolling |
| Latency SLO | SLI 2 — P99 Latency | ≤ 500ms | 30 ngày rolling |

---

## Error Budget

Với SLO Availability 99.5% trong 30 ngày:
- Tổng thời gian: 30 × 24 × 60 = 43,200 phút
- **Error budget = 0.5% × 43,200 = 216 phút** (~3.6 giờ được phép downtime/tháng)

---

## Alerting Rules

| Alert | Ngưỡng | Severity | Ý nghĩa |
|---|---|---|---|
| HighErrorRate | Error rate > 20% trong 1 phút | Critical | Service đang có vấn đề nghiêm trọng |
| HighLatencyP99 | P99 > 1s trong 1 phút | Warning | Service đang chậm bất thường |