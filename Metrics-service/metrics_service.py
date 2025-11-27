from flask import Flask, jsonify
from pymongo import MongoClient
from datetime import datetime, timedelta
import os

app = Flask(__name__)

# --- CONFIGURAZIONE DATABASE (da Env Vars K8s) ---
# Il Metrics Service accede in sola lettura ai dati storicizzati dal Consumer.
MONGO_HOST = os.getenv("MONGO_HOST")
MONGO_PORT = os.getenv("MONGO_PORT")
MONGO_DATABASE = os.getenv("MONGO_DATABASE")
MONGO_USER = os.getenv("MONGO_USER")
MONGO_PASSWORD = os.getenv("MONGO_PASSWORD")
MONGO_AUTH_SOURCE = os.getenv("MONGO_AUTH_SOURCE")

MONGO_URI = f"mongodb://{MONGO_USER}:{MONGO_PASSWORD}@{MONGO_HOST}:{MONGO_PORT}/{MONGO_DATABASE}?authSource={MONGO_AUTH_SOURCE}"

# Inizializzazione Client
client = MongoClient(MONGO_URI)
db = client[MONGO_DATABASE]
collection = db.sensor_data     # Punta alla Time Series Collection creata

# Health Check all'avvio
# Verifica immediata che il DB sia raggiungibile prima di accettare traffico HTTP.
try:
    client.admin.command('ping')
    print("Connected to MongoDB (IoT Network)")
except Exception as e:
    print(f"MongoDB connection error: {e}")

# 1. Totale Avvii (Boot Events)
# Metrica operativa semplice: conta quante volte i dispositivi si sono riavviati.
# Utile per monitorare la stabilità della flotta IoT.
@app.route("/metrics/boots", methods=["GET"])
def total_boots():
    count = collection.count_documents({"type": "boot"})
    return jsonify({"total_device_boots": count})

# 2. Media Temperatura per Zona
# Permette di monitorare le condizioni ambientali medie per ogni area dello stabilimento.
# Esegue una Aggregation Pipeline direttamente su MongoDB.
# Sfrutta gli indici delle Time Series per efficienza.
@app.route("/metrics/temperature/average-by-zone", methods=["GET"])
def avg_temp_per_zone():
    pipeline = [
        # Fase 1: Filtro (considera solo dati di telemetria, ignora boot/alert)
        {"$match": {"type": "telemetry"}},

        # Fase 2: Raggruppamento per 'zone_id'.
        {"$group": {
            "_id": "$zone_id", 
            "avg_temp": {"$avg": "$temperature"},   # Calcolo media temperatura
            "avg_hum": {"$avg": "$humidity"},       # Calcolo media umidità
            "samples": {"$sum": 1}                  # Numero di letture nel campione
        }}
    ]
    # Esecuzione query e conversione cursore -> lista
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

# 3. Security/Safety: Breakdown Allarmi
# Fornisce una panoramica degli incidenti raggruppati per gravità (severity).
# Essenziale per dashboard di monitoraggio critico (es. quanti 'critical' vs 'warning').
@app.route("/metrics/alerts", methods=["GET"])
def critical_alerts():
    pipeline = [
        # Filtra solo gli eventi di tipo 'alert'
        {"$match": {"type": "alert"}},
        # Raggruppa per livello di gravità (es. HIGH, MEDIUM, LOW) e conta le occorrenze
        {"$group": {"_id": "$severity", "count": {"$sum": 1}}}
    ]
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

# 4. Trend Attività (Ultimi 7 gg)
# Analisi temporale del volume di dati ingerito.
# Utilizza il campo '_ingest_ts' aggiunto dal Consumer per basarsi sul tempo di arrivo effettivo.
@app.route("/metrics/activity/last7days", methods=["GET"])
def activity_trend():
    # Calcola il timestamp di cut-off (7 giorni fa)
    since = datetime.utcnow() - timedelta(days=7)
    pipeline = [
        # Fase 1: Filtro temporale ($match).
        # MongoDB sfrutta l'efficienza delle Time Series collection per filtrare rapidamente range temporali.
        {"$match": {"_ingest_ts": {"$gte": since}}},

        # Fase 2: Raggruppamento temporale (Time Bucketing).
        # Converte il timestamp in stringa data (YYYY-MM-DD) troncando l'orario per raggruppare tutti gli eventi dello stesso giorno in un unico bucket.
        {"$group": {
            "_id": {"$dateToString": {"format": "%Y-%m-%d", "date": "$_ingest_ts"}}, 
            "events_count": {"$sum": 1} # Contatore incrementale per il bucket giornaliero
        }},
        # Fase 3: Ordinamento cronologico crescente (dal giorno più vecchio al più recente)
        {"$sort": {"_id": 1}}
    ]
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

# 5. Stato Aggiornamenti Firmware
# Monitora la distribuzione delle versioni firmware installate o in aggiornamento.
# Utile per verificare il successo di una campagna di aggiornamento massiva (Rollout).
@app.route("/metrics/firmware", methods=["GET"])
def firmware_stats():
    pipeline = [
        # Seleziona solo gli eventi di aggiornamento firmware
        {"$match": {"type": "firmware_update"}},
        #Conta quanti dispositivi stanno passando a una specifica versione ('update_to')
        {"$group": {"_id": "$update_to", "count": {"$sum": 1}}}
    ]
    result = list(collection.aggregate(pipeline))
    return jsonify(result)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)