from kafka import KafkaConsumer
from pymongo import MongoClient
from datetime import datetime
import json, os

# Configurazione Kafka
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")
SASL_USERNAME = os.getenv("SASL_USERNAME")
SASL_PASSWORD = os.getenv("SASL_PASSWORD")
KAFKA_CA = "/etc/ssl/certs/kafka/ca.crt"

# Topic da consumare
TOPICS = ["sensor-telemetry", "sensor-alerts"]

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

# Funzione helper per convertire la data
def fix_timestamp(event):
    if "timestamp" in event and isinstance(event["timestamp"], str):
        try:
            # Converte la stringa ISO 8601 in oggetto datetime
            event["timestamp"] = datetime.fromisoformat(event["timestamp"])
        except ValueError:
            print(f"[WARN] Formato data non valido: {event['timestamp']}", flush=True)
    return event

def handle_boot(event):
    event = fix_timestamp(event) 
    print(f"[BOOT] Device {event.get('device_id')} attivo in zona {event.get('zone_id')}.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_telemetry(event):
    event = fix_timestamp(event) 
    print(f"[TELEMETRY] Device {event.get('device_id')} -> Temp: {event.get('temperature')}°C, Hum: {event.get('humidity')}%", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_firmware_update(event):
    event = fix_timestamp(event) 
    print(f"[UPDATE] Device {event.get('device_id')} aggiornamento a {event.get('update_to')}.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_alert(event):
    event = fix_timestamp(event) 
    print(f"[ALERT] CRITICO: Device {event.get('device_id')} Code: {event.get('error_code')}", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_unknown(event):
    event = fix_timestamp(event) 
    print(f"[IGNOTO] Tipo evento non gestito: {event.get('type')}", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

# Inizializzazione Consumer
consumer = KafkaConsumer(
    *TOPICS,  # Sottoscrivi a entrambi i topic
    bootstrap_servers=KAFKA_BOOTSTRAP,
    security_protocol="SASL_SSL",
    sasl_mechanism="SCRAM-SHA-512",
    sasl_plain_username=SASL_USERNAME,
    sasl_plain_password=SASL_PASSWORD,
    ssl_cafile=KAFKA_CA,
    auto_offset_reset='earliest',
    group_id='iot-consumer-group',
    value_deserializer=lambda v: json.loads(v.decode('utf-8'))
)

print(f"IoT Consumer avviato. In ascolto su: {TOPICS}", flush=True)

# Loop principale
for message in consumer:
    event = message.value
    
    event_type = event.get("type")
    match event_type:
        case "boot":
            handle_boot(event)
        case "telemetry":
            handle_telemetry(event)
        case "firmware_update":
            handle_firmware_update(event)
        case "alert":
            handle_alert(event)
        case _:
            handle_unknown(event)