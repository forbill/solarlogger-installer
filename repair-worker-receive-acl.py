#!/usr/bin/env python3
"""Repair receive ACL on an already installed SolarLogger Mosquitto DynSec role.

Reads locally stored administrator credentials; never prints credentials.
Safe to rerun: ACL repair is idempotent (duplicate ACL response is treated as success).
"""
import json
import queue
import secrets
import threading
from pathlib import Path

import paho.mqtt.client as mqtt

secrets_path = Path("/root/solarlogger-mqtt-credentials.env")
creds = dict(line.split("=", 1) for line in secrets_path.read_text().splitlines() if "=" in line)
client = mqtt.Client(
    mqtt.CallbackAPIVersion.VERSION1,
    client_id="solarlogger-acl-fix-" + secrets.token_hex(5),
    protocol=mqtt.MQTTv311,
)
client.username_pw_set(creds["SOLARLOGGER_BROKER_ADMIN_USERNAME"], creds["SOLARLOGGER_BROKER_ADMIN_PASSWORD"])
connected = threading.Event()
subscribed = threading.Event()
responses = queue.Queue()

def on_connect(_, __, ___, code):
    if code == 0:
        connected.set()

def on_subscribe(_, __, ___, granted_qos):
    if granted_qos and granted_qos[0] == 1:
        subscribed.set()

def on_message(_, __, message):
    responses.put(json.loads(message.payload.decode()))

client.on_connect = on_connect
client.on_subscribe = on_subscribe
client.on_message = on_message
client.connect("127.0.0.1", 1883, 30)
client.loop_start()

try:
    if not connected.wait(8):
        raise RuntimeError("Administrator login failed")
    client.subscribe("$CONTROL/dynamic-security/v1/response", qos=1)
    if not subscribed.wait(8):
        raise RuntimeError("Admin response subscription failed")
    for suffix in ("telemetry", "state", "events", "ack"):
        topic = "solarlogger/v1/devices/+/" + suffix
        command = {
            "command": "addRoleACL",
            "rolename": "solarlogger-cloud-worker",
            "acltype": "publishClientReceive",
            "topic": topic,
            "allow": True,
            "priority": 10,
        }
        rc, mid = client.publish("$CONTROL/dynamic-security/v1", json.dumps({"commands": [command]}), qos=1)
        if rc != mqtt.MQTT_ERR_SUCCESS:
            raise RuntimeError("Publish failed for " + suffix)
        try:
            response = responses.get(timeout=8)["responses"][0]
        except queue.Empty as exc:
            raise RuntimeError("Timed out waiting for DynSec response") from exc
        error = response.get("error")
        if response.get("command") != "addRoleACL" or (error and "already" not in str(error).lower()):
            raise RuntimeError("DynSec ACL update failed for " + suffix + ": " + str(error))
        print("PASS receive ACL:", suffix)
finally:
    client.disconnect()
    client.loop_stop()
