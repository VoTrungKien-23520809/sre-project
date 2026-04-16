from flask import Flask, jsonify, Response
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.resources import Resource
import time
import random
import os

# ── OpenTelemetry setup ─────────────────────────────────────────
resource = Resource.create({"service.name": "tiny-service"})
provider = TracerProvider(resource=resource)

jaeger_endpoint = os.environ.get('JAEGER_ENDPOINT', 'http://jaeger:4317')
otlp_exporter = OTLPSpanExporter(endpoint=jaeger_endpoint, insecure=True)

provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

# ── Metrics định nghĩa ──────────────────────────────────────────
REQUEST_COUNT = Counter(
    'http_requests_total',
    'Tổng số HTTP requests',
    ['method', 'endpoint', 'status_code']
)

REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'Thời gian xử lý request (seconds)',
    ['endpoint'],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
)

IN_PROGRESS = Gauge(
    'http_requests_in_progress',
    'Số requests đang xử lý'
)

APP_INFO = Gauge(
    'app_info',
    'Thông tin app',
    ['version', 'service']
)
APP_INFO.labels(version='1.0.0', service='tiny-service').set(1)

# ── Helper đo latency ───────────────────────────────────────────
def track_request(endpoint):
    def decorator(f):
        def wrapper(*args, **kwargs):
            IN_PROGRESS.inc()
            start = time.time()
            status = 200
            try:
                result = f(*args, **kwargs)
                if hasattr(result, 'status_code'):
                    status = result.status_code
                return result
            except Exception as e:
                status = 500
                raise e
            finally:
                duration = time.time() - start
                REQUEST_COUNT.labels(
                    method='GET',
                    endpoint=endpoint,
                    status_code=str(status)
                ).inc()
                REQUEST_LATENCY.labels(endpoint=endpoint).observe(duration)
                IN_PROGRESS.dec()
        wrapper.__name__ = f.__name__
        return wrapper
    return decorator

# ── Endpoints ───────────────────────────────────────────────────
@app.route('/')
@track_request('/')
def home():
    return jsonify({
        'service': 'tiny-service',
        'version': '1.0.0',
        'status': 'running'
    })

@app.route('/health')
@track_request('/health')
def health():
    return jsonify({'status': 'healthy'}), 200

@app.route('/api/data')
@track_request('/api/data')
def get_data():
    with tracer.start_as_current_span("process-data") as span:
        time.sleep(random.uniform(0.01, 0.3))
        span.set_attribute("data.count", 5)  # gắn metadata vào span
        return jsonify({
            'data': [1, 2, 3, 4, 5],
            'message': 'success'
        })

@app.route('/api/slow')
@track_request('/api/slow')
def slow_endpoint():
    # Endpoint chậm để test SLO latency
    time.sleep(random.uniform(0.5, 2.0))
    return jsonify({'message': 'slow response'})

@app.route('/api/error')
@track_request('/api/error')
def error_endpoint():
    # Simulate lỗi 50% để test error rate SLI
    if random.random() < 0.5:
        return jsonify({'error': 'Internal Server Error'}), 500
    return jsonify({'message': 'ok'})

@app.route('/metrics')
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)