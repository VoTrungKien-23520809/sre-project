# Quang - ghi chú merge cho phần Người 3 (SRE & Chaos Engineering)

## Mục tiêu của nhánh này
Nhánh `feat/person3-sre-alert-chaos` bổ sung phần việc của Người 3:
- cấu hình Alertmanager gửi cảnh báo về Discord
- bổ sung chaos scripts để test local bằng Docker Compose
- theo dõi kết quả bằng Prometheus / Alertmanager / Grafana / Jaeger
- bổ sung cơ chế recover sau chaos test

## Những thay đổi chính
Các file/thư mục liên quan trong nhánh này:

- `.gitignore`
- `docker-compose.yml`
- `prometheus/prometheus.yml`
- `prometheus/alert.rules.yml`
- `tiny-service/app.py`
- `alertmanager/`
- `chaos/`

## Ý nghĩa từng phần
### 1. Alertmanager + Discord
- thêm cấu hình Alertmanager để gửi alert sang Discord qua webhook
- webhook URL không hardcode trực tiếp trong file cấu hình
- webhook được đặt trong file secret riêng để dễ thay thế theo môi trường

### 2. Prometheus
- cấu hình scrape cho `tiny-service`, `prometheus`, `node-exporter`
- bổ sung alert rules để phục vụ chaos test local:
  - `TinyServiceDown`
  - `HighErrorRate`
  - `HighLatencyP99`

### 3. tiny-service
- dùng để mô phỏng các tình huống chaos / observability
- các endpoint đang được dùng để test:
  - `/`
  - `/health`
  - `/api/error`
  - `/api/slow`
  - `/metrics`

### 4. Chaos scripts
Thư mục `chaos/` chứa các script phục vụ test local:
- `01-kill-service.sh`: kill service để kích alert down
- `02-error-rate.sh`: tạo error traffic để kích alert error rate
- `03-latency-load.sh`: tạo slow traffic để kích alert latency
- `04-cpu-stress.sh`: tạo CPU load để quan sát hệ thống
- `05-recover.sh`: kiểm tra hệ thống quay về trạng thái sạch
- `common.sh`: hàm dùng chung
- `README-chaos.md`: hướng dẫn chạy

## Kết quả đã kiểm chứng
### 1. Kill service
- `tiny-service` bị kill thành công
- alert `TinyServiceDown` đi qua các trạng thái `absent -> pending -> firing`
- recover thành công

### 2. Error rate
- traffic vào `/api/error` đã kích hoạt được `HighErrorRate`
- recover thành công

### 3. Latency
- traffic vào `/api/slow` đã kích hoạt được `HighLatencyP99`
- app vẫn sống, service vẫn up
- lưu ý: sau khi dừng load, latency alert có thể clear chậm hơn do dùng cửa sổ thống kê 5 phút và `for: 2m`
- khi recover sau latency test có thể cần tăng thời gian chờ, ví dụ:
  ```bash
  MAX_WAIT_SECONDS=420 ./chaos/05-recover.sh
  ```

### 4. CPU stress
- CPU stress đã chạy thành công
- theo dõi bằng Grafana và Jaeger
- mục tiêu của test này là quan sát tác động lên tài nguyên và response time
- hiện chưa cấu hình CPU-specific alert rule, nên test này không dùng để xác nhận alert firing

## Cách verify nhanh sau khi merge
### 1. Cấu hình Discord webhook
Xem file:
- `alertmanager/DISCORD_WEBHOOK_SETUP.md`

### 2. Khởi động lại stack
```bash
docker compose up -d --build
```

### 3. Test nhanh các kịch bản
```bash
./chaos/01-kill-service.sh
./chaos/05-recover.sh

./chaos/02-error-rate.sh
./chaos/05-recover.sh

./chaos/03-latency-load.sh
MAX_WAIT_SECONDS=420 ./chaos/05-recover.sh

CPU_WORKERS=$(nproc) CPU_DURATION=120 CHECK_INTERVAL=5 ./chaos/04-cpu-stress.sh
./chaos/05-recover.sh
```

## Công cụ quan sát
- Prometheus: metrics + alert evaluation
- Alertmanager: routing alert sang Discord
- Grafana: theo dõi CPU, service up, latency
- Jaeger: trace của `tiny-service`

## Ghi chú khi merge
Nên merge các file phục vụ tính năng chính:
- `.gitignore`
- `docker-compose.yml`
- `prometheus/`
- `alertmanager/`
- `chaos/`
- `tiny-service/app.py`

