import json
import os
import struct
import threading
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
import smbus2

OUTPUT_FILE = "/data/readings.jsonl"
POLL_INTERVAL = 5.0
I2C_BUS = 1

MQTT_BROKER = os.getenv("MQTT_BROKER", "mosquitto.default.svc.cluster.local")
MQTT_TOPIC = "sensehat/readings"
MQTT_INTERVAL_TOPIC = "sensehat/interval"

_interval_event = threading.Event()


def on_interval_message(client, userdata, message):
    global POLL_INTERVAL
    try:
        POLL_INTERVAL = max(0.1, min(5.0, int(message.payload) / 1000.0))
        _interval_event.set()
    except ValueError:
        pass

HTS221_ADDR = 0x5F
LPS25H_ADDR = 0x5C
LSM_AG_ADDR = 0x6A
LSM_M_ADDR = 0x1C


def read_i16(bus, addr, reg):
    data = bus.read_i2c_block_data(addr, reg | 0x80, 2)
    return struct.unpack("<h", bytes(data))[0]


# HTS221 — temperature + humidity

def hts221_init(bus):
    bus.write_byte_data(HTS221_ADDR, 0x20, 0x85)  # power on, BDU, 1 Hz


def hts221_calibration(bus):
    H0 = bus.read_byte_data(HTS221_ADDR, 0x30) / 2.0
    H1 = bus.read_byte_data(HTS221_ADDR, 0x31) / 2.0
    T0_lsb = bus.read_byte_data(HTS221_ADDR, 0x32)
    T1_lsb = bus.read_byte_data(HTS221_ADDR, 0x33)
    msb = bus.read_byte_data(HTS221_ADDR, 0x35)
    T0 = ((msb & 0x03) << 8 | T0_lsb) / 8.0
    T1 = ((msb & 0x0C) << 6 | T1_lsb) / 8.0
    H0_OUT = read_i16(bus, HTS221_ADDR, 0x36)
    H1_OUT = read_i16(bus, HTS221_ADDR, 0x3A)
    T0_OUT = read_i16(bus, HTS221_ADDR, 0x3C)
    T1_OUT = read_i16(bus, HTS221_ADDR, 0x3E)
    return H0, H1, H0_OUT, H1_OUT, T0, T1, T0_OUT, T1_OUT


def hts221_read(bus, cal):
    H0, H1, H0_OUT, H1_OUT, T0, T1, T0_OUT, T1_OUT = cal
    H_OUT = read_i16(bus, HTS221_ADDR, 0x28)
    T_OUT = read_i16(bus, HTS221_ADDR, 0x2A)
    humidity = H0 + (H1 - H0) * (H_OUT - H0_OUT) / (H1_OUT - H0_OUT)
    temperature = T0 + (T1 - T0) * (T_OUT - T0_OUT) / (T1_OUT - T0_OUT)
    return round(temperature, 2), round(humidity, 2)


# LPS25H — pressure

def lps25h_init(bus):
    bus.write_byte_data(LPS25H_ADDR, 0x20, 0xC4)  # power on, 25 Hz, BDU


def lps25h_read(bus):
    data = bus.read_i2c_block_data(LPS25H_ADDR, 0x28 | 0x80, 3)
    raw = data[2] << 16 | data[1] << 8 | data[0]
    if raw > 0x7FFFFF:
        raw -= 0x1000000
    return round(raw / 4096.0, 2)


# LSM9DS1 — accel + gyro

def lsm_ag_init(bus):
    bus.write_byte_data(LSM_AG_ADDR, 0x10, 0x60)  # gyro 119 Hz, ±245 dps
    bus.write_byte_data(LSM_AG_ADDR, 0x20, 0x60)  # accel 119 Hz, ±2 g


def lsm_ag_read(bus):
    raw = bus.read_i2c_block_data(LSM_AG_ADDR, 0x18 | 0x80, 6)
    gx, gy, gz = struct.unpack("<hhh", bytes(raw))
    raw = bus.read_i2c_block_data(LSM_AG_ADDR, 0x28 | 0x80, 6)
    ax, ay, az = struct.unpack("<hhh", bytes(raw))
    accel = {"x": round(ax * 6.1e-5, 5), "y": round(ay * 6.1e-5, 5), "z": round(az * 6.1e-5, 5)}
    gyro = {"x": round(gx * 8.75e-3, 4), "y": round(gy * 8.75e-3, 4), "z": round(gz * 8.75e-3, 4)}
    return accel, gyro


# LSM9DS1 — magnetometer

def lsm_m_init(bus):
    bus.write_byte_data(LSM_M_ADDR, 0x20, 0x70)  # high perf, 10 Hz
    bus.write_byte_data(LSM_M_ADDR, 0x21, 0x00)  # ±4 gauss
    bus.write_byte_data(LSM_M_ADDR, 0x22, 0x00)  # continuous mode
    bus.write_byte_data(LSM_M_ADDR, 0x23, 0x0C)  # high perf Z


def lsm_m_read(bus):
    raw = bus.read_i2c_block_data(LSM_M_ADDR, 0x28 | 0x80, 6)
    mx, my, mz = struct.unpack("<hhh", bytes(raw))
    return {"x": round(mx * 1.4e-4, 6), "y": round(my * 1.4e-4, 6), "z": round(mz * 1.4e-4, 6)}


def main():
    bus = smbus2.SMBus(I2C_BUS)

    hts221_init(bus)
    cal = hts221_calibration(bus)
    lps25h_init(bus)
    lsm_ag_init(bus)
    lsm_m_init(bus)

    mqttc = mqtt.Client()
    mqttc.message_callback_add(MQTT_INTERVAL_TOPIC, on_interval_message)
    mqttc.connect(MQTT_BROKER, 1883)
    mqttc.subscribe(MQTT_INTERVAL_TOPIC)
    mqttc.loop_start()

    with open(OUTPUT_FILE, "a") as f:
        while True:
            temperature, humidity = hts221_read(bus, cal)
            pressure = lps25h_read(bus)
            accel, gyro = lsm_ag_read(bus)
            mag = lsm_m_read(bus)

            sample = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "temperature": temperature,
                "humidity": humidity,
                "pressure": pressure,
                "accelerometer": accel,
                "gyroscope": gyro,
                "magnetometer": mag,
            }

            payload = json.dumps(sample)
            f.write(payload + "\n")
            f.flush()
            mqttc.publish(MQTT_TOPIC, payload)
            _interval_event.wait(timeout=POLL_INTERVAL)
            _interval_event.clear()


if __name__ == "__main__":
    main()
