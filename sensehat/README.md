# SenseHAT Data Pipeline

This system reads sensor data from a Raspberry Pi SenseHAT, sends it over a network using MQTT, and displays it live in a browser.

```
worker4 (Pi with SenseHAT)        manager0 (Pi running Kubernetes)        Your browser
──────────────────────────         ────────────────────────────────         ─────────────
collector.py                       Mosquitto (MQTT broker)                  index.html
  reads temperature,         →       receives the data           ←            connects via
  humidity, pressure,                and forwards it                          WebSocket,
  accelerometer, gyroscope,          to any subscriber                        shows a live
  magnetometer                                                                table
  every 5 seconds            →     Nginx (web server)            →
                                     serves index.html
```

---

## Components

### 1. `collector.py` — the sensor reader

This Python program runs inside a Kubernetes pod on `worker4`. It talks directly to the SenseHAT's sensors over the I2C bus (a simple two-wire hardware protocol) and reads six kinds of data every 5 seconds.

It does two things with each reading:
- Appends a line to `/data/readings.jsonl` on disk (a backup log)
- Publishes the reading to the MQTT broker so the frontend can display it immediately

The data is formatted as JSON, for example:
```json
{
  "ts": "2026-06-25T07:52:22+00:00",
  "temperature": 40.0,
  "humidity": 30.27,
  "pressure": 1005.57,
  "accelerometer": {"x": 0.039, "y": -0.139, "z": 0.974},
  "gyroscope": {"x": -0.98, "y": -2.96, "z": -0.41},
  "magnetometer": {"x": 0.507, "y": -0.094, "z": -0.197}
}
```

**Sensors and units:**

| Field | Sensor chip | Unit | Notes |
|---|---|---|---|
| temperature | HTS221 | °C | Reads ~10–15°C high due to CPU heat |
| humidity | HTS221 | % RH | Relative humidity |
| pressure | LPS25H | hPa | Same as millibar; ~1013 at sea level |
| accelerometer | LSM9DS1 | g | 1 g = gravity. Z ≈ 1.0 when Pi is flat |
| gyroscope | LSM9DS1 | °/s | Rotation speed. Small bias (~3 °/s) is normal |
| magnetometer | LSM9DS1 | G (gauss) | Earth's field is ~0.25–0.65 G |

---

### 2. MQTT — the messaging protocol

MQTT is a lightweight publish/subscribe protocol designed for small devices. Instead of devices talking directly to each other, they all talk to a central **broker**:

```
collector.py  →  publishes to topic "sensehat/readings"  →  Mosquitto broker
index.html    ←  subscribes to topic "sensehat/readings" ←  Mosquitto broker
```

Think of a **topic** like a radio channel. Anyone can publish (broadcast) to a topic, and anyone can subscribe (tune in) to receive messages on that topic.

**Why MQTT instead of HTTP?** MQTT is push-based — the browser gets data the instant it arrives, without having to ask for it repeatedly. It is also very lightweight, using minimal bandwidth and CPU.

**Mosquitto** is the broker used here. It runs as a Kubernetes pod on `manager0`. It listens on two ports:
- `1883` — standard MQTT (used by `collector.py`)
- `9001` — MQTT over WebSocket (used by the browser, since browsers cannot open raw TCP connections)

---

### 3. `index.html` — the frontend

A single HTML file served by Nginx. It has no framework and no build step — just plain HTML, CSS, and JavaScript.

When you open it in a browser, it:
1. Connects to the Mosquitto broker via WebSocket (`ws://<manager0-ip>:30901`)
2. Subscribes to the `sensehat/readings` topic
3. Every time a new reading arrives (every 5 seconds), it updates the table

The broker address is read from `window.location.hostname`, so the page automatically connects to the right broker as long as you open it from `manager0`'s IP.

---

### 4. Nginx — the web server

Nginx serves `index.html` as a static file. It is the simplest possible web server setup — no server-side logic, no database. Nginx runs as a Kubernetes pod on `manager0` and is reachable on port `30080`.

---

## How to deploy

**Prerequisites:**
- A running Kubernetes cluster (k3s) with `worker4` labeled `sensehat=true`
- `kubectl` configured with the cluster's kubeconfig
- Docker with `buildx` for ARM64 cross-compilation

### Step 1 — Build and push the frontend image

```bash
cd frontend
docker buildx build --platform linux/arm64 -t sondrejk/sensehat-frontend:latest --push .
```

### Step 2 — Deploy the broker and web server on manager0

```bash
kubectl apply -f frontend/frontend.yml
```

### Step 3 — Build and push the updated collector image (adds MQTT)

```bash
cd sensehat
docker buildx build --platform linux/arm64 -t sondrejk/sensehat-collector:latest --push .
kubectl apply -f sensehat/sensehat-collector.yml
kubectl rollout restart deployment/sensehat-collector
```

### Step 4 — Open the frontend

```
http://<manager0-ip>:30080
```

Replace `<manager0-ip>` with `192.168.3.19` (ethernet) or `192.168.42.1` (batman mesh).

---

## How to verify each component

**Is the MQTT broker running?**
```bash
kubectl get pods -l app=mosquitto
```

**Is the collector publishing data?** (subscribe from a temporary pod)
```bash
kubectl run -it --rm mqtt-test --image=eclipse-mosquitto:2 --restart=Never -- \
  mosquitto_sub -h mosquitto -t "sensehat/readings"
```
You should see a new JSON line every 5 seconds.

**Is the frontend reachable?**
```bash
curl http://<manager0-ip>:30080
```

**Are there errors in the collector?**
```bash
kubectl logs deployment/sensehat-collector
```
