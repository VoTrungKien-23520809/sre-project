# Chaos Test Guide

## Mục tiêu
Bộ script này dùng để mô phỏng chaos test local cho `tiny-service` đang chạy bằng Docker Compose.

Mục tiêu gồm:
- gây lỗi có kiểm soát
- kiểm tra alert firing
- kiểm tra khả năng recover
- ghi nhận kết quả qua Grafana và Jaeger

## Cấu trúc
- `common.sh`: biến dùng chung + helper functions
- `01-kill-service.sh`: kill service để kiểm tra alert down
- `02-error-rate.sh`: tạo error traffic để kích `HighErrorRate`
- `03-latency-load.sh`: tạo slow traffic để kích `HighLatencyP99`
- `04-cpu-stress.sh`: tạo CPU load để quan sát hệ thống
- `05-recover.sh`: kiểm tra hệ thống quay về trạng thái sạch
- `runs/`: lưu log và snapshot từng lần chạy

## cấu trúc hiện tại
- app URL: `http://localhost:5000`
- Prometheus: `http://localhost:9090`
- Alertmanager: `http://localhost:9093`
- Grafana: `http://localhost:3000`
- Jaeger: `http://localhost:16686`
- service name: `tiny-service`

## Alert rules đang dùng
- `TinyServiceDown`
- `HighErrorRate`
- `HighLatencyP99`

## Endpoint đang dùng để test
- `/`
- `/health`
- `/api/error`
- `/api/slow`
- `/metrics`

## Cấp quyền chạy
```bash
chmod +x chaos/*.sh
```

## Kịch bản 1: Kill service
### Chạy
```bash
./chaos/01-kill-service.sh
./chaos/05-recover.sh
```

### Kỳ vọng
- `tiny-service` bị kill
- alert `TinyServiceDown` chuyển từ `absent -> pending -> firing`
- recover xong thì alert clear

### Theo dõi
- Prometheus
- Alertmanager
- Discord
- Grafana

## Kịch bản 2: Error rate
### Chạy
```bash
./chaos/02-error-rate.sh
./chaos/05-recover.sh
```

### Kỳ vọng
- request vào `/api/error` tăng
- alert `HighErrorRate` firing
- recover thành công

### Theo dõi
- Prometheus
- Alertmanager
- Discord
- Grafana

## Kịch bản 3: Latency load
### Chạy
```bash
./chaos/03-latency-load.sh
MAX_WAIT_SECONDS=420 ./chaos/05-recover.sh
```

### Kỳ vọng
- request vào `/api/slow` làm tăng P99 latency
- alert `HighLatencyP99` firing

### Lưu ý
Latency alert có thể clear chậm hơn các alert khác vì expression dùng cửa sổ `[5m]` và có `for: 2m`.

Vì vậy sau latency test nên dùng thời gian chờ dài hơn khi recover.

### Theo dõi
- Prometheus
- Alertmanager
- Discord
- Grafana
- Jaeger

## Kịch bản 4: CPU stress
### Chạy
```bash
CPU_WORKERS=$(nproc) CPU_DURATION=120 CHECK_INTERVAL=5 ./chaos/04-cpu-stress.sh
./chaos/05-recover.sh
```

### Kỳ vọng
- CPU tăng rõ trên Grafana
- `tiny-service` vẫn `up`
- response time có thể tăng nhẹ
- recover thành công

### Lưu ý
CPU stress hiện dùng để quan sát tác động lên tài nguyên và response time.

Kịch bản này chưa phụ thuộc vào CPU-specific alert rule.

### Theo dõi
- Grafana:
  - Host CPU Usage
  - Tiny Service Up
  - P99 Latency by Endpoint
- Jaeger:
  - service `tiny-service`
  - operation `/` hoặc `/api/slow`

## Gợi ý panel Grafana
### Host CPU Usage
Ví dụ query:
```promql
clamp_min(
  100 * (1 - avg by(instance) (
    rate(node_cpu_seconds_total{job="node-exporter", mode="idle"}[1m])
  )),
  0
)
```

### Tiny Service Up
```promql
up{job="tiny-service"}
```

### P99 Latency by Endpoint
```promql
histogram_quantile(
  0.99,
  sum by (le, endpoint) (
    rate(http_request_duration_seconds_bucket{job="tiny-service"}[5m])
  )
)
```

## Ảnh nên chụp cho báo cáo
### Kill service
- terminal chạy kill script
- Prometheus alert firing
- Alertmanager active alert
- Discord notification
- terminal recover

### Error rate
- terminal chạy error-rate script
- Prometheus alert `HighErrorRate`
- Discord notification
- terminal recover

### Latency load
- terminal chạy latency script
- panel latency tăng trên Grafana
- Prometheus alert `HighLatencyP99`
- Jaeger trace liên quan
- terminal recover

### CPU stress
- terminal chạy CPU stress
- panel CPU tăng trên Grafana
- `Tiny Service Up = 1`
- Jaeger trace của `tiny-service`
- terminal recover

## Artifacts
Mỗi lần chạy sẽ sinh 1 thư mục trong:

```bash
chaos/runs/<timestamp>-<scenario>/
```

Các file bên trong:
- `timeline.log`
- `precheck.txt`
- `docker-compose-ps.txt`
- `targets.json`
- `prometheus-alerts.json`
- `alertmanager-alerts.json`
- file log riêng của từng scenario


