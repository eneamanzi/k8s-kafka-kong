from kafka import KafkaConsumer
from pymongo import MongoClient
from pymongo.errors import ConnectionFailure, OperationFailure
from datetime import datetime
import json, os, time

# --- CONFIGURAZIONE KAFKA (da Env Vars K8s) ---
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")  # Indirizzo broker
SASL_USERNAME = os.getenv("SASL_USERNAME")      # Utente Consumer
SASL_PASSWORD = os.getenv("SASL_PASSWORD")      # Password da Secret
KAFKA_CA = "/etc/ssl/certs/kafka/ca.crt"        #Path standard del volume montato in K8s

# Lista dei topic da sottoscrivere.
# Il consumer leggerà sia dati ad alta frequenza (telemetry) che allarmi (alerts)
TOPICS = ["sensor-telemetry", "sensor-alerts"]

# --- CONFIGURAZIONE MONGODB (da Env Vars K8s) ---
# Separazione tra parametri infrastrutturali (ConfigMap) e credenziali (Secret)
MONGO_HOST = os.getenv("MONGO_HOST")
MONGO_PORT = os.getenv("MONGO_PORT")
MONGO_DATABASE = os.getenv("MONGO_DATABASE")        #(iot_network)
MONGO_USER = os.getenv("MONGO_USER")
MONGO_PASSWORD = os.getenv("MONGO_PASSWORD")
MONGO_AUTH_SOURCE = os.getenv("MONGO_AUTH_SOURCE")  # DB di autenticazione (iot_network)

# Costruzione Connection String standard per MongoDB
MONGO_URI = f"mongodb://{MONGO_USER}:{MONGO_PASSWORD}@{MONGO_HOST}:{MONGO_PORT}/{MONGO_DATABASE}?authSource={MONGO_AUTH_SOURCE}"

# --- INIZIALIZZAZIONE DB (Pattern: Wait-For-Service) ---
def init_mongodb(max_retries=5, retry_delay=5):
    """
    Tenta la connessione a MongoDB con backoff.
    Essenziale in Kubernetes dove l'ordine di avvio dei pod non è garantito.
    """
    for attempt in range(1, max_retries + 1):
        try:
            # serverSelectionTimeoutMS=5000 fallisce veloce se il server non risponde
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
                raise   # Il pod andrà in CrashLoopBackOff, segnalando il problema a K8s

# Variabile globale per accedere alla collection
collection = init_mongodb()

# --- HELPER FUNCTIONS ---

def fix_timestamp(event):
    """
    Converte la stringa ISO 8601 ricevuta da JSON in un oggetto datetime Python nativo.
    Necessario perché MongoDB Time Series richiede il tipo BSON Date per indicizzare correttamente il tempo.
    """
    if "timestamp" in event and isinstance(event["timestamp"], str):
        try:
            event["timestamp"] = datetime.fromisoformat(event["timestamp"])
        except ValueError:
            print(f"[WARN] Formato data non valido: {event['timestamp']}", flush=True)
    return event

# Funzione helper per inserimento sicuro
def safe_insert(event, event_description):
    """
    Esegue l'inserimento nel DB gestendo eventuali eccezioni.
    """
    # Aggiunge timestamp di ingestione (utile per calcolare latenza end-to-end: _ingest_ts - timestamp)
    event["_ingest_ts"] = datetime.utcnow()
    try:
        collection.insert_one(event)
        print(f"[✓] {event_description}", flush=True)
        return True
    except OperationFailure as e:
        # Errori lato server Mongo (es. permessi, disco pieno)
        print(f"[ERROR] Inserimento fallito ({event_description}): {e}", flush=True)
        return False
    except Exception as e:
        # Errori generici (es. network disconnesso durante l'insert)
        print(f"[ERROR] Errore inatteso ({event_description}): {e}", flush=True)
        return False

# --- EVENT HANDLERS ---
# Ogni funzione gestisce una tipologia specifica di messaggio Kafka.
# Eseguono la normalizzazione (es. timestamp) e invocano la persistenza.

def handle_boot(event):
    event = fix_timestamp(event)
    desc = f"[BOOT] Device {event.get('device_id')} attivo in zona {event.get('zone_id')}"
    return safe_insert(event, desc)

def handle_telemetry(event):
    event = fix_timestamp(event)
    desc = f"[TELEMETRY] Device {event.get('device_id')} -> Temp: {event.get('temperature')}°C, Hum: {event.get('humidity')}%"
    return safe_insert(event, desc)

def handle_firmware_update(event):
    event = fix_timestamp(event)
    desc = f"[UPDATE] Device {event.get('device_id')} aggiornamento a {event.get('update_to')}"
    return safe_insert(event, desc)

def handle_alert(event):
    event = fix_timestamp(event)
    desc = f"[ALERT] CRITICO: Device {event.get('device_id')} Code: {event.get('error_code')}"
    return safe_insert(event, desc)

def handle_unknown(event):
    event = fix_timestamp(event)
    desc = f"[IGNOTO] Tipo evento non gestito: {event.get('type')}"
    return safe_insert(event, desc)

# --- CONFIGURAZIONE KAFKA CONSUMER ---
consumer = KafkaConsumer(
    *TOPICS,                            # Sottoscrizione multipla (telemetry + alerts)
    bootstrap_servers=KAFKA_BOOTSTRAP,

    # Configurazione Sicurezza (deve corrispondere al Producer e al Broker)
    security_protocol="SASL_SSL",
    sasl_mechanism="SCRAM-SHA-512",
    sasl_plain_username=SASL_USERNAME,
    sasl_plain_password=SASL_PASSWORD,
    ssl_cafile=KAFKA_CA,

    # Comportamento del Consumer
    # 'earliest': Se non c'è offset committato, parte dall'inizio (Zero Data Loss all'avvio)
    auto_offset_reset='earliest',

    # 'group_id': Fondamentale per la SCALABILITA ORIZZONTALE. 
    # Se avviamo più repliche di questo pod, Kafka bilancerà le partizioni tra loro.
    group_id='iot-consumer-group',

    value_deserializer=lambda v: json.loads(v.decode('utf-8'))
)

print(f"IoT Consumer avviato. In ascolto su: {TOPICS}", flush=True)

# --- MAIN PROCESSING LOOP ---
# Ciclo infinito: il consumer attende nuovi messaggi dai broker.
for message in consumer:
    event = message.value
    
    # Dispatching basato sul tipo di evento
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