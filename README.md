# SRE Observability Project — NT533.Q22 2026

## Tổng quan

Hệ thống giám sát toàn diện cho một Web Service mẫu, triển khai trên AWS EKS với đầy đủ 3 pillars of Observability: Metrics, Logs, Traces.

## Thành viên & Phân công

| Role | Nhiệm vụ | Trạng thái |
|---|---|---|
| Người 1 | Hạ tầng & EKS — deploy lên AWS | 🔲 Chưa làm |
| Người 2 | Observability Stack — Prometheus, Grafana, Loki, Jaeger | ✅ Hoàn thành |
| Người 3 | SRE & Chaos Engineering — SLI/SLO, AlertManager, Chaos Test | 🔲 Chưa làm |
| Người 4 | Phục hồi & Tự động hóa — Ansible, Runbook, Postmortem | 🔲 Chưa làm |

---

## Kiến trúc hệ thống
```
┌─────────────────────────────────────────────┐
│              AWS EKS Cluster                │
│                                             │
│  ┌─────────────┐    ┌──────────────────┐   │
│  │ Tiny Service│───▶│   Prometheus     │   │
│  │ :5000       │    │   :9090          │   │
│  └─────────────┘    └──────────────────┘   │
│         │                    │              │
│         ▼                    ▼              │
│  ┌─────────────┐    ┌──────────────────┐   │
│  │    Loki     │    │    Grafana       │   │
│  │    :3100    │    │    :3000         │   │
│  └─────────────┘    └──────────────────┘   │
│         │                    │              │
│         ▼                    ▼              │
│  ┌─────────────┐    ┌──────────────────┐   │
│  │   Promtail  │    │    Jaeger        │   │
│  │             │    │    :16686        │   │
│  └─────────────┘    └──────────────────┘   │
└─────────────────────────────────────────────┘
```

---

## Cấu trúc thư mục
```
sre-project/
├── docker-compose.yml          # Toàn bộ stack: 7 services
├── SLO.md                      # Định nghĩa SLI/SLO chính thức
├── prometheus/
│   ├── prometheus.yml          # Scrape config: 3 targets
│   └── alert.rules.yml         # 2 alerting rules
├── grafana/
│   └── provisioning/
│       └── datasources/
│           ├── prometheus.yml  # Auto-provision Prometheus
│           ├── loki.yml        # Auto-provision Loki
│           └── jaeger.yml      # Auto-provision Jaeger
├── promtail/
│   └── promtail.yml            # Docker service discovery
└── tiny-service/
    ├── app.py                  # Flask app với Prometheus + OpenTelemetry
    ├── requirements.txt        # Python dependencies
    └── Dockerfile              # Python 3.11-slim
```

---

## Hướng dẫn chạy local (cho tất cả thành viên)

### Yêu cầu

- Ubuntu 22.04 (hoặc WSL2)
- Docker Engine đã cài
- Git

### Bước 1 — Clone repo
```bash
git clone git@github.com:VoTrungKien-23520809/sre-project.git
cd sre-project
```

### Bước 2 — Khởi động toàn bộ stack
```bash
docker compose up -d --build
docker compose ps
```

Kiểm tra 7 container đều **Up**:
```
grafana, loki, node-exporter, prometheus, promtail, tiny-service, jaeger
```

### Bước 3 — Truy cập các service

| Service | URL | Login |
|---|---|---|
| Grafana Dashboard | http://localhost:3000 | admin / admin123 |
| Prometheus UI | http://localhost:9090 | không cần |
| Jaeger UI | http://localhost:16686 | không cần |
| Loki (API) | http://localhost:3100 | không cần |
| Tiny Service | http://localhost:5000 | không cần |

### Bước 4 — Sinh traffic để test
```bash
for i in $(seq 1 50); do
  curl -s http://localhost:5000/api/data > /dev/null
  curl -s http://localhost:5000/api/error > /dev/null
  sleep 0.3
done
```

