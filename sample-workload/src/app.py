import logging
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="simple-time-service")


def configure_logging() -> logging.Logger:
    """
    Configure and return the application logger.

    Logs are written to stdout.
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    logger = logging.getLogger("simple-time-service")
    logger.setLevel(logging.INFO)
    return logger


logger = configure_logging()


def get_client_ip(request: Request) -> str:
    """
    Return the originating client IP address from the incoming request.
    """
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
    """
    Log incoming requests and response status codes.
    """
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
    """
    Return the current UTC timestamp and resolved client IP address.
    """
    response = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ip": get_client_ip(request),
    }

    logger.info("Root endpoint served successfully for ip=%s", response["ip"])
    return JSONResponse(content=response, status_code=200)


@app.get("/health")
async def health():
    """
    Return a simple health response.
    """
    logger.info("Health check successful")
    return JSONResponse(content={"status": "ok"}, status_code=200)
