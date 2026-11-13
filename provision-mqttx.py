#!/usr/bin/env python3
"""Create a least-privilege SolarLogger MQTTX diagnostics account on an installed broker.

Credentials are generated locally, stored in a root-only file, never printed.
"""
import json
import os
import queue
import secrets
import threading
from pathlib import Path

import paho.mqtt.client as mqtt

target = Path("/root/solarlogger-mqttx-credentials.env")
if target.exists():
    raise SystemExit("MQTTX credentials already exist. Refusing to overwrite; check root-only file.")
creds = dict(line.split("=", 1) for line in Path("/root/solarlogger-mqtt-credentials.env").read_text().splitlines() if "=" in line)
username = "solarlogger-mqttx-" + secrets.token_hex(6)
password = secrets.token_urlsafe(36)
role_name = "solarlogger-mqttx-diagnostics"

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="sl-mqttx-provision-" + secrets.token_hex(5), protocol=mqtt.MQTTv311)
client.username_pw_set(creds["SOLARLOGGER_BROKER_ADMIN_USERNAME"], creds["SOLARLOGGER_BROKER_ADMIN_PASSWORD"])
connected = threading.Event()
subscribed = threading.Event()
responses = queue.Queue()
client.on_connect = lambda c, u, f, rc: connected.set() if rc == 0 else None
client.on_subscribe = lambda c, u, mid, qos: subscribed.set() if qos and qos[0] == 1 else None
client.on_message = lambda c, u, msg: responses.put(json.loads(msg.payload))
client.connect("127.0.0.1", 1883, 30)
client.loop_start()

def send(command):
    rc, mid = client.publish("$CONTROL/dynamic-security/v1", json.dumps({"commands": [command]}), qos=1)
    if rc != mqtt.MQTT_ERR_SUCCESS:
        raise RuntimeError("DynSec command publish failed")
    try:
        response = responses.get(timeout=10)["responses"][0]
    except queue.Empty:
        raise RuntimeError("DynSec response timed out") from None
    if response.get("command") != command["command"] or response.get("error"):
        raise RuntimeError("DynSec rejected " + command["command"] + ": " + str(response.get("error")))

try:
    if not connected.wait(8):
        raise RuntimeError("Broker admin connection failed")
    client.subscribe("$CONTROL/dynamic-security/v1/response", qos=1)
    if not subscribed.wait(8):
        raise RuntimeError("DynSec response subscription failed")
    acls = [
        {"acltype": "subscribeLiteral", "topic": "solarlogger/v1/#", "allow": True, "priority": 10},
        {"acltype": "subscribeLiteral", "topic": "solarlogger/v1/devices/+/telemetry", "allow": True, "priority": 10},
        {"acltype": "publishClientReceive", "topic": "solarlogger/v1/#", "allow": True, "priority": 10},
        {"acltype": "publishClientSend", "topic": "solarlogger/v1/devices/sl-smoke-20261114-01/telemetry", "allow": True, "priority": 10},
    ]
    send({"command": "createRole", "rolename": role_name, "acls": acls})
    send({"command": "createClient", "username": username, "password": password,
          "roles": [{"rolename": role_name, "priority": 10}]})
finally:
    client.disconnect()
    client.loop_stop()

fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as out:
    out.write("SOLARLOGGER_MQTTX_USERNAME=" + username + "\n")
    out.write("SOLARLOGGER_MQTTX_PASSWORD=" + password + "\n")
print("PASS: isolated MQTTX account created.")
print("Permissions: read solarlogger/v1/#; publish only sl-smoke test telemetry.")
print("Read root-only credentials in Termius with: cat /root/solarlogger-mqttx-credentials.env")
