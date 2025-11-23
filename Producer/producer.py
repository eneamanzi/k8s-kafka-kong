from flask import Flask, request, jsonify
from kafka import KafkaProducer
import json, os, uuid
from datetime import datetime

app = Flask(__name__)

# Configurazione Kafka
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")
SASL_USERNAME = os.getenv("SASL_USERNAME")
SASL_PASSWORD = os.getenv("SASL_PASSWORD")
KAFKA_CA = os.getenv("KAFKA_CA", "/etc/ssl/certs/kafka/ca.crt")

TOPIC = "sensor-stream"

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

def produce_event(event_type: str, payload: dict):
    """Invia evento IoT a Kafka"""
    event = {
        "event_id": str(uuid.uuid4()),
        "type": event_type,
        "timestamp": datetime.utcnow().isoformat(),
        **payload
    }
    producer.send(TOPIC, value=event)
    producer.flush()
    
    # Aggiorna metriche locali se il tipo è noto
    if event_type in event_count:
        event_count[event_type] += 1
        
    print(f"[PRODUCER-IOT] Evento inviato: {event_type} -> {event}", flush=True)
    return event


# 1. Device Boot
@app.route("/event/boot", methods=["POST"])
def device_boot():
    data = request.json or {}
    # Richiede device_id e zone_id (ex course_id)
    required = ["device_id", "zone_id"] 
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event("boot", {
        "device_id": data["device_id"],
        "zone_id": data["zone_id"]
    })
    return jsonify({"status": "boot_recorded", "event": event}), 200

# 2. Telemetry Data
@app.route("/event/telemetry", methods=["POST"])
def telemetry():
    data = request.json or {}
    # Richiede temperatura e umidità invece di score
    required = ["device_id", "temperature", "humidity", "zone_id"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event("telemetry", {
        "device_id": data["device_id"],
        "zone_id": data["zone_id"],
        "temperature": float(data["temperature"]),
        "humidity": float(data["humidity"])
    })
    return jsonify({"status": "data_received", "event": event}), 200

# 3. Firmware Update
@app.route("/event/firmware_update", methods=["POST"])
def firmware_update():
    data = request.json or {}
    required = ["device_id", "version_to"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event("firmware_update", {
        "device_id": data["device_id"],
        "update_to": data["version_to"]
    })
    return jsonify({"status": "update_started", "event": event}), 200

# 4. Critical Alert
@app.route("/event/alert", methods=["POST"])
def alert():
    data = request.json or {}
    required = ["device_id", "error_code", "severity"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    event = produce_event("alert", {
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