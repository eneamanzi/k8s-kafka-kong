# Progetto Kubernetes per il corso CCT

L'obiettivo è implementare un'architettura a microservizi su Kubernetes per il monitoraggio di una rete di sensori IoT. Il sistema gestisce flussi di telemetria ad alta frequenza tramite **Kafka** (su topic differenziati per priorità), storicizza i dati su **MongoDB** (utilizzando collezioni Time Series ottimizzate) ed espone metriche aggregate tramite **Kong**. L'autenticazione dei dispositivi è gestita tramite **API Key**.

L'architettura include:

  * **Kong**: API Gateway per l'esposizione sicura (API Key) degli endpoint dei sensori.
  * **Producer**: Microservizio di ingestione che riceve dati dai dispositivi (Boot, Telemetria, Allarmi) e li pubblica su Kafka.
  * **Kafka (Strimzi)**: Message broker per il buffering e disaccoppiamento del flusso dati (`sensor-stream`).
  * **Consumer**: Worker che processa gli eventi raw e li salva strutturati su MongoDB.
  * **MongoDB**: Database NoSQL per la persistenza (`iot_network`).
  * **Metrics-service**: Servizio di analytics che calcola medie (es. temperatura per zona) e statistiche operative.

**Scelte Architetturali Chiave**
Questo progetto implementa best practice specifiche per sistemi IoT:
   - **API Key**: Appropriato per dispositivi con capacità computazionali limitate
   - **Topic Kafka separati per priorità**: Telemetria ad alto volume vs allarmi critici
   - **MongoDB Time Series**: Ottimizzazione nativa per dati temporali
   - **ConfigMap/Secret separation**: Sicurezza e portabilità
   - **Compressione LZ4**: Riduzione del 40-60% del traffico di rete
  
