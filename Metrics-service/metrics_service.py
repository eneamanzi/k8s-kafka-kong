from flask import Flask, jsonify
from pymongo import MongoClient
from datetime import datetime, timedelta
import os

app = Flask(__name__)

# Configurazione MongoDB da ConfigMap e Secret
MONGO_HOST = os.getenv("MONGO_HOST")
MONGO_PORT = os.getenv("MONGO_PORT")
MONGO_DATABASE = os.getenv("MONGO_DATABASE")
MONGO_USER = os.getenv("MONGO_USER")
MONGO_PASSWORD = os.getenv("MONGO_PASSWORD")
MONGO_AUTH_SOURCE = os.getenv("MONGO_AUTH_SOURCE")

MONGO_URI = f"mongodb://{MONGO_USER}:{MONGO_PASSWORD}@{MONGO_HOST}:{MONGO_PORT}/{MONGO_DATABASE}?authSource={MONGO_AUTH_SOURCE}"

client = MongoClient(MONGO_URI)
db = client[MONGO_DATABASE]
collection = db.sensor_data

# Test di connessione
try:
    client.admin.command('ping')
    print("Connected to MongoDB (IoT Network)")
except Exception as e:
    print(f"MongoDB connection error: {e}")

# 1. Totale Avvii (Boot Events)
@app.route("/metrics/boots", methods=["GET"])
def total_boots():
    count = collection.count_documents({"type": "boot"})
    return jsonify({"total_device_boots": count})

# 2. Media Temperatura per Zona
@app.route("/metrics/temperature/average-by-zone", methods=["GET"])
def avg_temp_per_zone():
    pipeline = [
        {"$match": {"type": "telemetry"}},
        {"$group": {
            "_id": "$zone_id", 
            "avg_temp": {"$avg": "$temperature"},
            "avg_hum": {"$avg": "$humidity"},
            "samples": {"$sum": 1}
        }}
    ]
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

# 3. Conta Allarmi Critici
@app.route("/metrics/alerts", methods=["GET"])
def critical_alerts():
    pipeline = [
        {"$match": {"type": "alert"}},
        {"$group": {"_id": "$severity", "count": {"$sum": 1}}}
    ]
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

# 4. Trend Attività ultimi 7 giorni
@app.route("/metrics/activity/last7days", methods=["GET"])
def activity_trend():
    since = datetime.utcnow() - timedelta(days=7)
    pipeline = [
        {"$match": {"_ingest_ts": {"$gte": since}}},
        {"$group": {
            "_id": {"$dateToString": {"format": "%Y-%m-%d", "date": "$_ingest_ts"}}, 
            "events_count": {"$sum": 1}
        }},
        {"$sort": {"_id": 1}}
    ]
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

# 5. Stato Firmware
@app.route("/metrics/firmware", methods=["GET"])
def firmware_stats():
    pipeline = [
        {"$match": {"type": "firmware_update"}},
        {"$group": {"_id": "$update_to", "count": {"$sum": 1}}}
    ]
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)