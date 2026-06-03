import json
import logging
import os
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(title="simple-time-service")

Instrumentator().instrument(app).expose(app, include_in_schema=False)


class JSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        span = trace.get_current_span()
        ctx = span.get_span_context()
        log_record = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if ctx.is_valid:
            log_record["trace_id"] = format(ctx.trace_id, "032x")
            log_record["span_id"] = format(ctx.span_id, "016x")
        return json.dumps(log_record)


def configure_logging() -> logging.Logger:
    handler = logging.StreamHandler()
    handler.setFormatter(JSONFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    logger = logging.getLogger("simple-time-service")
    logger.setLevel(logging.INFO)
    return logger


def configure_tracing() -> None:
    service_name = os.environ.get("OTEL_SERVICE_NAME", "simple-time-service")
    provider = TracerProvider(resource=Resource.create({"service.name": service_name}))
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if endpoint:
        provider.add_span_processor(
            BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces"))
        )
    trace.set_tracer_provider(provider)


configure_tracing()
logger = configure_logging()
FastAPIInstrumentor.instrument_app(app, excluded_urls="health,metrics")


def get_client_ip(request: Request) -> str:
    x_forwarded_for = request.headers.get("x-forwarded-for", "")
    if x_forwarded_for:
        return x_forwarded_for.split(",")[0].strip()

    x_real_ip = request.headers.get("x-real-ip", "")
    if x_real_ip:
        return x_real_ip.strip()

    if request.client and request.client.host:
        return request.client.host

    return "unknown"


@app.middleware("http")
async def log_requests(request: Request, call_next):
    client_ip = get_client_ip(request)
    logger.info(
        "Incoming request: method=%s path=%s remote_addr=%s user_agent=%s",
        request.method,
        request.url.path,
        client_ip,
        request.headers.get("user-agent", "unknown"),
    )

    response = await call_next(request)

    logger.info(
        "Request completed: method=%s path=%s status_code=%s remote_addr=%s",
        request.method,
        request.url.path,
        response.status_code,
        client_ip,
    )
    return response


@app.get("/")
async def get_service_metadata(request: Request):
    response = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ip": get_client_ip(request),
    }

    logger.info("Root endpoint served successfully for ip=%s", response["ip"])
    return JSONResponse(content=response, status_code=200)


@app.get("/health")
async def health():
    logger.info("Health check successful")
    return JSONResponse(content={"status": "ok"}, status_code=200)
