# # from kafka import KafkaConsumer
# # import json, os

# # KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "uni-it-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092")
# # TOPIC = "student-events"

# # consumer = KafkaConsumer(
# #     TOPIC,
# #     bootstrap_servers=KAFKA_BOOTSTRAP,
# #     auto_offset_reset='earliest',  # legge dall'inizio se non ci sono commit
# #     group_id='student-events-group',         # nuovo gruppo, così rilegge tutto
# #     value_deserializer=lambda v: json.loads(v.decode('utf-8'))
# # )

# # print("Consumer avviato, in ascolto su topic:", TOPIC)
# # for message in consumer:
# #     print(f"Evento ricevuto: {message.value}", flush=True)

# from kafka import KafkaConsumer
# import json, os
# from pymongo import MongoClient
# from datetime import datetime

# KAFKA_BOOTSTRAP = os.getenv(
#     "KAFKA_BOOTSTRAP", 
#     "uni-it-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
# )
# TOPIC = "student-events"

# # Connessione MongoDB
# MONGO_URI = os.getenv(
#     "MONGO_URI", 
#     "mongodb://user:password@mongo-mongodb.mongo.svc.cluster.local:27017/student_events"
# )
# client = MongoClient(MONGO_URI)
# db = client.student_events
# collection = db.events

# consumer = KafkaConsumer(
#     TOPIC,
#     bootstrap_servers=KAFKA_BOOTSTRAP,
#     auto_offset_reset='earliest',
#     group_id='db-consumer-group',
#     value_deserializer=lambda v: json.loads(v.decode('utf-8'))
# )

# print("Consumer avviato, in ascolto su topic:", TOPIC)
# for message in consumer:
#     event = message.value
#     # aggiungo timestamp locale per tracciamento ingest
#     event["_ingest_ts"] = datetime.utcnow()
#     collection.insert_one(event)
#     print(f"Evento salvato su DB: {event}", flush=True)

from kafka import KafkaConsumer
from pymongo import MongoClient
from datetime import datetime
import json, os

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP")
SASL_USERNAME = os.getenv("SASL_USERNAME")
SASL_PASSWORD = os.getenv("SASL_PASSWORD")
KAFKA_CA = "/etc/ssl/certs/kafka/ca.crt"

TOPIC = "student-events"

MONGO_URI = os.environ["MONGO_URI"]
client = MongoClient(MONGO_URI)
db = client.student_events
collection = db.events

def handle_login(event):
    print(f"[LOGIN] Utente {event.get('user_id')} ha effettuato l'accesso.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_quiz_submission(event):
    print(f"[QUIZ] Utente {event.get('user_id')} ha inviato quiz {event.get('quiz_id')} con punteggio {event.get('score')}.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_material_download(event):
    print(f"[DOWNLOAD] Utente {event.get('user_id')} ha scaricato materiale {event.get('materiale_id')}.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_exam_booking(event):
    print(f"[ESAME] Utente {event.get('user_id')} ha prenotato esame {event.get('esame_id')}.", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

def handle_unknown(event):
    print(f"[IGNOTO] Tipo evento non riconosciuto: {event.get('type')}", flush=True)
    event["_ingest_ts"] = datetime.utcnow()
    collection.insert_one(event)

consumer = KafkaConsumer(
    TOPIC,
    bootstrap_servers=KAFKA_BOOTSTRAP,
    security_protocol="SASL_SSL",
    sasl_mechanism="SCRAM-SHA-512",
    sasl_plain_username=SASL_USERNAME,
    sasl_plain_password=SASL_PASSWORD,
    ssl_cafile=KAFKA_CA,
    auto_offset_reset='earliest',
    group_id='db-consumer-group',
    value_deserializer=lambda v: json.loads(v.decode('utf-8'))
)


print("✅ Consumer avviato, in ascolto su topic:", TOPIC, flush=True)
for message in consumer:
    event = message.value
    event["_ingest_ts"] = datetime.utcnow()
    
    event_type = event.get("type")
    match event_type:
        case "login":
            handle_login(event)
        case "quiz_submission":
            handle_quiz_submission(event)
        case "download_materiale":
            handle_material_download(event)
        case "prenotazione_esame":
            handle_exam_booking(event)
        case _:
            handle_unknown(event)
