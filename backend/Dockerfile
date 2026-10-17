# Backend Dockerfile
FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && pip uninstall -y setuptools wheel

# Copy application code
COPY . .

# Run as non-root (k8s runAsUser 10001 se match karta hai)
USER 10001

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "4", "--worker-tmp-dir", "/dev/shm", "app:app"]
