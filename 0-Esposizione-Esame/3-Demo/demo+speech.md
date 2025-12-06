# Demo Speech - Architettura Microservizi Event-Driven
> **Obiettivo:** Validare le proprietà non funzionali (NFP) dell'architettura attraverso scenari di test pratici

- [Setup Iniziale](#setup-iniziale)
  - [Verifica Stato Cluster](#verifica-stato-cluster)
- [TEST BASE: Pipeline Completa](#test-base-pipeline-completa)
  - [SCRITTURA / INVIO DATI](#scrittura--invio-dati)
    - [**Evento 1: Device Boot** (Accensione Sensore)](#evento-1-device-boot-accensione-sensore)
    - [**Evento 2: Telemetry Data** (Dati Ambientali Normali)](#evento-2-telemetry-data-dati-ambientali-normali)
    - [**Evento 3: Critical Alert** (Allarme Critico)](#evento-3-critical-alert-allarme-critico)
    - [**Evento 4: Firmware Update** (Aggiornamento OTA)](#evento-4-firmware-update-aggiornamento-ota)
  - [LETTURA / ANALITICHE Metrics Service](#lettura--analitiche-metrics-service)
    - [Comando 1: Totale Boot Events](#comando-1-totale-boot-events)
    - [Comando 2: Media Temperatura per Zona](#comando-2-media-temperatura-per-zona)
    - [Comando 3: Breakdown Allarmi per Severità](#comando-3-breakdown-allarmi-per-severità)
    - [Comando 4: Statistiche Firmware (Opzionale)](#comando-4-statistiche-firmware-opzionale)
    - [Comando 5: Trend Attività Ultimi 7 Giorni](#comando-5-trend-attività-ultimi-7-giorni)
    - [Output Atteso](#output-atteso-4)
- [PARTE 2: NFP Validation](#parte-2-nfp-validation)
  - [2.1 Security](#21-security)
    - [2.1.1 Auth Check](#211-auth-check)
    - [2.1.2 TLS: data in transit](#212-tls-data-in-transit)
    - [2.1.3 SASL: Autenticazione Challenge-Response](#213-sasl-autenticazione-challenge-response)
    - [2.1.4 MongoDB ConfigMap vs Secret](#214-mongodb-configmap-vs-secret)
    - [Conclusioni](#conclusioni)
  - [2.2 Fault Tolerance - Consumer Crash \& Buffering (4-5 minuti)](#22-fault-tolerance---consumer-crash--buffering-4-5-minuti)
    - [**Step 1: Simulazione Crash Consumer**](#step-1-simulazione-crash-consumer)
    - [**Step 2: Invio Eventi Durante Downtime**](#step-2-invio-eventi-durante-downtime)
    - [**Step 3: Verifica Lag su Kafka (Opzionale - Dimostrativo)**](#step-3-verifica-lag-su-kafka-opzionale---dimostrativo)
    - [**Step 4: Recovery - Riavvio Consumer**](#step-4-recovery---riavvio-consumer)
    - [**Step 5: Verifica Processamento Messaggi Buffered**](#step-5-verifica-processamento-messaggi-buffered)
    - [Conclusioni](#conclusioni-1)
  - [2.3 High Availability - Self-Healing (3-4 minuti)](#23-high-availability---self-healing-3-4-minuti)
    - [**Step 1: Setup Monitoring Pre-Crash**](#step-1-setup-monitoring-pre-crash)
    - [**Step 2: Simulazione Crash (Pod Kill)**](#step-2-simulazione-crash-pod-kill)
    - [**Step 3: Osservazione Recovery in Real-Time**](#step-3-osservazione-recovery-in-real-time)
    - [Conclusioni](#conclusioni-2)
  - [2.4 Scalabilità - Manual Scale \& Load Balancing (5-6 minuti)](#24-scalabilità---manual-scale--load-balancing-5-6-minuti)
    - [**Step 1: Scaling Manuale dei Microservizi**](#step-1-scaling-manuale-dei-microservizi)
    - [**Step 2: Burst Test - Injection Carico Massivo**](#step-2-burst-test---injection-carico-massivo)
    - [**Step 3: Validazione Load Balancing - Producer (HTTP Layer)**](#step-3-validazione-load-balancing---producer-http-layer)
    - [**Step 4: Validazione Parallelism - Consumer (Kafka Layer)**](#step-4-validazione-parallelism---consumer-kafka-layer)
    - [**Step 5: Restore Replicas**](#step-5-restore-replicas)
    - [Conclusioni](#conclusioni-3)
  - [2.5 Elasticità - Horizontal Pod Autoscaler (4-5 minuti)](#25-elasticità---horizontal-pod-autoscaler-4-5-minuti)
    - [**Step 1: Deploy HPA Configuration**](#step-1-deploy-hpa-configuration)
    - [**Step 2: Stress Test - Generazione Carico Pesante**](#step-2-stress-test---generazione-carico-pesante)
    - [**Step 3: Monitoring HPA in Real-Time**](#step-3-monitoring-hpa-in-real-time)
    - [**Step 4: Cleanup HPA**](#step-4-cleanup-hpa)
    - [Conclusioni](#conclusioni-4)
  - [2.6 Rate Limiting - DoS Protection (3-4 minuti)](#26-rate-limiting---dos-protection-3-4-minuti)
    - [**Step 1: Deploy Rate Limiting Plugin**](#step-1-deploy-rate-limiting-plugin)
    - [**Step 2: Attivazione Plugin su Ingress**](#step-2-attivazione-plugin-su-ingress)
    - [**Step 3: Flood Test - Saturazione Soglia**](#step-3-flood-test---saturazione-soglia)
    - [**Step 4: Cleanup Rate Limiting**](#step-4-cleanup-rate-limiting)
    - [Conclusioni](#conclusioni-5)
- [Conclusione Demo](#conclusione-demo)


## Setup Iniziale
> "Prima di iniziare con i test, devo configurare le variabili d'ambiente necessarie per comunicare con il cluster." \
> "Queste variabili verranno utilizzate in tutti i comandi `curl` successivi grazie al servizio nip.io, che risolve dinamicamente i sottodomini producer e metrics direttamente all'IP del cluster."
```bash
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')
export API_KEY="iot-sensor-key-prod-v1"

echo "Target (IP:PORT): $IP:$PORT"
echo "API Key: $API_KEY"
```

### Verifica Stato Cluster 
> "Prima di iniziare, verifico rapidamente lo stato dei componenti principali dell'architettura per assicurarmi che tutto sia operativo."

```bash
# Verifica pod nei namespace critici
kubectl get pods -n kafka -l "app in (producer, consumer)"
kubectl get pods -n metrics -l app=metrics-service
kubectl get pods -n kafka -l strimzi.io/name=iot-sensor-cluster-kafka

# Verifica servizi Kong
kubectl get svc -n kong kong-kong-proxy
```

## TEST BASE: Pipeline Completa
> "Ora testiamo il flusso completo end-to-end dell'architettura Event-Driven. \
> Invierò eventi di tutte e quattro le tipologie gestite dal sistema: Boot (avvio dispositivo), Telemetry (dati ambientali), Alert (allarmi critici) e Firmware Update (aggiornamenti). \
> L'obiettivo è dimostrare che i dati attraversano correttamente tutta la pipeline: Producer → Kafka → Consumer → MongoDB, e che il routing intelligente funziona, con i dati operativi che vanno sul topic 'sensor-telemetry' (ottimizzato con compressione LZ4) e gli allarmi su 'sensor-alerts' (configurato per massima durabilità)."

### SCRITTURA / INVIO DATI

**[APRIRE NUOVO TERMINALE - Tab 1]**
> "Per visualizzare in tempo reale il processamento dei messaggi, apro un terminale parallelo dove monitoro i log del Consumer."

```bash
# Monitoring continuo dei log del Consumer con filtraggio per eventi recenti
kubectl logs -l app=consumer -n kafka -f --tail=0
```

> "Procedo ora con l'invio di eventi rappresentativi delle quattro tipologie. Per ogni tipo, vedremo il log corrispondente apparire nel terminale del Consumer, confermando che il messaggio è stato letto da Kafka e salvato su MongoDB."

#### **Evento 1: Device Boot** (Accensione Sensore)
```bash
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "firmware": "v1.0"}'
```
```bash
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "zone_id": "warehouse-A", "firmware": "v1.0"}'
```

#### **Evento 2: Telemetry Data** (Dati Ambientali Normali)
```bash
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "temperature": 24.5, "humidity": 45}'
```

```bash
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "zone_id": "warehouse-A", "temperature": 32.0, "humidity": 30}'
```

#### **Evento 3: Critical Alert** (Allarme Critico)
```bash
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/alert \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "error_code": "CRITICAL_OVERHEAT", "severity": "high"}'
```

#### **Evento 4: Firmware Update** (Aggiornamento OTA)
```bash
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/firmware_update \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "version_to": "v2.0"}'
```


**[CHIUDERE Tab 1 - Logs Consumer]**
> Premere `CTRL+C` per terminare il comando `kubectl logs -f`

### LETTURA / ANALITICHE Metrics Service
> "Il Metrics Service espone diverse API per l'analisi dei dati.

#### Comando 1: Totale Boot Events
```bash
curl -s -H "apikey: $API_KEY" \
  http://metrics.$IP.nip.io:$PORT/metrics/boots | jq
```

##### Output Atteso
```json
  "total_device_boots": 2
```
> "Il sistema ha registrato correttamente 2 eventi di boot (sensor-01 e sensor-02)."

#### Comando 2: Media Temperatura per Zona
```bash
curl -s -H "apikey: $API_KEY" \
  http://metrics.$IP.nip.io:$PORT/metrics/temperature/average-by-zone | jq
```

##### Output Atteso
```json
  "_id": "warehouse-A",
  "avg_temp": 28.25,
  "avg_hum": 37.5,
  "samples": 2
```
> "Il Metrics Service ha eseguito un'aggregation pipeline su MongoDB e ha calcolato le medie.
> Questa query sfrutta gli indici clustered automatici delle Time Series Collection, garantendo performance elevate anche su dataset molto grandi."

#### Comando 3: Breakdown Allarmi per Severità
```bash
curl -s -H "apikey: $API_KEY" \
  http://metrics.$IP.nip.io:$PORT/metrics/alerts | jq
```

##### Output Atteso
```json
  "_id": "high",
  "count": 1
```

#### Comando 4: Statistiche Firmware (Opzionale)
```bash
curl -s -H "apikey: $API_KEY" \
  http://metrics.$IP.nip.io:$PORT/metrics/firmware | jq
```

##### Output Atteso
```json
  "_id": "v2.0",
  "count": 1
```


#### Comando 5: Trend Attività Ultimi 7 Giorni
```bash
curl -s -H "apikey: $API_KEY" \
  http://metrics.$IP.nip.io:$PORT/metrics/activity/last7days | jq
```

#### Output Atteso
```json
  "_id": "2025-12-06",
  "events_count": 6
```

## PARTE 2: NFP Validation

### 2.1 Security


#### 2.1.1 Auth Check 
> "L'obiettivo è dimostrare il pattern di **Gateway Offloading**: Kong deve bloccare qualsiasi richiesta non autenticata all'edge, restituendo un errore 401 Unauthorized, senza mai raggiungere i microservizi backend."

##### Test Negativo: Accesso Negato (Senza API Key)
> "Iniziamo con lo scenario negativo: provo a contattare il Producer senza fornire alcuna API Key nell'header della richiesta."

```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "Content-Type: application/json" \
  -d '{"device_id": "hacker-device", "zone_id": "unknown"}'
```

Output Atteso
```http
  "message": "No API key found in request"
```
> "Come previsto, Kong ha intercettato la richiesta e restituito un errore 401 con il messaggio 'No API key found in request', la richiesta è stata respinta all'edge. Questo protegge il backend da traffico non autorizzato e potenziali attacchi."

##### Test Negativo: Accesso con API Key Errata
> "Ora verifichiamo che anche fornendo un'API Key, se questa non è valida (non presente nel database di Kong), la richiesta venga comunque bloccata."
```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: bad-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "hacker-device", "zone_id": "unknown"}'
```

Output Atteso
```http
{
  "message": "Unauthorized",
}
```
> "Anche con un header 'apikey' presente, Kong ha verificato che la chiave 'bad-key-12345' non corrisponde a nessuna credenziale registrata nel Secret Kubernetes 'iot-devices-apikey', quindi ha respinto la richiesta con 'Invalid authentication credentials'."


##### Test Positivo: Accesso Consentito (Con API Key Valida)
> "Ora eseguiamo il test positivo: utilizziamo l'API Key corretta registrata nel sistema. La richiesta deve essere accettata e il payload deve essere processato dal Producer."
```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "test-sensor", "zone_id": "lab", "firmware": "v1.0"}'
```

##### Output Atteso
```http
HTTP/1.1 200 OK
{
  "status": "boot_recorded",
  "event": {
    "event_id": "8f3a7b2c-4d5e-6f7a-8b9c-0d1e2f3a4b5c",
    "type": "boot",
    "timestamp": "2025-12-06T10:17:30.123456",
    "device_id": "test-sensor",
    "zone_id": "lab",
    "firmware": "v1.0"
  }
}
```

> "Questa volta abbiamo ricevuto un 200 OK. Il Producer ha accettato la richiesta, l'ha processata e ha restituito il payload arricchito.\
> Questo dimostra che il pattern di Gateway Offloading funziona correttamente: l'autenticazione avviene all'edge tramite Kong, il quale inoltra solo le richieste valide al backend.
> Kong protegge l'edge con API Key authentication.


#### 2.1.2 TLS: data in transit

> "Il primo controllo valida che la connessione tra microservizi e broker Kafka avvenga su canale cifrato. Mi connetto direttamente a un pod del broker Kafka e utilizzo OpenSSL per ispezionare il protocollo TLS sulla porta 9093, che è la porta configurata per le connessioni sicure."

```bash
kubectl exec -it -n kafka iot-sensor-cluster-broker-0 -- \
  openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief </dev/null
```

Output Atteso
```
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
...
```

> 1. **Protocol version: TLSv1.3** - Stiamo usando l'ultima versione del protocollo TLS, che elimina vulnerabilità note delle versioni precedenti
> 2. **Ciphersuite: TLS_AES_256_GCM_SHA384** - Questa è una cipher suite robusta che usa AES a 256 bit con modalità GCM (Galois/Counter Mode) per cifratura autenticata, e SHA384 per l'integrità dei dati
> Questo significa che tutti i messaggi scambiati tra Producer/Consumer e Kafka transitano in un tunnel cifrato, proteggendoli da attacchi Man-in-the-Middle anche se qualcuno riuscisse a intercettare il traffico di rete interno al cluster."

#### 2.1.3 SASL: Autenticazione Challenge-Response
> "La cifratura TLS protegge i dati in transito, ma non verifica l'identità di chi si connette. Per questo abbiamo implementato SASL/SCRAM-SHA-512, un meccanismo di autenticazione challenge-response sicuro. Verifichiamo che le credenziali siano gestite correttamente come Kubernetes Secrets e non in chiaro nei manifest."

```bash
# Visualizza il Secret del Consumer/Consumer (password in base64)
kubectl get secret consumer-user -n kafka -o yaml | grep "password:"
```

> "Questo Secret viene montato come variabile d'ambiente nei pod del Consumer e Producer tramite 'secretKeyRef' nel Deployment manifest, quindi la password non appare mai in chiaro nei file YAML versionati su Git."
> "Anche il Producer ha le sue credenziali separate. Questo segue il principio del least privilege: ogni microservizio ha un utente Kafka dedicato con permessi specifici. Se un componente venisse compromesso, l'attaccante avrebbe accesso solo a quel subset di operazioni."

#### 2.1.4 MongoDB ConfigMap vs Secret

> "Completiamo la validazione della sicurezza verificando che anche le credenziali di MongoDB siano gestite tramite Secrets, non hardcoded."

```bash
# 1. Verifica ConfigMap (parametri NON sensibili)
echo "=== CONFIGMAP (Non Sensibili) ==="
kubectl get configmap -n kafka mongodb-config -o yaml | grep "MONGO_"
```

```bash
echo "=== SECRET (Sensibili) ==="
# 2. Verifica Secret (credenziali SENSIBILI in base64)
kubectl get secret -n kafka mongo-creds -o yaml | grep "MONGO_"
```

> **ConfigMap** (mongodb-config):
> - Host, porta, nome database, authentication source
> - Parametri infrastrutturali non sensibili
> - Possono essere versionati pubblicamente su Git
> 
> **Secret** (mongo-creds):
> - Username e password in base64
> - Parametri sensibili che non devono mai finire in repository pubblici
> - Vengono iniettati nei pod come variabili d'ambiente al runtime


#### Conclusioni
> Questa architettura implementa la Defense in Depth su tre layer:
> - **Edge**: API Key authentication su Kong
> - **Transport**: TLS 1.3 per cifratura dati
> - **Application**: SASL/SCRAM per autenticazione utenti


### 2.2 Fault Tolerance - Consumer Crash & Buffering (4-5 minuti)
> "Ora testiamo una proprietà critica per sistemi distribuiti: la Fault Tolerance. \
> L'obiettivo è dimostrare che il sistema non perde dati anche in caso di crash totale del Consumer. Questo è possibile grazie alla natura asincrona di Kafka, che funge da buffer persistente tra Producer e Consumer. Il **disaccoppiamento** tramite messaggistica permette ai due componenti di operare indipendentemente: se il Consumer crasha, i messaggi si accumulano su Kafka e vengono processati non appena il servizio torna online, garantendo Zero Data Loss."

#### **Step 1: Simulazione Crash Consumer**
> "Primo step: simulo un crash totale scalando il Consumer a zero repliche. Questo equivale a un guasto hardware del nodo che ospita il pod, o a un crash irrecuperabile del processo Python."

```bash
kubectl scale deploy/consumer -n kafka --replicas=0
```

#### **Step 2: Invio Eventi Durante Downtime**
> "Ora invio 5 eventi di telemetria mentre il Consumer è offline. Questi messaggi verranno accettati dal Producer e bufferizzati su Kafka, ma non potranno essere consumati finché il worker non torna online."

```bash
echo "Invio eventi durante downtime del Consumer..."
for i in {1..5}; do
  RESPONSE=$(curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
    -H "apikey: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"offline-sensor-$i\", \"zone_id\":\"buffer-test\", \"temperature\": 20.0, \"humidity\": 50.0}")
  
  # Estrai event_id dalla risposta per tracking
  EVENT_ID=$(echo $RESPONSE | jq -r '.event.event_id')
  echo "  [$i/5] Inviato offline-sensor-$i (Event ID: ${EVENT_ID:0:8}...)"
done
echo "Completato invio di 5 eventi."
```


#### **Step 3: Verifica Lag su Kafka (Opzionale - Dimostrativo)**
> "Per dimostrare visivamente che i messaggi sono effettivamente bufferizzati su Kafka, possiamo interrogare il Consumer Group per vedere il lag - ovvero quanti messaggi sono in attesa di essere consumati."
```bash
# Esegui all'interno di un pod broker Kafka per usare i tool di Kafka
kubectl exec -it -n kafka iot-sensor-cluster-broker-0 -- \
  /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --group iot-consumer-group \
    --describe
```

Output Atteso (Semplificato)
```
GROUP             TOPIC            PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
iot-consumer-group sensor-telemetry 0         15              17              2
iot-consumer-group sensor-telemetry 1         12              14              2
iot-consumer-group sensor-telemetry 2         10              11              1
```

> "La colonna 'LAG' mostra che ci sono messaggi non consumati (LAG > 0) sulle partizioni. Il totale è 5 (2+2+1), corrispondente esattamente ai 5 eventi che abbiamo inviato. Questi messaggi sono persistiti su disco e aspettano il Consumer. Ora procediamo al recovery."


#### **Step 4: Recovery - Riavvio Consumer**
> "Ora simulo il ripristino del servizio riportando il Consumer a 1 replica. Kubernetes creerà un nuovo pod, che al boot richiederà gli offset committati al Consumer Group, e riprenderà la lettura esattamente dal punto in cui si era interrotto, processando tutti i messaggi accumulati."

```bash
kubectl scale deploy/consumer -n kafka --replicas=1

# Attendi che il pod sia ready
kubectl wait --for=condition=ready pod -l app=consumer -n kafka --timeout=60s
```

> "Il Consumer è tornato online. Ora apro il monitoring dei log per vedere in tempo reale il processamento dei messaggi accumulati."

#### **Step 5: Verifica Processamento Messaggi Buffered**

**[APRIRE NUOVO TERMINALE - Tab 2]** - Monitoring Recovery
```bash
# Mostra gli ultimi 20 log e segui in tempo reale
kubectl logs -n kafka -l app=consumer -f --tail=20
```

Output Atteso (Nei primi secondi dopo il riavvio)
```
Connected to MongoDB (mongo-mongodb-headless.kafka.svc.cluster.local:27017)
IoT Consumer avviato. In ascolto su: ['sensor-telemetry', 'sensor-alerts']
[✓] [TELEMETRY] Device offline-sensor-1 -> Temp: 20.0°C, Hum: 50.0%
[✓] [TELEMETRY] Device offline-sensor-2 -> Temp: 20.0°C, Hum: 50.0%
[✓] [TELEMETRY] Device offline-sensor-3 -> Temp: 20.0°C, Hum: 50.0%
[✓] [TELEMETRY] Device offline-sensor-4 -> Temp: 20.0°C, Hum: 50.0%
[✓] [TELEMETRY] Device offline-sensor-5 -> Temp: 20.0°C, Hum: 50.0%
```
**[CHIUDERE Tab 2]** - Terminare monitoring con CTRL+C

> "Guardate i log: nel giro di pochi secondi, il Consumer ha:
> 1. Completato il bootstrap (connessione a MongoDB e Kafka)
> 2. Sottoscritto i topic 'sensor-telemetry' e 'sensor-alerts'
> 3. Richiesto al Kafka Broker l'ultimo offset committato per il suo Consumer Group
> 4. Processato immediatamente i 5 messaggi che erano rimasti in coda durante il downtime


#### Conclusioni

> Questo test dimostra la Fault Tolerance dell'architettura Event-Driven:
> 1. **Disaccoppiamento**: Producer e Consumer operano indipendentemente
> 2. **Buffer Persistente**: Kafka mantiene i messaggi su disco anche durante crash
> 3. **Zero Data Loss**: Nessun messaggio è stato perso durante il downtime
> 4. **Automatic Recovery**: Al riavvio, il Consumer riprende automaticamente dal punto corretto
> 5. **Idempotenza Ready**: Grazie agli event_id, possiamo implementare upsert idempotenti se necessario

### 2.3 High Availability - Self-Healing (3-4 minuti)

> "Ora testiamo la High Availability e il meccanismo di Self-Healing di Kubernetes. L'obiettivo è dimostrare che il sistema è capace di rilevare automaticamente guasti dei pod e ripristinarli senza intervento umano. Eliminerò forzatamente un pod del Producer per simulare un crash improvviso - come potrebbe accadere per un bug nel codice, esaurimento memoria (OOMKill), o failure del nodo fisico. Kubernetes deve rilevare che lo stato desiderato (replicas: 1) non corrisponde allo stato attuale (replicas: 0) e creare immediatamente un nuovo pod sostitutivo."

#### **Step 1: Setup Monitoring Pre-Crash**

> "Prima di causare il guasto, avvio un watcher in tempo reale sui pod del Producer. Questo ci permetterà di vedere esattamente cosa succede durante il crash e il recovery: termination del vecchio pod, creazione del nuovo, e transizioni di stato."

**[APRIRE NUOVO TERMINALE - Tab 3]** - Pod Watcher
```bash
kubectl get pods -n kafka -l app=producer -w
```


#### **Step 2: Simulazione Crash (Pod Kill)**

> "Forzo la cancellazione del pod attualmente in esecuzione. Kubernetes interpre questo come un segnale SIGTERM seguito da SIGKILL se il graceful shutdown fallisce."

Comando: Kill Pod
```bash
# Elimina automaticamente il primo pod del producer trovato
kubectl delete pod $(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}") -n kafka
```

#### **Step 3: Osservazione Recovery in Real-Time**

```
NAME                        READY   STATUS        RESTARTS   AGE
producer-7d8f9c6b5d-abc12   1/1     Terminating   0          10m
producer-7d8f9c6b5d-xyz78   0/1     Pending       0          0s
producer-7d8f9c6b5d-xyz78   0/1     Pending       0          0s
producer-7d8f9c6b5d-xyz78   0/1     ContainerCreating   0    1s
producer-7d8f9c6b5d-abc12   0/1     Terminating         0    10m
producer-7d8f9c6b5d-abc12   0/1     Terminating         0    10m
producer-7d8f9c6b5d-abc12   0/1     Terminating         0    10m
producer-7d8f9c6b5d-xyz78   1/1     Running             0    18s
```

> Ma questo test dimostra che il recovery è completamente automatico. In produzione, con 2+ repliche, il downtime sarebbe ZERO: Kong e il Service Kubernetes avrebbero immediatamente rediretto il traffico alle repliche superstiti."


#### Conclusioni 
> "Questo test ha dimostrato tre meccanismi fondamentali di Kubernetes:
> 1. **Self-Healing Automatico**: 
>    - Il ReplicaSet controlla costantemente che il numero di pod in Running corrisponda allo stato desiderato
>    - In caso di discrepanza, crea automaticamente nuovi pod sostitutivi
>    - Nessun intervento umano necessario
> 
> 2. **High Availability tramite Replication**:
>    - Con 2+ repliche, il sistema sopravvive al crash di un pod senza downtime
>    - Il Service Kubernetes + Kong Load Balancer reindirizzano automaticamente il traffico
> 
> 3. **Graceful Degradation**:
>    - Durante il recovery, il sistema potrebbe operare a capacità ridotta (1 replica invece di 2)
>    - Ma rimane comunque disponibile e si auto-ripara


### 2.4 Scalabilità - Manual Scale & Load Balancing (5-6 minuti)

> "Ora testiamo la capacità di scalare orizzontalmente il sistema e la distribuzione automatica del carico. L'obiettivo è dimostrare due proprietà chiave:
> 1. **Ingress Load Balancing (HTTP Layer)**: Kong e il Service Kubernetes distribuiscono il traffico HTTP tra le repliche del Producer
> 2. **Consumer Parallelism (Kafka Layer)**: Il Consumer Group protocol di Kafka assegna automaticamente partizioni esclusive a ogni replica del Consumer, massimizzando il throughput
> 

#### **Step 1: Scaling Manuale dei Microservizi**

> "Primo step: scalo manualmente i Deployment. Il Producer a 2 repliche per testare il Round-Robin HTTP, e il Consumer a 3 repliche per sfruttare completamente le 3 partizioni del topic 'sensor-telemetry'. Notate che scalare il Consumer a più di 3 repliche non aumenterebbe il throughput, perché ci sono solo 3 partizioni - le repliche extra rimarrebbero idle."

```bash
echo "=== SCALING PRODUCER TO 2 REPLICAS ==="
kubectl scale deploy/producer -n kafka --replicas=2

echo ""
echo "=== SCALING CONSUMER TO 3 REPLICAS ==="
kubectl scale deploy/consumer -n kafka --replicas=3

echo ""
echo "Attendere che tutti i pod siano ready..."
kubectl wait --for=condition=ready pod -l app=producer -n kafka --timeout=90s
kubectl wait --for=condition=ready pod -l app=consumer -n kafka --timeout=90s

echo ""
echo "=== VERIFICA STATO POD ==="
kubectl get pods -n kafka -l "app in (producer, consumer)"
```

> "Ora abbiamo 2 repliche del Producer e 3 del Consumer, tutte in stato Running. 


#### **Step 2: Burst Test - Injection Carico Massivo**

> "Ora invio un burst di 50 richieste rapide senza delay tra una e l'altra. Questo carico elevato costringerà il Service Kubernetes a distribuire il traffico tra le 2 repliche del Producer, e i Producer invieranno messaggi a Kafka che verranno distribuiti sulle 3 partizioni e consumati dai 3 Consumer in parallelo."

```bash
echo "=== BURST TEST: INVIO 50 RICHIESTE RAPIDE ==="
echo "Inizio: $(date +%H:%M:%S)"

for i in {1..50}; do
  curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"device_id\":\"load-test-$i\", \"zone_id\":\"LB-test\", \"temperature\": 22.5, \"humidity\": 48.0}" \
  > /dev/null
  
  # Progress indicator ogni 10 richieste
  if [ $((i % 10)) -eq 0 ]; then
    echo "  Progresso: $i/50 richieste inviate"
  fi
done

echo "Fine: $(date +%H:%M:%S)"
echo "=== BURST COMPLETATO ==="
```

#### **Step 3: Validazione Load Balancing - Producer (HTTP Layer)**
> "Primo check: verifichiamo che il traffico HTTP sia stato distribuito tra le 2 repliche del Producer. Se il load balancing funziona, dovremmo vedere entrambi i pod nei log, con una distribuzione approssimativamente uniforme (circa 25 richieste ciascuno)."

```bash
echo "=== DISTRIBUZIONE TRAFFICO TRA PRODUCER ==="
echo ""
echo "Pod 1:"
PRODUCER_1=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}")
COUNT_1=$(kubectl logs -n kafka $PRODUCER_1 --tail=100 | grep "load-test" | wc -l)
echo "  Nome: $PRODUCER_1"
echo "  Richieste processate: $COUNT_1"

echo ""
echo "Pod 2:"
PRODUCER_2=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[1].metadata.name}")
COUNT_2=$(kubectl logs -n kafka $PRODUCER_2 --tail=100 | grep "load-test" | wc -l)
echo "  Nome: $PRODUCER_2"
echo "  Richieste processate: $COUNT_2"

echo ""
echo "Totale: $((COUNT_1 + COUNT_2))/50"

# Campione di log
echo ""
echo "=== CAMPIONE LOG PRODUCER 1 (prime 3 righe) ==="
kubectl logs -n kafka $PRODUCER_1 --tail=50 | grep "load-test" | head -n 3

echo ""
echo "=== CAMPIONE LOG PRODUCER 2 (prime 3 righe) ==="
kubectl logs -n kafka $PRODUCER_2 --tail=50 | grep "load-test" | head -n 3
```

Output Atteso
```
=== DISTRIBUZIONE TRAFFICO TRA PRODUCER ===

Pod 1:
  Nome: producer-7d8f9c6b5d-abc12
  Richieste processate: 26

Pod 2:
  Nome: producer-7d8f9c6b5d-xyz78
  Richieste processate: 24

Totale: 50/50

=== CAMPIONE LOG PRODUCER 1 (prime 3 righe) ===
[PRODUCER] telemetry -> sensor-telemetry: {...'device_id': 'load-test-1'...}
[PRODUCER] telemetry -> sensor-telemetry: {...'device_id': 'load-test-3'...}
[PRODUCER] telemetry -> sensor-telemetry: {...'device_id': 'load-test-5'...}

=== CAMPIONE LOG PRODUCER 2 (prime 3 righe) ===
[PRODUCER] telemetry -> sensor-telemetry: {...'device_id': 'load-test-2'...}
[PRODUCER] telemetry -> sensor-telemetry: {...'device_id': 'load-test-4'...}
[PRODUCER] telemetry -> sensor-telemetry: {...'device_id': 'load-test-6'...}
```


> 1. **Kong Ingress Controller** ha bilanciato il traffico HTTP in entrata
> 2. Il **Service Kubernetes** (ClusterIP) ha distribuito le connessioni tra i backend pod
> 3. L'algoritmo di bilanciamento è **Round-Robin**: le richieste alternate tra i pod


#### **Step 4: Validazione Parallelism - Consumer (Kafka Layer)**

> "Ora verifichiamo il parallelismo lato Kafka. Con 3 partizioni e 3 repliche del Consumer, ogni replica dovrebbe aver letto da una partizione dedicata. Il Kafka Consumer Group protocol garantisce l'assegnazione esclusiva delle partizioni per evitare duplicazioni."
```bash
echo "=== DISTRIBUZIONE ELABORAZIONE TRA CONSUMER ==="
echo ""

for i in 0 1 2; do
  POD=$(kubectl get pod -l app=consumer -n kafka -o jsonpath="{.items[$i].metadata.name}")
  COUNT=$(kubectl logs -n kafka $POD --tail=100 | grep "load-test" | wc -l)
  echo "Consumer $((i+1)): $POD"
  echo "  Eventi processati: $COUNT"
  echo ""
done

echo "=== CAMPIONI LOG PER CONFERMA VISIVA ==="
echo ""
for i in 0 1 2; do
  POD=$(kubectl get pod -l app=consumer -n kafka -o jsonpath="{.items[$i].metadata.name}")
  echo "Consumer $((i+1)) - Prime 3 linee:"
  kubectl logs -n kafka $POD --tail=50 | grep "load-test" | head -n 3
  echo ""
done
```

Output Atteso
```
=== DISTRIBUZIONE ELABORAZIONE TRA CONSUMER ===

Consumer 1: consumer-9b4c3a1f2e-aaa11
  Eventi processati: 17

Consumer 2: consumer-9b4c3a1f2e-bbb22
  Eventi processati: 16

Consumer 3: consumer-9b4c3a1f2e-ccc33
  Eventi processati: 17

=== CAMPIONI LOG PER CONFERMA VISIVA ===

Consumer 1 - Prime 3 linee:
[✓] [TELEMETRY] Device load-test-1 -> Temp: 22.5°C, Hum: 48.0%
[✓] [TELEMETRY] Device load-test-7 -> Temp: 22.5°C, Hum: 48.0%
[✓] [TELEMETRY] Device load-test-10 -> Temp: 22.5°C, Hum: 48.0%

Consumer 2 - Prime 3 linee:
[✓] [TELEMETRY] Device load-test-2 -> Temp: 22.5°C, Hum: 48.0%
[✓] [TELEMETRY] Device load-test-5 -> Temp: 22.5°C, Hum: 48.0%
[✓] [TELEMETRY] Device load-test-11 -> Temp: 22.5°C, Hum: 48.0%

Consumer 3 - Prime 3 linee:
[✓] [TELEMETRY] Device load-test-3 -> Temp: 22.5°C, Hum: 48.0%
[✓] [TELEMETRY] Device load-test-6 -> Temp: 22.5°C, Hum: 48.0%
[✓] [TELEMETRY] Device load-test-9 -> Temp: 22.5°C, Hum: 48.0%
```

> 1. Il Producer ha distribuito i 50 messaggi tra le 3 partizioni del topic (con partitioning probabilmente basato su hash del device_id)
> 2. Kafka ha assegnato esclusivamente la Partition 0 al Consumer 1, la Partition 1 al Consumer 2, e la Partition 2 al Consumer 3
> 3. Ogni Consumer legge SOLO dalla sua partizione assegnata, garantendo che nessun messaggio venga processato due volte
> 
> Questa architettura permette di scalare linearmente il throughput di lettura"


#### **Step 5: Restore Replicas**

> "Ora riporto il sistema allo stato iniziale con singola replica per liberare risorse per i test successivi."

```bash
echo "=== RESTORE TO SINGLE REPLICA ==="
kubectl scale deploy/producer -n kafka --replicas=1
kubectl scale deploy/consumer -n kafka --replicas=1

echo ""
echo "Attendere terminazione pod in eccesso..."
sleep 5

echo ""
echo "=== STATO FINALE ==="
kubectl get pods -n kafka -l "app in (producer, consumer)"
```

#### Conclusioni

> **Scalabilità Orizzontale**:
> - Possibilità di aumentare il numero di repliche per gestire carichi maggiori
> - Distribuzione automatica del traffico senza configurazione manuale
> 
> **Load Balancing Multi-Layer**:
> - **HTTP Layer (Kong + Service)**: Round-Robin tra Producer
> - **Streaming Layer (Kafka)**: Partition assignment esclusivo tra Consumer
> 
> **Throughput Scalabile**:
> - Con N partizioni, possiamo avere fino a N Consumer in parallelo
> - Scalare oltre N Consumer non aumenta il throughput (repliche idle)
> 
> **High Availability Implicita**:
> - Con 2+ repliche, il sistema sopravvive al crash di un pod
> - Load balancer redirezione automatica del traffico

### 2.5 Elasticità - Horizontal Pod Autoscaler (4-5 minuti)

> "L'ultimo test di scalabilità valida l'elasticità automatica del sistema tramite l'Horizontal Pod Autoscaler (HPA). A differenza dello scaling manuale appena visto, l'HPA permette a Kubernetes di adattare autonomamente il numero di repliche in base al carico di lavoro effettivo, senza intervento umano. Questo è essenziale in ambienti cloud-native per:
> 1. **Gestire picchi imprevisti**: Scale out automatico quando il traffico aumenta
> 2. **Ottimizzare i costi**: Scale down automatico quando il carico diminuisce
> 
> Ho configurato una soglia CPU del 50%: quando il carico medio supera questo valore, Kubernetes scalerà automaticamente da 1 fino a un massimo di 4 repliche. **Attenzione**: questo test richiede qualche minuto perché l'HPA impiega tempo per raccogliere metriche, valutare le condizioni, e far partire i nuovi pod."

#### **Step 1: Deploy HPA Configuration**
> "Primo step: applico il manifest dell'HPA che configura le policy di scaling per Producer, Consumer e Metrics Service."

```bash
kubectl apply -f ./K8s/hpa.yaml

# Attendi che l'HPA sia operativo
sleep 5

echo ""
echo "=== STATO INIZIALE HPA ==="
kubectl get hpa -n kafka
kubectl get hpa -n metrics
```
 
> L'HPA interroga il Metrics Server di Kubernetes ogni 15 secondi per ottenere le metriche CPU/RAM dei pod. Quando rileva che la media supera il 50%, inizia il processo di scale-out."


#### **Step 2: Stress Test - Generazione Carico Pesante**

> "Ora genero un carico pesante per saturare la CPU. Invio 5000 richieste consecutive, che dovrebbero far salire l'utilizzo CPU ben oltre il 50% e triggerare l'autoscaling."

```bash
echo "=== STRESS TEST STARTED ==="
echo "Inviando 5000 richieste per saturare la CPU..."
echo "Inizio: $(date +%H:%M:%S)"
echo ""

for i in {1..5000}; do
  curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
    -H "apikey: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"stress-sensor-$i\", \"zone_id\":\"HPA-test\", \"temperature\": 50.0, \"humidity\": 10.0}" \
    > /dev/null
  
  # Progress bar ogni 500 richieste
  if [ $((i % 500)) -eq 0 ]; then
    PROGRESS=$((i * 100 / 5000))
    echo "  [$PROGRESS%] $i/5000 richieste inviate"
  fi
done

echo ""
echo "Fine: $(date +%H:%M:%S)"
echo "=== STRESS TEST COMPLETATO ==="
```
#### **Step 3: Monitoring HPA in Real-Time**

> "Apro un watcher dell'HPA che si aggiorna ogni secondo. Vedrete il campo TARGETS (utilizzo CPU) salire, e poi il campo REPLICAS aumentare man mano che Kubernetes crea nuovi pod."

**[APRIRE NUOVO TERMINALE - Tab 5]** - HPA Live Monitoring
```bash
# Monitoring continuo con refresh ogni secondo
watch -n 1 'kubectl get hpa -n kafka'
```

```bash
kubectl get hpa -n kafka -w
```

> **Fase 1 - Detection (T+0-30s)**:
> - L'HPA rileva che il TARGETS (CPU) sta salendo rapidamente
> 
> **Fase 2 - Scale Out Aggressivo (T+30-120s)**:
> - La CPU continua a salire perché ci sono ancora migliaia di richieste in coda su Kafka
> - L'HPA aggiunge repliche rapidamente: 2 → 3 → 4 (massimo raggiunto)
> 
> **Fase 3 - Stabilizzazione (T+120-300s)**:
> - Tutte le 4 repliche del Producer sono Running
> - Il carico viene distribuito tra i 4 pod
> - La CPU per pod scende (es. 65% / 4 repliche = ~16% per pod)
> - Il sistema smaltisce la coda residua di messaggi su Kafka
> 
> **Fase 4 - Scale Down Graduale (T+300-600s)**:
> - Il carico termina, la CPU scende sotto il 50%
> - L'HPA aspetta 60 secondi di stabilità (stabilization window) prima di ridurre
> - Poi inizia il scale down: 4 → 2 → 1
> - Il processo è più lento della salita per evitare oscillazioni
> 
> Questo è l'elasticità automatica: il sistema si è espanso autonomamente per gestire il picco, poi si è contratto per rilasciare risorse non necessarie."


#### **Step 4: Cleanup HPA**

> "Ora rimuovo la configurazione HPA per ripristinare il controllo manuale delle repliche e liberare risorse per il test finale di Rate Limiting."

```bash
kubectl delete -f K8s/hpa.yaml

# Verifica rimozione
kubectl get hpa -A
```

#### Conclusioni
> Questo test ha dimostrato l'elasticità automatica cloud-native:
> 
> **Vantaggi dell'Auto-Scaling**:
> 1. **Resilienza ai picchi**: Il sistema assorbe automaticamente carichi imprevisti
> 2. **Ottimizzazione costi**: Rilascia risorse quando non servono (pay-per-use)
> 3. **Operazioni hands-free**: Nessun intervento umano necessario durante i picchi
> 4. **SLA guarantee**: Mantiene le performance anche sotto stress
> 
> **Configurazione Flessibile**:
> - Soglie personalizzabili (CPU, RAM, custom metrics)
> - Policy di scaling asimmetriche (veloce in salita, lento in discesa)
> - Limiti min/max per evitare over-provisioning


### 2.6 Rate Limiting - DoS Protection (3-4 minuti)

> "L'ultimo test valida la protezione contro attacchi Denial of Service (DoS) o flood involontari. Configurerò Kong con una policy di Rate Limiting che impone un limite di 5 richieste al secondo per client. Qualsiasi traffico eccedente questa soglia verrà respinto all'edge con codice HTTP 429 (Too Many Requests), proteggendo il backend da sovraccarichi o attacchi malevoli. Questo è essenziale per:
> 1. **Prevenire saturazione**: Evitare che un singolo client monopolizzi le risorse
> 2. **Garantire fairness**: Assicurare che tutti i client abbiano accesso equo
> 3. **Proteggere da DoS**: Mitigare attacchi flood deliberati o bug client-side"



#### **Step 1: Deploy Rate Limiting Plugin**
> "Primo step: creo un KongPlugin di tipo 'rate-limiting' che limita a 5 richieste al secondo. La policy è 'local', quindi ogni istanza di Kong conta autonomamente (in produzione si userebbe 'cluster' con Redis per condividere i contatori tra repliche)."

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: global-rate-limit
  namespace: kafka
config:
  second: 5              # Max 5 richieste al secondo
  policy: local          # Conteggio locale (non distribuito)
  hide_client_headers: false  # Mostra header rate-limit al client
plugin: rate-limiting
YAML

# Verifica creazione
kubectl get kongplugin -n kafka global-rate-limit
```
#### **Step 2: Attivazione Plugin su Ingress**

> "Patch l'Ingress per aggiungere il rate limiting alla pipeline di plugin già esistente."

```bash
kubectl patch ingress producer-ingress -n kafka \
  -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth, global-rate-limit"}}}'
```

> "Perfetto! L'Ingress ora applica entrambi i plugin in sequenza:
> 1. **key-auth**: Verifica l'API Key (401 se mancante/errata)
> 2. **global-rate-limit**: Conta le richieste e blocca se > 5/sec (429)


#### **Step 3: Flood Test - Saturazione Soglia**

> "Ora eseguo un flood test: 20 richieste inviate il più velocemente possibile senza delay. Questo simula un attacco DoS o un bug client-side che genera richieste infinite."

```bash
echo ""
echo "=== FLOOD TEST (20 richieste rapide - SOPRA SOGLIA) ==="
echo "Inizio: $(date +%H:%M:%S.%3N)"
echo ""

SUCCESS_COUNT=0
THROTTLED_COUNT=0

for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
    -H "apikey: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"flood-sensor-$i\", \"zone_id\":\"DoS-test\", \"temperature\": 99.0, \"humidity\": 0.0}")
  
  if [ "$HTTP_CODE" == "200" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    echo "  [$i] OK HTTP 200 OK"
  elif [ "$HTTP_CODE" == "429" ]; then
    THROTTLED_COUNT=$((THROTTLED_COUNT + 1))
    echo "  [$i] KO - HTTP 429 Too Many Requests (THROTTLED)"
  else
    echo "  [$i] ? HTTP $HTTP_CODE"
  fi
done

echo ""
echo "Fine: $(date +%H:%M:%S.%3N)"
echo ""
echo "=== RISULTATI FLOOD TEST ==="
echo "  Richieste accettate: $SUCCESS_COUNT"
echo "  Richieste bloccate: $THROTTLED_COUNT"
echo "  Totale: $((SUCCESS_COUNT + THROTTLED_COUNT))/20"
```

> "Il rate limiting ha funzionato esattamente come previsto:
> - **Prime 5 richieste**: Accettate (200 OK) - dentro il limite di 5 req/sec
> - **Richieste 6-20**: Bloccate (429) - soglia superata
> 
> Notate che tutte le 20 richieste sono state inviate nello stesso secondo (timestamp da 10:52:30.125 a 10:52:30.892). Kong ha contato le richieste, ha permesso le prime 5, e ha respinto le successive 15 all'edge, **senza mai raggiungere il Producer**."


#### **Step 4: Cleanup Rate Limiting**
> "Ora rimuovo il plugin di rate limiting per ripristinare il normale funzionamento del sistema, mantenendo solo l'autenticazione API Key."

```bash
# Rimuovi il plugin
kubectl delete kongplugin -n kafka global-rate-limit --ignore-not-found

# Ripristina Ingress solo con key-auth
kubectl patch ingress producer-ingress -n kafka \
  -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}'

```

#### Conclusioni

> **Protezione Implementata**:
> - Limite configurabile (5 req/sec, ma può essere adattato al contesto)
> - Blocco all'edge: traffico malevolo non raggiunge mai il backend
> - Header informativi per client smart
> - Policy dichiarativa: nessuna logica nel codice applicativo

## Conclusione Demo
> "Questo conclude la dimostrazione pratica delle proprietà non funzionali dell'architettura a microservizi Event-Driven su Kubernetes.
> 
> Abbiamo validato attraverso scenari pratici che il sistema garantisce:
> **1. Security (Defense in Depth)**:
> - **Edge Layer**: API Key authentication tramite Kong (Gateway Offloading)
> - **Transport Layer**: Cifratura TLS 1.3 con cipher suite robuste
> - **Application Layer**: Autenticazione SASL/SCRAM-SHA-512 per accesso Kafka
> - **Data Layer**: Secrets Management tramite Kubernetes (zero hardcoding)
> 
> **2. Resilience & Fault Tolerance**:
> - **Zero Data Loss**: Kafka come buffer persistente garantisce che nessun messaggio venga perso durante crash
> - **Automatic Recovery**: Il Consumer riprende automaticamente dal punto corretto dopo un guasto
> - **Disaccoppiamento Asincrono**: Producer e Consumer operano indipendentemente
> 
> **3. High Availability**:
> - **Self-Healing**: Kubernetes rileva e ripristina automaticamente pod crashati
> - **Replication**: Con 2+ repliche, zero downtime durante guasti
> - **Automatic Failover**: Il traffico viene rediretto istantaneamente alle repliche superstiti
> 
> **4. Scalabilità & Load Balancing**:
> - **HTTP Layer**: Kong + Service Kubernetes distribuiscono traffico Round-Robin
> - **Streaming Layer**: Kafka assegna partizioni esclusive per parallelismo massimo
> - **Linear Scaling**: Con N partizioni, supportiamo fino a N consumer paralleli
> 
> **5. Elasticità Automatica**:
> - **Auto-Scaling**: HPA espande/contrae repliche in base al carico CPU
> - **Cost Optimization**: Rilascio automatico risorse quando non necessarie
> - **Hands-Free Operations**: Gestione autonoma picchi senza intervento umano
> 
> **6. Protection & DoS Mitigation**:
> - **Rate Limiting**: Blocco traffico eccedente all'edge (429)
> - **Backend Protection**: Il traffico malevolo non raggiunge mai i microservizi
> - **Fairness**: Garanzia quote eque tra client