## Indice
- [Progetto Kubernetes per il corso CCT](#progetto-kubernetes-per-il-corso-cct)
  - [Indice](#indice)
  - [Prerequisiti](#prerequisiti)
  - [Architettura e Funzionamento](#architettura-e-funzionamento)
    - [Flusso di Ingestione (Scrittura)](#flusso-di-ingestione-scrittura)
    - [Flusso di Analisi (Lettura)](#flusso-di-analisi-lettura)
  - [Guida all'Installazione](#guida-allinstallazione)
    - [0. Setup Iniziale del Cluster](#0-setup-iniziale-del-cluster)
    - [1. Creazione Namespace](#1-creazione-namespace)
    - [2. Strimzi Kafka Operator](#2-strimzi-kafka-operator)
    - [3. MongoDB](#3-mongodb)
      - [3.1. Configurazione Utente Applicativo e Time Series Collection](#31-configurazione-utente-applicativo-e-time-series-collection)
      - [3.2. Configurazione ConfigMap e Secret (per Producer Consumer e Metrics-service)](#32-configurazione-configmap-e-secret-per-producer-consumer-e-metrics-service)
    - [4. Kong API Gateway](#4-kong-api-gateway)
    - [5. Microservizi (Producer, Consumer, Metrics)](#5-microservizi-producer-consumer-metrics)
      - [5.1. Aggiornamento Microservizi](#51-aggiornamento-microservizi)
    - [6. Autenticazione: API Key](#6-autenticazione-api-key)
      - [6.1 Configurazione Key-Auth](#61-configurazione-key-auth)
      - [6.2 Generazione API Key](#62-generazione-api-key)
      - [6.3 Setup Client-Side](#63-setup-client-side)
    - [7. Deploy Restante dei Microservizi](#7-deploy-restante-dei-microservizi)
  - [Comandi di Test: verifica del funzionamento + utility](#comandi-di-test-verifica-del-funzionamento--utility)
    - [1. Setup Variabili Ambiente (IP, PORT, KEY)](#1-setup-variabili-ambiente-ip-port-key)
    - [2. Verifica Autenticazione (Security Check)](#2-verifica-autenticazione-security-check)
    - [3. Inviare Eventi al Producer](#3-inviare-eventi-al-producer)
      - [3.1 Device Boot (Avvio Dispositivi)](#31-device-boot-avvio-dispositivi)
      - [3.2 Telemetry Data (Invio Dati Ambientali)](#32-telemetry-data-invio-dati-ambientali)
      - [3.3 Critical Alerts (Gestione Errori)](#33-critical-alerts-gestione-errori)
      - [3.4 Firmware Updates (Manutenzione)](#34-firmware-updates-manutenzione)
    - [4. Leggere le Metriche (Metrics-service)](#4-leggere-le-metriche-metrics-service)
    - [5. Database Clean-up (utility)](#5-database-clean-up-utility)
  - [Non-Functional Property (NFP)](#non-functional-property-nfp)
    - [Prerequisites](#prerequisites)
    - [1. **Security \& Secrets Management**](#1-security--secrets-management)
    - [2. **Resilience, Fault Tolerance \& High Availability**](#2-resilience-fault-tolerance--high-availability)
      - [2.1. Fault Tolerance: Consumer Failure (Buffering)](#21-fault-tolerance-consumer-failure-buffering)
      - [2.2. High Availability: Self-Healing del Producer](#22-high-availability-self-healing-del-producer)
    - [3. **Scalabilità \& Load Balancing (senza HPA)**](#3-scalabilità--load-balancing-senza-hpa)
    - [4. **Horizontal Pod Autoscaler (HPA)**](#4-horizontal-pod-autoscaler-hpa)
    - [5. **Kong Rate Limiting Policy (Optional)**](#5-kong-rate-limiting-policy-optional)


## Prerequisiti

* **Necessari**
  * **Docker Engine** (NON Docker Desktop). [Guida installazione Ubuntu](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository) 
  * **Minikube**
  * **kubectl**

* **Opzionali**
  * **Lens**
  * **k9s**
  
---
## Architettura e Funzionamento

Il sistema implementa un pattern **Event-Driven** con API Gateway per l'autenticazione.

### Flusso di Ingestione (Scrittura)
1.  **Client HTTP** (Sensore IoT): Invia una richiesta `POST /event/...` all'API Gateway (Kong) includendo l'header `apikey`.
2.  **Kong Gateway**: Verifica l'API Key.
    * **Key Valida**: La richiesta passa al Producer.
    * **Key Invalida**: Restituisce `401 Unauthorized`.
3.  **Producer**: Riceve il payload, aggiunge metadati e instrada il messaggio sul topic Kafka corretto:
    * `sensor-telemetry`: per dati ad alta frequenza (Boot, Telemetria, Firmware).
    * `sensor-alerts`: per errori critici (Allarmi).
4.  **Kafka**: Persiste i messaggi (il topic di telemetria usa compressione LZ4).
5.  **Consumer**: Legge da entrambi i topic, converte i timestamp e salva nella collezione Time Series di **MongoDB**.


### Flusso di Analisi (Lettura)
1.  **Client HTTP**: Invia una richiesta `GET /metrics/temperature/average-by-zone` a Kong.
2.  **Kong Gateway**: Esegue la validazione dell'API Key.
3.  **Metrics-service**: Riceve la richiesta, esegue query di aggregazione su MongoDB e restituisce le statistiche.

---

## Guida all'Installazione

**(Opzionale) Reset e Pulizia Ambiente:**
    ```bash
    minikube delete --all
    docker system prune -a -f
    ```

### 0. Setup Iniziale del Cluster

1.  **Avviare Minikube:**
    ```bash
    minikube start -p IoT-cluster
    minikube profile IoT-cluster  #imposta il profilo come default per comandi minikube (non necessita -p)
    minikube profile list
    minikube addons enable metrics-server -p IoT-cluster
    ```
    *(Se ricevi un errore, aggiungi il tuo utente al gruppo docker)*:
    ```bash
    sudo usermod -aG docker $USER && newgrp docker
    ```

2.  **Impostare l'ambiente Docker:**
    Per utilizzare il Docker daemon interno a Minikube (necessario per buildare le immagini che Kubernetes userà):
    ```bash
    eval $(minikube -p IoT-cluster docker-env)
    ```
    **ATTENZIONE:** Questo comando va eseguito in *ogni terminale* che userai per buildare le immagini Docker. Sostituire con il nome del profilo minikube in esecuzione

### 1. Creazione Namespace

<div style="margin-left: 40px;">

Creiamo i namespace per isolare i componenti:
```bash
kubectl create namespace kong
kubectl create namespace metrics
kubectl create namespace kafka
```
</div>

### 2\. Strimzi Kafka Operator

1. **Installiamo Strimzi** per gestire il cluster Kafka tramite Helm.
    ```bash
    helm repo add strimzi https://strimzi.io/charts/
    helm repo update
    helm install strimzi-cluster-operator strimzi/strimzi-kafka-operator -n kafka
    ```

2. **Deploy del Cluster Kafka** Per prima cosa, applichiamo i manifest che definiscono il Cluster, gli Utenti e i Topic di Kafka. Questo avvierà l'operator Strimzi, che creerà il cluster e genererà il secret `iot-sensor-cluster-cluster-ca-cert` contenente i certificati CA.
    ```bash
    kubectl apply -f ./K8s/kafka/kafka-cluster.yaml
    kubectl apply -f ./K8s/kafka/kafka-users.yaml
    kubectl apply -f ./K8s/kafka/kafka-topics.yaml
    ```

    > **Attendi che il cluster sia pronto:** affinché l'operator crei il cluster potrebbe volerci qualche minuto
    ```bash
    kubectl wait kafka/iot-sensor-cluster --for=condition=Ready --timeout=300s -n kafka
    ```
    
    Una volta terminato il comando precedente verifica che il secret `iot-sensor-cluster-cluster-ca-cert` sia stato creato con successo
    ```bash
    kubectl get secret iot-sensor-cluster-cluster-ca-cert -n kafka
    ```

    *Kafka è configurato (tramite i file YAML in `K8s/`) per usare TLS e autenticazione SCRAM-SHA-512.*

3. **Crea Secret per Kafka SSL:** Ora, creiamo il secret `kafka-ca-cert`. Questo comando legge il certificato CA dal secret generato da Strimzi (`iot-sensor-cluster-cluster-ca-cert`) e lo salva in un nuovo secret che i nostri pod (Producer e Consumer) useranno per comunicare via TLS con Kafka.

    ```bash
    kubectl create secret generic kafka-ca-cert -n kafka \
      --from-literal=ca.crt="$(kubectl get secret iot-sensor-cluster-cluster-ca-cert -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d)"
    ```

### 3\. MongoDB

<div style="margin-left: 40px;">

**Installiamo MongoDB** usando Helm.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install mongo-mongodb bitnami/mongodb --namespace kafka --version 18.1.1
```
>*Se l'installazione fallisce per errori di connessione, riprovare*

Attendiamo il compeltamento (Premi CTRL+C quando vedi Running)
```bash
kubectl get pods -n kafka -l app.kubernetes.io/name=mongodb -w
```

</div>

#### 3.1\. Configurazione Utente Applicativo e Time Series Collection

1.  **Recupera la password di root:**

    ```bash
    export MONGODB_ROOT_PASSWORD=$(kubectl get secret -n kafka mongo-mongodb -o jsonpath='{.data.mongodb-root-password}' | base64 -d)
    ```

    *(Annota la password generata, es: `A36NCeYzH4`)*

2.  **Accedi alla shell di Mongo:**

    ```bash
    kubectl exec -it deployment/mongo-mongodb -n kafka -- mongosh -u root -p $MONGODB_ROOT_PASSWORD --authenticationDatabase admin
    ```

3.  **Creazione utente**
    
    1.  Passa al database `iot_network`
        ```mongo
        use iot_network;
        ```
    2.  Crea l'utenza che verrà usata per accedere al DB
        ```mongo
        db.createUser({
          user: "db_user",
          pwd: "segreta",
          roles: [ { role: "readWrite", db: "iot_network" } ]
        });
        ```

4. **Crea la Time Series Collection per telemetria**
    ```mongo
    db.createCollection("sensor_data", {
      timeseries: {
        timeField: "timestamp",
        metaField: "device_id",
        granularity: "seconds"
      },
      expireAfterSeconds: 2592000  // 30 giorni auto-cleanup
    });
    ```

5.  **Controllare creazione:**

    ```mongo
    use iot_network;
    ```

    ```mongo
    db.getUsers()
    ```
    ```mongo
    //Verifica la creazione
    db.getCollectionInfos();
    ```

    Le applicazioni useranno questa stringa di connessione: `mongodb://db_user:segreta@mongo-mongodb.kafka.svc.cluster.local:27017/iot_network?authSource=iot_network`

#### 3.2\. Configurazione ConfigMap e Secret (per Producer Consumer e Metrics-service)

<div style="margin-left: 40px;">

Separiamo la configurazione (ConfigMap) dalle credenziali (Secret).

Utilizziamo Secret kubernetes invece delle password per permettere a Producer, Consumer e Metrics-service di connettersi a MongoDB.

```bash
# Applica le ConfigMap (Host, Port, DB Name)
kubectl apply -f ./K8s/mongodb-config.yaml

# Secret per namespace kafka (Producer e Consumer)
kubectl create secret generic mongo-creds -n kafka \
  --from-literal=MONGO_USER="db_user" \
  --from-literal=MONGO_PASSWORD="segreta"

# Secret per namespace metrics
kubectl create secret generic mongo-creds -n metrics \
  --from-literal=MONGO_USER="db_user" \
  --from-literal=MONGO_PASSWORD="segreta"
```
</div>


### 4\. Kong API Gateway

<div style="margin-left: 40px;">

**Installiamo Kong** e configuriamolo per monitorare i namespace corretti.

```bash
helm repo add kong https://charts.konghq.com
helm repo update
helm install kong kong/kong -n kong
```
</div>

1. **Aggiorniamo Kong** per fargli "vedere" gli ingress negli altri namespace
    ```bash
    helm upgrade kong kong/kong -n kong \
      --set ingressController.watchNamespaces="{kong,kafka,metrics}"
    ```
2. **Verifica installazione Kong:** controlla i servizi interni al cluster nel namespace 'kong':
    ```bash
    kubectl get svc -n kong
    ```
    > L'output dovrebbe essere simile a questo (la riga importante è `kong-kong-proxy`):

    ```text
    NAME                           TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
    kong-kong-manager              NodePort       10.109.18.217   <none>        8002:31545/TCP,8445:30670/TCP
    kong-kong-metrics              ClusterIP      10.101.88.235   <none>        10255/TCP,10254/TCP
    kong-kong-proxy                LoadBalancer   10.105.61.105   <pending>     80:31260/TCP,443:32030/TCP
    kong-kong-validation-webhook   ClusterIP      10.110.97.78    <none>        443/TCP
    ```
3. **Ottieni l'URL pubblico** per accedere a Kong dal tuo computer
    ```bash
    minikube service kong-kong-proxy -n kong --url
    ```

    > Questo è un comando specifico di Minikube che crea un tunnel di rete dal tuo computer al servizio `kong-kong-proxy` dentro il cluster. L'output stamperà gli URL che puoi usare per inviare richieste all'API Gateway (uno per HTTP e uno per HTTPS):

    ```text
    http://192.168.49.2:31260
    http://192.168.49.2:32030
    ```

### 5\. Microservizi (Producer, Consumer, Metrics)

Dobbiamo buildare le immagini Docker dei nostri microservizi Python.

1. **Esegui `eval $(minikube -p IoT-cluster  docker-env)` in questo terminale**
   
2. **Builda le immagini**

    ```bash
    docker build -t producer:latest ./Producer
    docker build -t consumer:latest ./Consumer
    docker build -t metrics-service:latest ./Metrics-service
    ```

    Per controllare che le immagini siano state create nell'ambiente Minikube:
    ```bash
    docker images
    ```

#### 5.1\. Aggiornamento Microservizi

<div style="margin-left: 40px;">

Se modifichi il codice (es. `app.py`), devi ricreare l'immagine e riavviare il deployment:

```bash
# Ricrea l'immagine (es. producer)
docker build -t producer:latest ./Producer

# Riavvia il deployment
kubectl rollout restart deployment/producer -n kafka
kubectl rollout restart deployment/consumer -n kafka
kubectl rollout restart deployment/metrics-service -n metrics
```

Per riavviare tutti i deployment in un namespace:

```bash
kubectl rollout restart deployment -n kafka
kubectl rollout restart deployment -n metrics
```
</div>

### 6\. Autenticazione: API Key
<div style="margin-left: 40px;">

L'obiettivo è proteggere gli endpoint esposti (`producer` e `metrics`) bloccando qualsiasi richiesta non autenticata (`401 Unauthorized`) e permettendo l'accesso (`200 OK`) solo se presente un'API Key valida nell'header `apikey`.

**Componenti utilizzati:**
  * 2x `KongPlugin` (uno per namespace: `kafka` e `metrics`) - tipo `key-auth`
  * 1x `KongConsumer` (identità logica "iot-devices")
  * 2x `Secret` Kubernetes (API Key per namespace `kafka` e `metrics`)

> **Nota di Produzione:** In questo progetto usiamo una **singola API Key condivisa** (`iot-sensor-key-prod-v1`) per semplicità didattica. In produzione, ogni dispositivo IoT dovrebbe avere la propria chiave univoca, generabile con `openssl rand -hex 32`.

#### 6.1 Configurazione Key-Auth
<div style="margin-left: 40px;">

Abilitiamo il plugin `key-auth` su Kong e creiamo l'identità del consumatore "iot-devices".

```bash
# Attiva il plugin per i namespace
kubectl apply -f ./K8s/auth-apikey/apikey-plugin-kafka.yaml
kubectl apply -f ./K8s/auth-apikey/apikey-plugin-metrics.yaml

# Crea il consumatore logico
kubectl apply -f ./K8s/auth-apikey/apikey-consumer.yaml
```
> Kong applica la sicurezza tramite plugin associati ai namespace o agli Ingress. Poiché abbiamo Ingress in namespace diversi, attiviamo il plugin `apikey` specificamente per ciascuno di essi.
</div>


#### 6.2 Generazione API Key
<div style="margin-left: 40px;">

Creiamo la chiave segreta e la associamo al consumatore.

```bash
# Crea il secret con la chiave
kubectl apply -f ./K8s/auth-apikey/apikey-credential.yaml

# Associa la credenziale al consumatore Kong
kubectl patch kongconsumer iot-devices -n kafka \
  --type=json \
  -p='[{"op": "add", "path": "/credentials", "value": ["iot-devices-apikey"]}]'
```
Poiché Kong condivide i consumer tra namespace ma non le credential, dobbiamo creare una seconda API Key secret per il namespace `metrics`:
```bash
kubectl apply -f ./K8s/auth-apikey/apikey-credential-metrics.yaml
```

Verifica:
```bash
kubectl get secret -A | grep iot-devices-apikey
```

Dovresti vedere **2 secret** (uno per kafka, uno per metrics).
</div>

#### 6.3 Setup Client-Side
<div style="margin-left: 40px;">

Esporta la chiave per usarla nei test:

```bash
export API_KEY="iot-sensor-key-prod-v1"
echo "API Key: $API_KEY"
```
</div>

### 7\. Deploy Restante dei Microservizi
<div style="margin-left: 40px;">

Ora che l'infrastruttura di base e la sicurezza sono configurate, possiamo deployare i restanti manifest (Deployment, Service, Ingress).
Gli Ingress (`producer-ingress` e `metrics-ingress`) sono già configurati con l'annotazione `konghq.com/plugins: key-auth`, quindi saranno protetti immediatamente al momento della creazione.

```bash
# Consumer (Backend worker, nessun Ingress)
kubectl apply -f ./K8s/micro-services/consumer-deployment.yaml

# Metrics Service (Backend + Ingress)
kubectl apply -f ./K8s/micro-services/metrics-deployment.yaml
kubectl apply -f ./K8s/micro-services/metrics-ingress.yaml

# Producer (Backend + Ingress)
kubectl apply -f ./K8s/micro-services/producer-deployment.yaml
kubectl apply -f ./K8s/micro-services/producer-ingress.yaml
```

>**Attenzione:** I file Ingress in K8s/micro-services/ sono configurati per l'IP **192.168.58.2**. Se `minikube ip` restituisce un valore diverso, aggiorna `producer-ingress.yaml` e `metrics-ingress.yaml` con il tuo IP:
>```yaml
># In producer-ingress.yaml e metrics-ingress.yaml, modifica:
>host: producer.TUO_IP.nip.io   # Esempio: producer.192.168.49.2.nip.io
>host: metrics.TUO_IP.nip.io    # Esempio: metrics.192.168.49.2.nip.io
>```

</div>

## Comandi di Test: verifica del funzionamento + utility
Utilizzeremo  il servizio `nip.io` per risolvere i sottodomini (`producer` e `metrics`) direttamente all'IP del cluster Minikube, permettendoci di testare gli Ingress basati su host. \
Utilizziamo `curl` per simulare il comportamento dei sensori e verificare il funzionamento della pipeline.

### 1\. Setup Variabili Ambiente (IP, PORT, KEY)
Prima di iniziare, esportiamo le variabili necessarie per non dover modificare manualmente ogni comando `curl`.

```bash
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

export API_KEY="iot-sensor-key-prod-v1"

echo "Target (IP:PORT): $IP:$PORT"
echo "API Key: $API_KEY"
```

### 2\. Verifica Autenticazione (Security Check)

Verifichiamo che il Gateway blocchi correttamente le richieste non autorizzate e accetti quelle valide.

**Scenario A: Accesso Negato (Senza API Key o con key errata)**

1. **Proviamo a contattare  `producer` senza credenziali.**
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "Content-Type: application/json" \
      -d '{"device_id": "hacker-device", "zone_id": "unknown"}'
    ```
    > **Risultato Atteso:** `HTTP/1.1 401 Unauthorized`

2. **Proviamo a contattare `metrics` senza credenziali.**
    ```bash
    curl -i http://metrics.$IP.nip.io:$PORT/metrics/boots
    ```
    > **Risultato Atteso:** `401 Unauthorized`

**Scenario B: Accesso Consentito (Con API Key)**
Riprova le stesse richiesta aggiungendo l'header `apikey` con la relativa API key

1. **Proviamo a contattare  `producer`**
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"device_id": "test-sensor", "zone_id": "lab", "firmware": "v1.0"}'
    ```
    > **Risultato Atteso:** `HTTP/1.1 200 OK`

2. **Proviamo a contattare `metrics`**
    ```bash
    curl -i  http://metrics.$IP.nip.io:$PORT/metrics/boots \
      -H "apikey: $API_KEY"
    ```
    > **Risultato Atteso:** `HTTP/1.1 200 OK`
   
  
### 3\. Inviare Eventi al Producer
Ora che abbiamo verificato l'accesso, popoliamo il sistema con diversi tipi di eventi per testare il flusso completo (Producer -\> Kafka -\> Consumer -\> MongoDB).

Queste richieste `curl` colpiscono l'host `producer.$IP.nip.io`, che Kong instrada al servizio `producer`.

**Monitoraggio Logs**: In un altro terminale, osserva il consumer che processa i dati:
  ```bash
  kubectl logs -l app=consumer -n kafka -f
  ```

#### 3.1 Device Boot (Avvio Dispositivi) 
Segnala che un sensore si è acceso ed è online.
```bash
# Sensore 1 (Magazzino A)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "firmware": "v1.0"}'

# Sensore 2 (Magazzino A)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "zone_id": "warehouse-A", "firmware": "v1.0"}'
```

#### 3.2 Telemetry Data (Invio Dati Ambientali)
Invio periodico di temperatura e umidità.
```bash
# Dati normali (Sensore 1)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "temperature": 24.5, "humidity": 45}'

# Picco di calore (Sensore 2)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "zone_id": "warehouse-A", "temperature": 32.0, "humidity": 30}'
```

#### 3.3 Critical Alerts (Gestione Errori)
Simulazione di un guasto hardware.

```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/alert \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "error_code": "CRITICAL_OVERHEAT", "severity": "high"}'
```

#### 3.4 Firmware Updates (Manutenzione)
```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/firmware_update \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "version_to": "v2.0"}'
```

### 4\. Leggere le Metriche (Metrics-service)
Interroghiamo il sistema per vedere i dati aggregati.

Queste richieste `curl` colpiscono l'host `metrics.$IP.nip.io`, che Kong instrada al servizio `metrics-service`.

```bash
# 1. Totale dispositivi avviati
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/boots | json_pp

# 2. Media temperature per zona
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/temperature/average-by-zone | json_pp

# 3. Conteggio allarmi critici
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/alerts | json_pp

# 4. Statistiche aggiornamenti Firmware
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/firmware | json_pp

# 5. Trend attività ultimi 7 giorni
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/activity/last7days | json_pp
```

### 5\. Database Clean-up (utility)
  
Recupero password admin dal secret di mongo
```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret --namespace kafka mongo-mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 -d)
```

Trova tutte le collezioni presenti in student_events e cancella il loro contenuto una per una.
```bash
kubectl exec -it deployment/mongo-mongodb -n kafka -- mongosh iot_network \
-u root -p $MONGODB_ROOT_PASSWORD \
--authenticationDatabase admin \
--eval "db.getCollectionNames().forEach(function(c){ db[c].deleteMany({}); print('Svuotata: ' + c); })"
```

Cicla su tutte le collezioni e usa printjson per mostrare i dati formattati.
```bash
kubectl exec -it deployment/mongo-mongodb -n kafka -- mongosh iot_network \
-u root -p $MONGODB_ROOT_PASSWORD \
--authenticationDatabase admin \
--eval "db.getCollectionNames().forEach(function(c){ print('\n--- Collezione: ' + c + ' ---'); printjson(db[c].find().toArray()); })"
```

## Non-Functional Property (NFP)

Questa sezione documenta la validazione delle proprietà non funzionali (NFP) dell'infrastruttura. \
L'obiettivo è certificare la `sicurezza`, la `resilienza, fault tolerance e HA`,  la `scalabilità e load balancing` tra cui l'`autoscaling basato su metriche` dell'architettura a microservizi su realizzata.

### Prerequisites 
Estrazione dinamica di IP e Porta del Gateway (Minikube)

```bash
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

export API_KEY="iot-sensor-key-prod-v1"
echo "Target (IP:PORT): $IP:$PORT"
echo "API Key: $API_KEY"
```

### 1\. **Security & Secrets Management**

**Obiettivo:** Verificare la cifratura del canale (TLS), l'autenticazione (SASL) e la protezione delle credenziali.

1.  **Verifica TLS (Data in Transit):**
    Controlla che la comunicazione col broker avvenga su canale cifrato.

    ```bash
    kubectl exec -it -n kafka iot-sensor-cluster-broker-0 -- \
      openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief </dev/null
    ```

    > **Expectation:** Output contenente `Protocol version: TLSv1.3` e Cipher Suite robusta (es. `TLS_AES_256_GCM_SHA384`).

2.  **Verifica SASL (Authentication):**
    Tenta una connessione senza credenziali per confermare che venga rifiutata, fallisce restituendo `No API key found in request` o `Unauthorized`.

    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "Content-Type: application/json" \
      -d '{"device_id": "unauth-sensor", "zone_id": "test"}'
    ```
    Viene rifiutata anche se si usa una chiave diversa da quelal registrata
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "apikey: bad-key" \
      -H "Content-Type: application/json" \
      -d '{"device_id": "test-sensor", "zone_id": "lab", "firmware": "v1.0"}'
    ```

3.  **Verifica Kubernetes Secrets/ConfigMap:** Verifica che le credenziali non siano in chiaro e che la configurazione sia separata.
    ```bash
    # Verifica Secret (credenziali cifrate)
    kubectl get secret -n kafka mongo-creds -o yaml | grep "MONGO_"

    # Verifica ConfigMap (configurazione in chiaro)
    kubectl get configmap -n kafka mongodb-config -o yaml | grep "MONGO_"
    ```

    > Expectation: 
    > * Nel Secret, i valori `MONGO_USER`e `MONGO_PASSWORD` sono in base64 (non leggibili direttamente).
    > * Nella ConfigMap, i valori `MONGO_HOST`, `MONGO_PORT`, ecc. sono in chiaro (OK, non sono sensibili)

### 2\. **Resilience, Fault Tolerance & High Availability**

#### 2.1\. Fault Tolerance: Consumer Failure (Buffering)

**Obiettivo:** Dimostrare che il sistema non perde dati in caso di crash dei componenti

Questo scenario simula il crash improvviso del Consumer mentre i dati continuano ad arrivare al Producer. Dimostra la capacità di Kafka di fungere da buffer persistente.

1. **Spegni il Consumer (Simulazione Crash)**
    Scaliamo il deployment a 0 per simulare un'interruzione totale del servizio di consumo.

    ```bash
    kubectl scale deploy/consumer -n kafka --replicas=0
    ```

2. **Invia eventi mentre il Consumer è offline**
    Questi messaggi non possono essere processati subito, ma verranno salvati nel topic Kafka.

    ```bash
    for i in {1..5}; do
      curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"device_id\":\"offline-sensor-$i\", \"zone_id\":\"buffer-test\", \"temperature\": 20.0, \"humidity\": 50.0}" >/dev/null
    done
    ```

3. **Riaccendi il Consumer (Recovery)**
    Riportiamo il deployment allo stato operativo.

    ```bash
    kubectl scale deploy/consumer -n kafka --replicas=1
    ```

4. **Verifica il processamento dei log**
    Osserva i log: dovresti vedere i messaggi inviati durante il "downtime" (quelli con ID `offline-sensor-*`) venire processati immediatamente al riavvio.

    ```bash
    kubectl logs -n kafka -l app=consumer -f --tail=20
    ```

> **Expectation:** Al riavvio, il Consumer processa immediatamente i messaggi `offline-sensor-*`. Nessuna perdita di dati.


#### 2.2\. High Availability: Self-Healing del Producer

**Obiettivo:** Dimostrare che il sistema ripristina autonomamente i pod interrotti garantendo High Availability (se replicas>=2), sopravvivendo quindi alla perdita di un nodo applicativo.

Questo test verifica la resilienza dell'infrastruttura simulando un crash improvviso (o un'eliminazione accidentale) di un Pod. L'obiettivo è dimostrare che Kubernetes rileva la discrepanza tra lo stato desiderato e quello attuale, avviando immediatamente una nuova istanza per ripristinare il servizio.

1. **Watcher sul producer**
    Prima di causare il guasto, identifichiamo il pod del Producer attivo e notiamo il suo `AGE` (tempo di attività).

     ```bash
    kubectl get pods -n kafka -l app=producer -w
    ```
    > Quando simuliamo il crash Kubernetes dovrebbe terminare il vecchio pod e crearne uno nuovo istantaneamente.

2. **Verifica Continuità del Servizio**
    Per dimostrare che il disservizio è minimo o nullo durante il self-healing, lanciare questo loop in un terminale separato **prima** di uccidere il pod (passo successivo).
    ```bash
    # Invia una richiesta ogni 0.5s per monitorare la disponibilità
    while true; do 
      curl -s -o /dev/null -w "%{http_code} " \
      http://producer.$IP.nip.io:$PORT/event/boot \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"device_id":"healing-check", "zone_id":"ha-test"}'
      sleep 0.5
    done
    ```
    > **Risultato atteso:** Vedrai una sequenza di codici `200`. Potresti vedere un breve momento di pausa o un singolo errore di connessione durante lo switch, ma il servizio tornerà subito a rispondere `200`.

3. **Simulazione del Guasto (Kill Pod)**
    Forziamo la cancellazione del pod attualmente in esecuzione. Questo simula un "crash" fatale dell'applicazione.

    ```bash
    # Elimina automaticamente il primo pod del producer trovato
    kubectl delete pod $(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}") -n kafka
    ```

    > **Expectation:**
    > 1.  Il vecchio pod entra in stato `Terminating`.
    > 2.  Un **nuovo pod** (con un nome diverso) appare immediatamente in stato `Pending` -\> `ContainerCreating` -\> `Running`.
    > 3.  L'operazione avviene senza intervento umano.

4. **NO-down-time**
    Se deployamo più di un producer e ne crasha uno, le richieste vengono instradate all'altro, evitando completamente downtime
    ```bash
    kubectl scale deploy/producer -n kafka --replicas=2
    ```

    

### 3\. **Scalabilità & Load Balancing (senza HPA)**

**Obiettivo:** Verificare che il traffico sia distribuito tra le repliche di producer e consumer

> **ATTENZIONE:** Assicurati che l'Horizontal Pod Autoscaler (HPA) **NON** sia attivo prima di eseguire questo test. Se hai già applicato `hpa.yaml`, eliminalo con `kubectl delete -f K8s/hpa.yaml` per evitare che Kubernetes interferisca con il ridimensionamento manuale.

Questo test simula uno scenario di alto carico per verificare due comportamenti critici simultaneamente: \
  **Ingress Load Balancing:** La distribuzione del traffico HTTP tra le repliche del Producer. \
  **Consumer Parallelism:** La capacità di parallelizzare la lettura dei messaggi Kafka sfruttando il partizionamento.


1. **Preparazione: Scaling dei Servizi**
    Scaliamo il **Producer** a 2 repliche (per testare il Round-Robin HTTP) e il **Consumer** a 3 repliche (per allinearsi alle 3 partizioni del topic Kafka e garantire il massimo parallelismo).

    ```bash
    # Scala il Producer (HTTP Layer)
    kubectl scale deploy/producer -n kafka --replicas=2

    # Scala il Consumer (Kafka Layer)
    kubectl scale deploy/consumer -n kafka --replicas=3

    # Attendi che i pod siano pronti
    kubectl get pods -n kafka -l "app in (producer, consumer)"
    ```

2. **Iniezione del Carico (Burst)**
    Eseguiamo un ciclo di 50 chiamate API rapide. L'alta frequenza costringerà il Service a distribuire il carico sui Producer, i quali invieranno messaggi a Kafka per essere consumati in parallelo.

    ```bash
    for i in {1..50}; do
      curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"device_id\":\"load-test-$i\", \"zone_id\":\"LB-test\", \"temperature\": 22.5, \"humidity\": 48.0}" >/dev/null
    done
    ```

3. **Validazione1: Producer & Ingress**
    Verifica che le richieste siano state distribuite tra i due pod del Producer.

    ```bash
    kubectl logs -n kafka -l app=producer --tail=50 --prefix=true | grep "load-test"
    ```

    > **Expectation:** Osservando i log, dovresti vedere che le richieste `load-test-*` sono state gestite alternativamente dai due pod diversi (es. *vv8cg/producer* e *bpn87/producer*), confermando che il carico è stato bilanciato dal Kong Ingress e dal producer-service.

4. **Validazione2: Consumer & Partizioni**
    Verifica che i messaggi siano stati processati da tutte e tre le repliche del Consumer.

    ```bash
    kubectl logs -n kafka -l app=consumer --tail=50 --prefix=true | grep "load-test"
    ```

    > **Expectation:** I log devono provenire da **tutti e 3 i pod** del Consumer. Questo conferma che ogni replica sta leggendo dalla sua partizione assegnata, massimizzando il throughput.


    > **Nota sull'HA:** Anche se questo test verifica le performance, dimostra indirettamente l'High Availability. Se un Producer fallisse, il traffico verrebbe natturalmente rediretto sull'altro, ugual situazione per il consumer

5. **Restore Replicas**
    Riportiamo sia il Producer che il Consumer a una singola replica.

    ```bash
    kubectl scale deployment producer -n kafka --replicas=1
    kubectl scale deployment consumer -n kafka --replicas=1
    ```

    > **Expectation:** Kubernetes terminerà i pod in eccesso (stato `Terminating`), liberando CPU e RAM sul cluster, mentre il servizio rimane attivo con le repliche superstiti.

### 4\. **Horizontal Pod Autoscaler (HPA)**

**Obiettivo:** Verificare che le repliche dei pod consumer e poducer aumentano/diminusicono inbase al carico di lavoro, gestito autonomamente da HPA

1.  **Setup Iniziale:** Deploy della configurazione per HPA
    ```bash
    kubectl apply -f ./K8s/hpa.yaml
    ```

    Comandi per controllare che sia effettivamente deployato e i relativi valori
    ```bash
    kubectl get hpa -n kafka
    kubectl describe hpa producer-hpa -n kafka | head -n 15
    ```

2.  **HPA Trigger (Stress Test):**
    Genera carico sufficiente per saturare la soglia CPU definita nell'HPA.

    ```bash
    for i in {1..5000}; do
      curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
        -H "apikey: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"stress-sensor-$i\", \"zone_id\":\"HPA-test\", \"temperature\": 50.0, \"humidity\": 10.0}" \
        > /dev/null
    done
    ```

3.  **Monitoraggio Scaling:**
    ```bash
    kubectl get hpa -n kafka -w
    ```

    > **Expectation:** Il numero di repliche (`REPLICAS`) aumenta automaticamente (es. da 1 a 4) al salire della CPU target.

4. **Elasticità & Scale Down**
Dopo aver testato i picchi di carico, è fondamentale dimostrare l'**elasticità** inversa del sistema: la capacità di rilasciare risorse quando non sono più necessarie (*scale down*), riportando il cluster allo stato operativo standard; gestito automaticamente da HPA.
   
5.  **Restore:**
Rimozione della configurazione HPA dal cluster
    ```bash
    kubectl delete -f K8s/hpa.yaml
    ```

### 5\. **Kong Rate Limiting Policy (Optional)**

**Obiettivo:** Verificare la protezione dell'API Gateway contro attacchi flood.

Definiamo una risorsa `KongPlugin` che impone un limite di **5 richieste al secondo** per client. Questo protegge il servizio da sovraccarichi o attacchi DoS (Denial of Service).

1. **Applica il plugin al cluster**
    Usa questo comando per creare l'oggetto Kubernetes direttamente da riga di comando.

    ```bash
    cat <<'YAML' | kubectl apply -f -
    apiVersion: configuration.konghq.com/v1
    kind: KongPlugin
    metadata:
      name: global-rate-limit
      namespace: kafka
    config:
      second: 5
      policy: local
    plugin: rate-limiting
    YAML
    ```
2. **Attivazione plugin Rate Limiting su Kong (5 req/sec)**
    ```bash
    kubectl patch ingress producer-ingress -n kafka \
    -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth, global-rate-limit"}}}'
    ```
3. **Esegui il Flood Test**
    ```bash
    for i in {1..20}; do
      curl -s -o /dev/null -w "%{http_code}\n" \
        -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
        -H "apikey: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"flood-$i\", \"zone_id\":\"DoS-test\", \"temperature\": 0, \"humidity\": 0}"
    done
    ```
    > **Expectation:** Dopo le prime richieste (codice `200`), si ricevono risposte `429 Too Many Requests`.

1. **Rimozione configurazione**
    ```bash
    kubectl delete kongplugin -n kafka global-rate-limit --ignore-not-found
    
    # lascio solo il plugin per autenticazione
    kubectl patch ingress producer-ingress -n kafka \
    -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}'
    ```

    > **Expectation:** Si ottengono solo risposte con codice `200` data l'assenza del rate-limiting.