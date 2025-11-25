from kafka import KafkaConsumer
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure, OperationFailure
from datetime import datetime
import json, os, time

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

# Inizializzazione MongoDB con retry logic
def init_mongodb(max_retries=5, retry_delay=5):
    """Inizializza connessione MongoDB con retry automatico"""
    for attempt in range(1, max_retries + 1):
        try:
            client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
            client.admin.command('ping')
            print(f"[✓] Connesso a MongoDB ({MONGO_HOST}:{MONGO_PORT})", flush=True)
            return client[MONGO_DATABASE].sensor_data
        except ConnectionFailure as e:
            print(f"[WARN] Tentativo {attempt}/{max_retries} fallito: {e}", flush=True)
            if attempt < max_retries:
                time.sleep(retry_delay)
            else:
                print("[ERROR] MongoDB non raggiungibile. Consumer termina.", flush=True)
                raise

collection = init_mongodb()

# Funzione helper per convertire la data
def fix_timestamp(event):
    if "timestamp" in event and isinstance(event["timestamp"], str):
        try:
            event["timestamp"] = datetime.fromisoformat(event["timestamp"])
        except ValueError:
            print(f"[WARN] Formato data non valido: {event['timestamp']}", flush=True)
    return event

# Funzione helper per inserimento sicuro
def safe_insert(event, event_description):
    """Inserisce evento in MongoDB con gestione errori"""
    event["_ingest_ts"] = datetime.utcnow()
    try:
        collection.insert_one(event)
        print(f"[✓] {event_description}", flush=True)
        return True
    except OperationFailure as e:
        print(f"[ERROR] Inserimento fallito ({event_description}): {e}", flush=True)
        return False
    except Exception as e:
        print(f"[ERROR] Errore inatteso ({event_description}): {e}", flush=True)
        return False

def handle_boot(event):
    event = fix_timestamp(event)
    desc = f"[BOOT] Device {event.get('device_id')} attivo in zona {event.get('zone_id')}"
    safe_insert(event, desc)

def handle_telemetry(event):
    event = fix_timestamp(event)
    desc = f"[TELEMETRY] Device {event.get('device_id')} -> Temp: {event.get('temperature')}°C, Hum: {event.get('humidity')}%"
    safe_insert(event, desc)

def handle_firmware_update(event):
    event = fix_timestamp(event)
    desc = f"[UPDATE] Device {event.get('device_id')} aggiornamento a {event.get('update_to')}"
    safe_insert(event, desc)

def handle_alert(event):
    event = fix_timestamp(event)
    desc = f"[ALERT] CRITICO: Device {event.get('device_id')} Code: {event.get('error_code')}"
    safe_insert(event, desc)

def handle_unknown(event):
    event = fix_timestamp(event)
    desc = f"[IGNOTO] Tipo evento non gestito: {event.get('type')}"
    safe_insert(event, desc)

# Inizializzazione Consumer
consumer = KafkaConsumer(
    *TOPICS,
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