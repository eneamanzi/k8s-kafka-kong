from kafka import KafkaConsumer
from pymongo import MongoClient
from datetime import datetime
import json, os

# Configurazione Kafka
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")
SASL_USERNAME = os.getenv("SASL_USERNAME")
SASL_PASSWORD = os.getenv("SASL_PASSWORD")
KAFKA_CA = "/etc/ssl/certs/kafka/ca.crt"

TOPIC = "sensor-stream"

# Configurazione MongoDB (Il Secret punta già a iot_network, ma esplicitiamo il db)
MONGO_URI = os.environ["MONGO_URI"]
client = MongoClient(MONGO_URI)
db = client.iot_network  
collection = db.sensor_data

def handle_boot(event):
    print(f"[BOOT] Device {event.get('device_id')} attivo in zona {event.get('zone_id')}.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_telemetry(event):
    print(f"[TELEMETRY] Device {event.get('device_id')} -> Temp: {event.get('temperature')}°C, Hum: {event.get('humidity')}%", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_firmware_update(event):
    print(f"[UPDATE] Device {event.get('device_id')} aggiornamento a {event.get('update_to')}.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_alert(event):
    print(f"[ALERT] CRITICO: Device {event.get('device_id')} Code: {event.get('error_code')}", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_unknown(event):
    print(f"[IGNOTO] Tipo evento non gestito: {event.get('type')}", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

# Inizializzazione Consumer
consumer = KafkaConsumer(
    TOPIC,
    bootstrap_servers=KAFKA_BOOTSTRAP,
    security_protocol="SASL_SSL",
    sasl_mechanism="SCRAM-SHA-512",
    sasl_plain_username=SASL_USERNAME,
    sasl_plain_password=SASL_PASSWORD,
    ssl_cafile=KAFKA_CA,
    auto_offset_reset='earliest', # Legge dall'inizio 
    group_id='iot-consumer-group',
    value_deserializer=lambda v: json.loads(v.decode('utf-8'))
)

print(f"IoT Consumer avviato. In ascolto su: {TOPIC}", flush=True)

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