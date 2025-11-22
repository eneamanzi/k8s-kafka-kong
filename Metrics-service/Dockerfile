FROM python:3.11-slim

WORKDIR /app

COPY metrics_service.py requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

CMD ["python", "metrics_service.py"]
