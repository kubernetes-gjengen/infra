#!/usr/bin/env python3
"""Poll loop: ARP-scan for never-before-seen Pis, queue them, SSH-probe the
queue, and batch-trigger a full provision_all.yml run once any of them answer SSH.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion

# Only meaningful running outside the container; the Deployment sets these as env vars directly.
try:
    from dotenv import load_dotenv

    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except ImportError:
    pass

PLAYBOOKS_DIR = Path("/app/playbooks")
sys.path.insert(0, str(PLAYBOOKS_DIR / "inventories"))
import discover  # noqa: E402

POLL_INTERVAL = int(os.environ.get("VENIVIDIVICI_POLL_INTERVAL", "30"))
SSH_PROBE_TIMEOUT = int(os.environ.get("VENIVIDIVICI_SSH_PROBE_TIMEOUT", "5"))
REGISTRY_CA_CERT_PATH = os.environ.get("REGISTRY_CA_CERT_PATH", "/secrets/registry-ca.crt")

# Distinct names from the node-side MQTT_HOST/MQTT_PORT - this is the in-cluster ClusterIP, not the NodePort.
MQTT_BROKER = os.environ.get("VENIVIDIVICI_MQTT_BROKER", "mosquitto.default.svc.cluster.local")
MQTT_PORT = int(os.environ.get("VENIVIDIVICI_MQTT_PORT", 1883))
EVENT_TOPIC = os.environ.get("VENIVIDIVICI_EVENT_TOPIC", "event/node-discovered")


def on_connect(_client, _userdata, _connect_flags, reason_code, _properties):
    if reason_code.is_failure:
        print(f"venividivici: MQTT connection failed: {reason_code}", flush=True)
    else:
        print(f"venividivici: connected to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}", flush=True)


def create_mqtt_client() -> mqtt.Client:
    client = mqtt.Client(callback_api_version=CallbackAPIVersion.VERSION2)
    client.on_connect = on_connect
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    client.connect_async(MQTT_BROKER, MQTT_PORT)
    client.loop_start()
    return client


def publish_discovery_event(mqtt_client, ip, mac):
    payload = {"ip": ip, "mac": mac, "timestamp": time.time()}
    mqtt_client.publish(EVENT_TOPIC, json.dumps(payload), qos=1)


def ssh_reachable(ip):
    cmd = [
        "sshpass", "-p", discover.SSH_PASSWORD,
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", f"ConnectTimeout={SSH_PROBE_TIMEOUT}",
        f"{discover.SSH_USER}@{ip}", "true",
    ]
    try:
        return subprocess.run(
            cmd, capture_output=True, timeout=SSH_PROBE_TIMEOUT + 5,
        ).returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def run_provision(ready):
    macs = ", ".join(ready)
    print(f"venividivici: {len(ready)} Pi(s) ready ({macs}), running provision_all.yml", flush=True)
    result = subprocess.run(
        ["ansible-playbook", "provision_all.yml",
         "-e", f"registry_ca_cert_path={REGISTRY_CA_CERT_PATH}"],
        cwd=PLAYBOOKS_DIR,
    )
    if result.returncode != 0:
        print(f"venividivici: provision_all.yml exited {result.returncode}", flush=True)
    else:
        print("venividivici: provision run complete", flush=True)


def main():
    print(
        f"venividivici: watching {discover.SCAN_SUBNET} for new Pis, "
        f"polling every {POLL_INTERVAL}s",
        flush=True,
    )
    mqtt_client = create_mqtt_client()
    pending = {}  # mac -> ip, announced but not yet SSH-reachable / provisioned

    while True:
        known = discover.load_assignments()
        for ip, mac in discover.scan_pis():
            if mac in known or mac in pending:
                continue
            print(f"venividivici: unseen MAC {mac} at {ip}, queued", flush=True)
            pending[mac] = ip
            publish_discovery_event(mqtt_client, ip, mac)

        ready = {mac: ip for mac, ip in pending.items() if ssh_reachable(ip)}
        if ready:
            run_provision(ready)
            for mac in ready:
                del pending[mac]

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
