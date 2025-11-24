from flask import Flask, request, jsonify
from kafka import KafkaProducer
import json, os, uuid
from datetime import datetime

app = Flask(__name__)

# Configurazione da ConfigMap e Secret
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")
SASL_USERNAME = os.getenv("SASL_USERNAME")
SASL_PASSWORD = os.getenv("SASL_PASSWORD")
KAFKA_CA = os.getenv("KAFKA_CA", "/etc/ssl/certs/kafka/ca.crt")

# Topic Kafka
TOPIC_TELEMETRY = "sensor-telemetry"
TOPIC_ALERTS = "sensor-alerts"

# Kafka Secure Producer
producer = KafkaProducer(
    bootstrap_servers=KAFKA_BOOTSTRAP,
    security_protocol="SASL_SSL",
    sasl_mechanism="SCRAM-SHA-512",
    sasl_plain_username=SASL_USERNAME,
    sasl_plain_password=SASL_PASSWORD,
    ssl_cafile=KAFKA_CA,
    value_serializer=lambda v: json.dumps(v).encode("utf-8")
)

# Contatori Locali
event_count = {
    "boot": 0,
    "telemetry": 0,
    "firmware_update": 0,
    "alert": 0
}

def produce_event(topic: str, event_type: str, payload: dict):
    """Invia evento IoT a Kafka sul topic appropriato"""
    event = {
        "event_id": str(uuid.uuid4()),
        "type": event_type,
        "timestamp": datetime.utcnow().isoformat(),
        **payload
    }
    producer.send(topic, value=event)
    producer.flush()
    
    if event_type in event_count:
        event_count[event_type] += 1
        
    print(f"[PRODUCER] {event_type} -> {topic}: {event}", flush=True)
    return event


# 1. Device Boot (Telemetry Topic)
@app.route("/event/boot", methods=["POST"])
def device_boot():
    data = request.json or {}
    required = ["device_id", "zone_id"] 
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event(TOPIC_TELEMETRY, "boot", {
        "device_id": data["device_id"],
        "zone_id": data["zone_id"],
        "firmware": data.get("firmware", "unknown")
    })
    return jsonify({"status": "boot_recorded", "event": event}), 200

# 2. Telemetry Data (Telemetry Topic)
@app.route("/event/telemetry", methods=["POST"])
def telemetry():
    data = request.json or {}
    required = ["device_id", "temperature", "humidity", "zone_id"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event(TOPIC_TELEMETRY, "telemetry", {
        "device_id": data["device_id"],
        "zone_id": data["zone_id"],
        "temperature": float(data["temperature"]),
        "humidity": float(data["humidity"])
    })
    return jsonify({"status": "data_received", "event": event}), 200

# 3. Firmware Update (Telemetry Topic)
@app.route("/event/firmware_update", methods=["POST"])
def firmware_update():
    data = request.json or {}
    required = ["device_id", "version_to"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event(TOPIC_TELEMETRY, "firmware_update", {
        "device_id": data["device_id"],
        "update_to": data["version_to"]
    })
    return jsonify({"status": "update_started", "event": event}), 200

# 4. Critical Alert (Alerts Topic)
@app.route("/event/alert", methods=["POST"])
def alert():
    data = request.json or {}
    required = ["device_id", "error_code", "severity"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event(TOPIC_ALERTS, "alert", {
        "device_id": data["device_id"],
        "error_code": data["error_code"],
        "severity": data["severity"]
    })
    return jsonify({"status": "alert_logged", "event": event}), 200

# Metriche interne
@app.route("/metrics", methods=["GET"])
def metrics():
    total = sum(event_count.values())
    return jsonify({"iot_events_sent": total, "breakdown": event_count}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)