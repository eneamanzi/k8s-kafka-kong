# from flask import Flask, request, jsonify
# from kafka import KafkaProducer
# import json, os

# KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "uni-it-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092")
# TOPIC = "student-events"

# producer = KafkaProducer(
#     bootstrap_servers=KAFKA_BOOTSTRAP,
#     value_serializer=lambda v: json.dumps(v).encode("utf-8")
# )

# app = Flask(__name__)

# # Contatore eventi per metriche
# event_count = 0

# @app.route("/event", methods=["POST"])
# def handle_event():
#     global event_count
#     data = request.json
#     producer.send(TOPIC, value=data)
#     producer.flush()
#     event_count += 1
#     return jsonify({"status": "ok"}), 200

# @app.route("/metrics", methods=["GET"])
# def metrics():
#     return jsonify({"events_received": event_count}), 200

# if __name__ == "__main__":
#     app.run(host="0.0.0.0", port=5000)


from flask import Flask, request, jsonify
from kafka import KafkaProducer
import json, os, uuid
from datetime import datetime

app = Flask(__name__)

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")
SASL_USERNAME = os.getenv("SASL_USERNAME")
SASL_PASSWORD = os.getenv("SASL_PASSWORD")
KAFKA_CA = os.getenv("KAFKA_CA", "/etc/ssl/certs/kafka/ca.crt")

TOPIC = "student-events"

# Kafka secure producer
producer = KafkaProducer(
    bootstrap_servers=KAFKA_BOOTSTRAP,
    security_protocol="SASL_SSL",
    sasl_mechanism="SCRAM-SHA-512",
    sasl_plain_username=SASL_USERNAME,
    sasl_plain_password=SASL_PASSWORD,
    ssl_cafile=KAFKA_CA,
    value_serializer=lambda v: json.dumps(v).encode("utf-8")
)


# 🔢 Contatori per monitoraggio locale
event_count = {
    "login": 0,
    "quiz_submission": 0,
    "download_materiale": 0,
    "prenotazione_esame": 0
}

def produce_event(event_type: str, payload: dict):
    """Crea un evento completo e lo invia a Kafka"""
    event = {
        "event_id": str(uuid.uuid4()),
        "type": event_type,
        "timestamp": datetime.utcnow().isoformat(),
        **payload
    }
    producer.send(TOPIC, value=event)
    producer.flush()
    event_count[event_type] += 1
    print(f"[PRODUCER] Evento inviato: {event_type} -> {event}", flush=True)
    return event

# 🎓 LOGIN EVENT
@app.route("/event/login", methods=["POST"])
def produce_login():
    data = request.json or {}
    required = ["user_id"]
    if not all(k in data for k in required):
        return jsonify({"error": "Missing required field: user_id"}), 400

    event = produce_event("login", {"user_id": data["user_id"]})
    return jsonify({"status": "ok", "event": event}), 200

# 🧮 QUIZ SUBMISSION
@app.route("/event/quiz", methods=["POST"])
def produce_quiz():
    data = request.json or {}
    required = ["user_id", "quiz_id", "course_id", "score"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing required fields: {required}"}), 400

    event = produce_event("quiz_submission", {
        "user_id": data["user_id"],
        "quiz_id": data["quiz_id"],
        "course_id": data["course_id"],
        "score": data["score"]
    })
    return jsonify({"status": "ok", "event": event}), 200

# 📚 DOWNLOAD MATERIALE
@app.route("/event/download", methods=["POST"])
def produce_download():
    data = request.json or {}
    required = ["user_id", "materiale_id", "course_id"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing required fields: {required}"}), 400

    event = produce_event("download_materiale", {
        "user_id": data["user_id"],
        "materiale_id": data["materiale_id"],
        "course_id": data["course_id"]
    })
    return jsonify({"status": "ok", "event": event}), 200

# 🧾 PRENOTAZIONE ESAME
@app.route("/event/exam", methods=["POST"])
def produce_exam():
    data = request.json or {}
    required = ["user_id", "esame_id", "course_id"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing required fields: {required}"}), 400

    event = produce_event("prenotazione_esame", {
        "user_id": data["user_id"],
        "esame_id": data["esame_id"],
        "course_id": data["course_id"]
    })
    return jsonify({"status": "ok", "event": event}), 200

# 📊 METRICHE LOCALI
@app.route("/metrics", methods=["GET"])
def metrics():
    total = sum(event_count.values())
    return jsonify({"events_sent": total, "breakdown": event_count}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