---

## Tiny Service — API Endpoints

| Endpoint | Mô tả | Dùng để test |
|---|---|---|
| `GET /` | Service info | Health check cơ bản |
| `GET /health` | Health check | Kubernetes liveness probe |
| `GET /api/data` | Trả data, latency 10-300ms ngẫu nhiên | Test latency SLI |
| `GET /api/slow` | Trả data, latency 500ms-2s | Test P99 latency alert |
| `GET /api/error` | Lỗi 500 với xác suất 50% | Test error rate SLI |
| `GET /metrics` | Prometheus metrics endpoint | Scrape target |

---

## SLI / SLO (xem chi tiết trong SLO.md)

| Chỉ số | Định nghĩa | Ngưỡng SLO |
|---|---|---|
| SLI 1 — Availability | Tỉ lệ request thành công (2xx) | ≥ 99.5% / 30 ngày |
| SLI 2 — Latency P99 | 99th percentile response time | ≤ 500ms / 30 ngày |

**Error Budget**: 216 phút downtime được phép mỗi tháng.

---

## Alerting Rules

| Alert | Điều kiện | Severity |
|---|---|---|
| HighErrorRate | Error rate > 20% trong 1 phút | Critical |
| HighLatencyP99 | P99 latency > 1s trong 1 phút | Warning |

Kiểm tra alerts tại: http://localhost:9090/alerts

---

## Hướng dẫn cho từng thành viên

### Người 1 — Hạ tầng & EKS

Clone repo về, đọc `docker-compose.yml` để hiểu cấu trúc service. Nhiệm vụ là deploy stack này lên AWS EKS thay vì chạy local bằng Docker Compose. Xem thêm tài liệu: https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html

Các bước cần làm:
1. Tạo EKS cluster bằng `eksctl`
2. Chuyển đổi `docker-compose.yml` sang Kubernetes manifests (Deployment, Service, ConfigMap)
3. Cấu hình Ingress để truy cập từ ngoài

### Người 3 — SRE & Chaos Engineering

Stack đã có sẵn alert rules và SLO definition. Nhiệm vụ là:
1. Cấu hình AlertManager gửi thông báo về Discord khi alert firing
2. Viết chaos script kill pod và CPU stress
3. Ghi nhận kết quả từ Grafana + Jaeger khi chaos xảy ra

Cấu hình AlertManager Discord:
```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m

route:
  receiver: discord

receivers:
  - name: discord
    discord_configs:
      - webhook_url: '<DISCORD_WEBHOOK_URL>'
        title: '{{ .CommonAnnotations.summary }}'
        message: '{{ .CommonAnnotations.description }}'
```

Cách lấy Discord Webhook URL:
1. Vào Discord channel muốn nhận alert
2. Settings → Integrations → Webhooks → New Webhook
3. Copy Webhook URL dán vào config trên

### Người 4 — Phục hồi & Tự động hóa

Dựa trên kết quả chaos test của Người 3 để viết:
1. Ansible Playbook tự động restart pod khi nhận alert
2. On-call Runbook: nếu `HighErrorRate` firing → làm gì
3. Postmortem template cho 1 sự cố thật

---

## Grafana Dashboards đã import

| Dashboard | ID | Mô tả |
|---|---|---|
| Node Exporter Full | 1860 | CPU, RAM, Disk, Network của host |

Import thêm dashboard: Grafana → Dashboards → New → Import → nhập ID

---

## Troubleshooting thường gặp

**Container không start:**
```bash
docker compose logs <tên-container>
```

**Prometheus không scrape được tiny-service:**
```bash
# Kiểm tra target status
curl http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health
```

**Loki không nhận logs:**
```bash
curl http://localhost:3100/loki/api/v1/label/container/values | python3 -m json.tool
```

**Rebuild tiny-service sau khi sửa code:**
```bash
docker compose build --no-cache tiny-service
docker compose up -d tiny-service
```