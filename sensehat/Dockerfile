FROM python:3.11-slim-bookworm

RUN pip install smbus2 paho-mqtt

COPY collector.py /app/collector.py
WORKDIR /app

CMD ["python", "collector.py"]
