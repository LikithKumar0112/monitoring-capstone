# Pinned slim base — never :latest, so rebuilds are reproducible.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# -u = unbuffered stdout so `docker logs` shows prints immediately.
CMD ["python", "-u", "app.py"]
