# Hướng dẫn cấu hình Discord Webhook cho Alertmanager

## Mục tiêu
Cấu hình Alertmanager để gửi cảnh báo sang Discord khi alert firing.

## Bước 1: Tạo Discord Webhook
Trong Discord:
1. Mở channel muốn nhận alert
2. Chọn `Edit Channel`
3. Vào `Integrations`
4. Chọn `Webhooks`
5. Tạo webhook mới
6. Copy Webhook URL

## Bước 2: Lưu webhook URL vào file secret
Tạo hoặc cập nhật file:

```bash
alertmanager/secrets/discord_webhook_url
```

Nội dung file là đúng 1 dòng webhook URL, ví dụ:

```text
https://discord.com/api/webhooks/xxxxx/yyyyy
```

Lưu ý:
- không thêm khoảng trắng thừa
- không thêm dấu nháy
- không commit webhook thật lên git public

## Bước 3: Kiểm tra cấu hình Alertmanager
File cấu hình chính:

```bash
alertmanager/alertmanager.yml
```

Cấu hình receiver Discord sẽ đọc webhook URL từ file secret tương ứng.

## Bước 4: Khởi động lại Alertmanager / stack
```bash
docker compose up -d --build alertmanager
```

Hoặc nếu muốn đồng bộ toàn stack:

```bash
docker compose up -d --build
```

## Bước 5: Kiểm tra Alertmanager đã chạy
```bash
curl -s -o /dev/null -w "alertmanager=%{http_code}\n" http://localhost:9093
```

Kỳ vọng:
```text
alertmanager=200
```

## Bước 6: Kiểm tra thực tế bằng chaos test
Ví dụ test down service:

```bash
./chaos/01-kill-service.sh
```

Kỳ vọng:
- Prometheus alert chuyển sang `firing`
- Alertmanager có alert active
- Discord channel nhận được thông báo

Sau đó recover:

```bash
./chaos/05-recover.sh
```

## Lưu ý
- Nếu Discord chưa nhận alert, kiểm tra lại:
  - webhook URL có đúng không
  - file secret có mount đúng vào container không
  - Alertmanager config có load thành công không
  - Prometheus có thực sự gửi alert sang Alertmanager không
