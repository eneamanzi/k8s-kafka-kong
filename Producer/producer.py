from flask import Flask, request, jsonify
from kafka import KafkaProducer
import json, os, uuid
from datetime import datetime

app = Flask(__name__)

# --- CONFIGURAZIONE AMBIENTE (KUBERNETES) ---
# Le seguenti variabili vengono iniettate nel container dal Deployment Kubernetes
# tramite ConfigMap (endpoint) e Secrets (credenziali sensibili).
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")                  # Indirizzo del broker Kafka
SASL_USERNAME = os.getenv("SASL_USERNAME")                      # Utente SCRAM-SHA-512
SASL_PASSWORD = os.getenv("SASL_PASSWORD")                      # Password decifrata dal Secret K8s
KAFKA_CA = os.getenv("KAFKA_CA", "/etc/ssl/certs/kafka/ca.crt") # Certificato CA montato via Volume

# --- DEFINIZIONE TOPIC ---
# Separazione logica dei canali per QoS differenziato
TOPIC_TELEMETRY = "sensor-telemetry"    # Alta frequenza, compressione LZ4
TOPIC_ALERTS = "sensor-alerts"          # Bassa frequenza, alta durabilità

# --- INIZIALIZZAZIONE KAFKA PRODUCER ---
# Configurazione sicura per ambiente di produzione (TLS + Auth).
# La connessione è persistente e thread-safe.
producer = KafkaProducer(
    bootstrap_servers=KAFKA_BOOTSTRAP,
    security_protocol="SASL_SSL",                       #SASL_SSL indica Auth (SASL) su canale cifrato (SSL/TLS)
    sasl_mechanism="SCRAM-SHA-512",                     #SCRAM-SHA-512 è più sicuro di PLAIN (evita invio pw in chiaro se non c'è TLS)
    sasl_plain_username=SASL_USERNAME,
    sasl_plain_password=SASL_PASSWORD,
    ssl_cafile=KAFKA_CA,                                #Percorso della CA per validare il certificato del server Kafka
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
    """
    Costruisce il payload standardizzato e lo invia a Kafka.
    Implementa il pattern 'Enriched Event': aggiunge ID e Timestamp all'edge.
    """
    event = {
        "event_id": str(uuid.uuid4()),                  #UUID univoco per idempotenza lato DB
        "type": event_type,
        "timestamp": datetime.utcnow().isoformat(),     #Timestamp alla ricezione (Ingestion Time)
        **payload                                       #Unpacking dei dati originali del sensore
    }

    # Invio asincrono al buffer locale del producer.
    # NOTA: .send() non è bloccante, ma .flush() forza l'invio immediato (utile per bassa latenza a discapito del throughput).
    producer.send(topic, value=event)
    producer.flush()
    
    if event_type in event_count:
        event_count[event_type] += 1
        
    # Logging su stdout nel pod K8s
    print(f"[PRODUCER] {event_type} -> {topic}: {event}", flush=True) 
    return event


# 1. Device Boot (Telemetry Topic)
# Registra l'accensione di un dispositivo.
@app.route("/event/boot", methods=["POST"])
def device_boot():
    data = request.json or {}

    #Validazione input: 'device_id' e 'zone_id' sono obbligatori per localizzare il sensore
    required = ["device_id", "zone_id"]             
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    #Instradamento: Usa TOPIC_TELEMETRY (compressione LZ4) perché è un evento di routine ad alto volume.
    event = produce_event(TOPIC_TELEMETRY, "boot", {
        "device_id": data["device_id"],
        "zone_id": data["zone_id"],
        "firmware": data.get("firmware", "unknown")
    })
    return jsonify({"status": "boot_recorded", "event": event}), 200

# 2. Telemetry Data (Telemetry Topic)
# Endpoint per inviare dati ambientali.
# Rappresenta il carico maggiore del sistema (Write-Intensive).
@app.route("/event/telemetry", methods=["POST"])
def telemetry():
    data = request.json or {}

    # Validazione stringente: tutti i campi metrici devono essere presenti
    required = ["device_id", "temperature", "humidity", "zone_id"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    # Instradamento: TOPIC_TELEMETRY.
    event = produce_event(TOPIC_TELEMETRY, "telemetry", {
        "device_id": data["device_id"],
        "zone_id": data["zone_id"],
        "temperature": float(data["temperature"]),
        "humidity": float(data["humidity"])
    })
    return jsonify({"status": "data_received", "event": event}), 200

# 3. Firmware Update (Telemetry Topic)
# Segnala l'inizio di un aggiornamento OTA (Over-The-Air).
@app.route("/event/firmware_update", methods=["POST"])
def firmware_update():
    data = request.json or {}
    required = ["device_id", "version_to"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    # Instradamento: Anche se meno frequente, usa TOPIC_TELEMETRY per mantenere 
    # l'ordine cronologico con i boot e i dati operativi nello stesso stream logico.
    event = produce_event(TOPIC_TELEMETRY, "firmware_update", {
        "device_id": data["device_id"],
        "update_to": data["version_to"]
    })
    return jsonify({"status": "update_started", "event": event}), 200

# 4. Critical Alert (Alerts Topic)
# Gestisce guasti e anomalie critiche (es. surriscaldamento).
@app.route("/event/alert", methods=["POST"])
def alert():
    data = request.json or {}
    required = ["device_id", "error_code", "severity"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing fields: {required}"}), 400

    # Instradamento: TOPIC_ALERTS.
    # Separa il "segnale" (allarmi) dal "rumore" (telemetria).
    event = produce_event(TOPIC_ALERTS, "alert", {
        "device_id": data["device_id"],
        "error_code": data["error_code"],
        "severity": data["severity"]
    })
    return jsonify({"status": "alert_logged", "event": event}), 200

# 5. Internal Metrics (Observability)
# Endpoint leggero per monitoraggio: espone i contatori in-memory degli eventi processati dall'avvio del pod.
@app.route("/metrics", methods=["GET"])
def metrics():
    total = sum(event_count.values())
    return jsonify({"iot_events_sent": total, "breakdown": event_count}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)