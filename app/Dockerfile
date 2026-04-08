FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN groupadd --system --gid 10001 appgroup && \
    useradd --system --uid 10001 --gid appgroup --create-home --home-dir /home/appuser --shell /usr/sbin/nologin appuser

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt && \
    rm -rf /root/.cache /tmp/* /var/tmp/*

COPY src/ ./src/

RUN chown -R appuser:appgroup /app && \
    chmod -R 755 /app

USER 10001:10001

EXPOSE 8080

CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]