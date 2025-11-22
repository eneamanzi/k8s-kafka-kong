# Progetto Kubernetes per il corso CCT

Questo repository contiene il progetto per il corso di *Cloud Computing Technologies (CCT)*. L'obiettivo è implementare un'architettura a microservizi su Kubernetes che gestisca eventi tramite un flusso di dati asincrono (Kafka) e un database (MongoDB), il tutto esposto tramite un API Gateway (Kong).

L'architettura include:
* **Kong**: API Gateway per l'esposizione dei servizi.
* **Producer**: Microservizio che riceve dati via API e li pubblica su un topic Kafka.
* **Kafka (Strimzi)**: Message broker per la comunicazione asincrona.
* **Consumer**: Microservizio che consuma eventi da Kafka e li salva su MongoDB.
* **MongoDB**: Database per la persistenza dei dati.
* **Metrics-service**: Microservizio che espone metriche calcolate leggendo da MongoDB.

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
      - [3.1. Configurazione Utente Applicativo](#31-configurazione-utente-applicativo)
    - [4. Kong API Gateway](#4-kong-api-gateway)
    - [5. Microservizi (Producer, Consumer, Metrics)](#5-microservizi-producer-consumer-metrics)
      - [5.1. Aggiornamento Microservizi](#51-aggiornamento-microservizi)
    - [6. Creazione Secret per Producer Consumer e Metrics-service](#6-creazione-secret-per-producer-consumer-e-metrics-service)
    - [7. Autenticazione JWT](#7-autenticazione-jwt)
      - [7.1. Configurazione JWT: Kong Consumer \& Credentials](#71-configurazione-jwt-kong-consumer--credentials)
      - [7.2. Attivazione Plugin di Sicurezza](#72-attivazione-plugin-di-sicurezza)
      - [7.3. Generazione Token di Accesso (Client-Side)](#73-generazione-token-di-accesso-client-side)
    - [8. Deploy Restante dei Microservizi](#8-deploy-restante-dei-microservizi)
  - [Comandi di Test: verifica del funzionamento + utility](#comandi-di-test-verifica-del-funzionamento--utility)
    - [1. Setup Variabili Ambiente (IP, PORT, TOKEN)](#1-setup-variabili-ambiente-ip-port-token)
    - [2. Verifica Autenticazione (Security Check)](#2-verifica-autenticazione-security-check)
    - [3. Inviare Eventi al Producer](#3-inviare-eventi-al-producer)
      - [3.1 Login Utenti](#31-login-utenti)
      - [3.2 Risultati Quiz](#32-risultati-quiz)
      - [3.3 Download Materiali](#33-download-materiali)
      - [3.4 Prenotazione Esami](#34-prenotazione-esami)
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
    - [6. Verification \& Success Criteria (Final Checklist)](#6-verification--success-criteria-final-checklist)


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
1.  **Client HTTP**: Invia una richiesta `POST /event/...` all'API Gateway (Kong).
2.  **Kong Gateway**: Intercetta la richiesta e verifica il token JWT nell'header `Authorization`.
    * **Token Valido**: La richiesta viene inoltrata al servizio **Producer**.
    * **Token Invalido/Assente**: Kong restituisce immediatamente `401 Unauthorized`.
3.  **Producer**: Riceve il payload JSON, aggiunge metadati (UUID, timestamp) e pubblica il messaggio sul topic `student-events` di Kafka.
4.  **Kafka**: Persiste il messaggio in modo distribuito e replicato.
5.  **Consumer**: Legge il messaggio dal topic e salva il documento nella collezione `events` di **MongoDB**.

### Flusso di Analisi (Lettura)
1.  **Client HTTP**: Invia una richiesta `GET /metrics/...` a Kong.
2.  **Kong Gateway**: Esegue la validazione JWT.
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
    minikube start
    ```
    *(Se ricevi un errore, aggiungi il tuo utente al gruppo docker)*:
    ```bash
    sudo usermod -aG docker $USER && newgrp docker
    ```

2.  **Impostare l'ambiente Docker:**
    Per utilizzare il Docker daemon interno a Minikube (necessario per buildare le immagini che Kubernetes userà):
    ```bash
    eval $(minikube docker-env)
    ```
    **ATTENZIONE:** Questo comando va eseguito in *ogni terminale* che userai per buildare le immagini Docker.

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

2. **Deploy del Cluster Kafka** Per prima cosa, applichiamo i manifest che definiscono il Cluster, gli Utenti e i Topic di Kafka. Questo avvierà l'operator Strimzi, che creerà il cluster e genererà il secret `uni-it-cluster-cluster-ca-cert` contenente i certificati CA.
    ```bash
    kubectl apply -f ./K8s/kafka-cluster.yaml
    kubectl apply -f ./K8s/kafka-users.yaml
    kubectl apply -f ./K8s/kafka-topic.yaml
    ```

    > **Attendi che il cluster sia pronto:** affinché l'operator crei il cluster potrebbe volerci qualche minuto
    ```bash
    kubectl wait kafka/uni-it-cluster --for=condition=Ready --timeout=300s -n kafka
    ```
    Una volta terminato il comando precedente verifica che il secret `uni-it-cluster-cluster-ca-cert` sia stato creato con successo
    ```bash
    kubectl get secret uni-it-cluster-cluster-ca-cert -n kafka
    ```

    *Kafka è configurato (tramite i file YAML in `K8s/`) per usare TLS e autenticazione SCRAM-SHA-512.*

3. **Crea Secret per Kafka SSL:** Ora, creiamo il secret `kafka-ca-cert`. Questo comando legge il certificato CA dal secret generato da Strimzi (`uni-it-cluster-cluster-ca-cert`) e lo salva in un nuovo secret che i nostri pod (Producer e Consumer) useranno per comunicare via TLS con Kafka.

    ```bash
    kubectl create secret generic kafka-ca-cert -n kafka \
      --from-literal=ca.crt="$(kubectl get secret uni-it-cluster-cluster-ca-cert -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d)"
    ```

### 3\. MongoDB

<div style="margin-left: 40px;">

**Installiamo MongoDB** usando Helm.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install mongo-mongodb bitnami/mongodb --namespace kafka --version 18.1.1
```
>*Se l'installazione fallisce per errori di connessione, riprovare*

</div>

#### 3.1\. Configurazione Utente Applicativo

1.  **Recupera la password di root:**

    ```bash
    kubectl get secret -n kafka mongo-mongodb -o jsonpath='{.data.mongodb-root-password}' | base64 -d
    ```

    *(Annota la password generata, es: `A36NCeYzH4`)*

2.  **Accedi al pod di Mongo:**

    ```bash
    kubectl exec -it -n kafka $(kubectl get pods -n kafka -l app.kubernetes.io/name=mongodb -o jsonpath='{.items[0].metadata.name}') -- bash
    ```

3.  **Avvia la shell Mongo e crea l'utente:**
    Sostituisci `<PASSWORD>` con quella recuperata al punto 1.

    ```bash
    mongosh -u root -p <PASSWORD> --authenticationDatabase admin
    ```

4.  **Nel prompt di Mongo, esegui:**
    
    1.  Passa al database `student_events`
        ```mongo
        use student_events;
        ```
    2.  Crea l'utenza che verrà usata per accedere al DB
        ```mongo
        db.createUser({
          user: "appuser",
          pwd: "appuserpass",
          roles: [ { role: "readWrite", db: "student_events" } ]
        });
        ```
5.  **Controllare creazione:**

    ```mongo
    use student_events;
    ```

    ```mongo
    db.getUsers()
    ```

Le applicazioni useranno questa stringa di connessione: `mongodb://appuser:appuserpass@mongo-mongodb.kafka.svc.cluster.local:27017/student_events?authSource=student_events`

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

1. **Esegui `eval $(minikube docker-env)` in questo terminale**
   
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
```

Per riavviare tutti i deployment in un namespace:

```bash
kubectl rollout restart deployment -n kafka
kubectl rollout restart deployment -n metrics
```
</div>

### 6\. Creazione Secret per Producer Consumer e Metrics-service

<div style="margin-left: 40px;">

Utilizziamo Secret kubernetes invece delle password per permettere a Producer, Consumer e Metrics-service di connettersi a MongoDB.
Il `MONGO_URI ` è stato ottenuto alla fine del configurazione di MongoDB ([3.1 Configurazione Utente Applicativo](#31-configurazione-utente-applicativo)).


```bash
MONGO_URI=mongodb://appuser:appuserpass@mongo-mongodb.kafka.svc.cluster.local:27017/student_events?authSource=student_events

kubectl create secret generic mongo-creds -n kafka --from-literal=MONGO_URI="$MONGO_URI" 

kubectl create secret generic mongo-creds -n metrics --from-literal=MONGO_URI="$MONGO_URI"
```
</div>


### 7\. Autenticazione JWT
<div style="margin-left: 40px;">

L'obiettivo è proteggere gli endpoint esposti (`producer` e `metrics`) bloccando qualsiasi richiesta non autenticata (`401 Unauthorized`) e permettendo l'accesso (`200 OK`) solo se presente un token valido firmato con algoritmo HS256.

**Componenti utilizzati:**

  * 2x `KongPlugin` (uno per namespace: `kafka` e `metrics`)
  * 1x `KongConsumer` (identità logica del client)
  * 1x `Secret` Kubernetes (credenziali JWT dichiarative, senza uso di Admin API)
</div>

#### 7.1\. Configurazione JWT: Kong Consumer & Credentials
<div style="margin-left: 40px;">

Prima di esporre i servizi, configuriamo l'autenticazione. Creiamo l'identità del "consumatore" (è SOLO un oggetto per Kong, NON un utente reale. Serve per collegare una credential JWT ad un “nome”) e le credenziali JWT necessarie per validare i token.

> **Nota:** Questo passaggio crea un `KongConsumer` e un `Secret` Kubernetes contenente la chiave condivisa (HS256) per la firma dei token.

```bash
kubectl apply -f ./K8s/jwt-consumer.yaml

kubectl apply -f ./K8s/jwt-credential.yaml
```
</div>

#### 7.2\. Attivazione Plugin di Sicurezza
<div style="margin-left: 40px;">

Kong applica la sicurezza tramite plugin associati ai namespace o agli Ingress. Poiché abbiamo Ingress in namespace diversi, attiviamo il plugin `jwt` specificamente per ciascuno di essi.

```bash
kubectl apply -f ./K8s/jwt-plugin-kafka.yaml

kubectl apply -f ./K8s/jwt-plugin-metrics.yaml
```
</div>

#### 7.3\. Generazione Token di Accesso (Client-Side)
<div style="margin-left: 40px;">

Qualsiasi richiesta effettuata senza un token valido riceverà un errore `401 Unauthorized`: per interagire con le API, è necessario generare un token JWT firmato con la stessa chiave segreta caricata al punto [7.1. Configurazione JWT: Kong Consumer & Credentials](#71-configurazione-jwt-kong-consumer--credentials)

**Genera il token:** Utilizza lo script Python incluso nella root del progetto (richiede la libreria `pyjwt`) per generare un token e salvarlo in una variabile d'ambiente:

```bash
export TOKEN=$(python3 gen_jwt.py)
echo "Token generato: $TOKEN"
```
> **Nota di Sicurezza:** Lo script `gen-jwt.py` contiene il segreto condiviso hardcodato per semplicità dimostrativa. In un ambiente di produzione, questa chiave dovrebbe essere iniettata tramite variabili d'ambiente sicure o sistemi di gestione dei segreti (es. Vault).
</div>

### 8\. Deploy Restante dei Microservizi
<div style="margin-left: 40px;">

Ora che l'infrastruttura di base e la sicurezza sono configurate, possiamo deployare i restanti manifest (Deployment, Service, Ingress).
Gli Ingress (`producer-ingress` e `metrics-ingress`) sono già configurati con l'annotazione `konghq.com/plugins: jwt-auth`, quindi saranno protetti immediatamente al momento della creazione.

```bash
kubectl apply -f ./K8s
```

*(Questo comando applicherà tutti i file YAML nella cartella K8s, aggiornando quelli già esistenti e creando quelli nuovi).*

>**Attenzione:** I file Ingress in K8s/ sono configurati per l'IP 192.168.49.2. Se minikube ip restituisce un valore diverso, modifica `producer-ingress` e `metrics-ingress` con il tuo IP corretto.
</div>

## Comandi di Test: verifica del funzionamento + utility
Utilizzeremo `curl` e il servizio `nip.io` per risolvere i sottodomini (`producer` e `metrics`) direttamente all'IP del cluster Minikube, permettendoci di testare gli Ingress basati su host.

### 1\. Setup Variabili Ambiente (IP, PORT, TOKEN)
Prima di iniziare, esportiamo le variabili necessarie per non dover modificare manualmente ogni comando `curl`.

```bash
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

export TOKEN=$(python3 gen_jwt.py)

echo "Target (IP:PORT): $IP:$PORT"
echo "Token:  $TOKEN"
```

### 2\. Verifica Autenticazione (Security Check)

Verifichiamo che il Gateway blocchi correttamente le richieste non autorizzate e accetti quelle valide.

**Scenario A: Accesso Negato (Senza Token)**

1. **Proviamo a contattare  `producer` senza credenziali.**
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/login \
      -H "Content-Type: application/json" \
      -d '{"user_id":"unauthorized-user"}'
    ```
    > **Risultato Atteso:** `HTTP/1.1 401 Unauthorized`

2. **Proviamo a contattare `metrics` senza credenziali.**
    ```bash
    curl -i http://metrics.$IP.nip.io:$PORT/metrics
    ```
    > **Risultato Atteso:** `401 Unauthorized`

**Scenario B: Accesso Consentito (Con Token)**
Riprova le stesse richiesta aggiungendo l'header `Authorization` con il relativo TOKEN.

1. **Proviamo a contattare  `producer`**
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/login \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"user_id":"auth-user"}'
    ```
    > **Risultato Atteso:** `HTTP/1.1 200 OK`

2. **Proviamo a contattare `metrics`**
    ```bash
    curl -i http://metrics.$IP.nip.io:$PORT/metrics/logins \
      -H "Authorization: Bearer $TOKEN"
    ```
    > **Risultato Atteso:** `HTTP/1.1 200 OK`
   
  
### 3\. Inviare Eventi al Producer
Ora che abbiamo verificato l'accesso, popoliamo il sistema con diversi tipi di eventi per testare il flusso completo (Producer -\> Kafka -\> Consumer -\> MongoDB).

Queste richieste `curl` colpiscono l'host `producer.$IP.nip.io`, che Kong instrada al servizio `producer`.

**Stampare i log** per vedere se il consumer riceve effettivamente i dati mandati
  ```bash
  kubectl logs -l app=consumer -n kafka -f
  ```

#### 3.1 Login Utenti
```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/login \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "alice"}'

curl -i -X POST http://producer.$IP.nip.io:$PORT/event/login \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "bob"}'

curl -i -X POST http://producer.$IP.nip.io:$PORT/event/login \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "charlie"}'
```

#### 3.2 Risultati Quiz

```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/quiz \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "alice", "quiz_id": "math101", "score": 24, "course_id": "math"}'

curl -i -X POST http://producer.$IP.nip.io:$PORT/event/quiz \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "bob", "quiz_id": "math101", "score": 15, "course_id": "math"}'

curl -i -X POST http://producer.$IP.nip.io:$PORT/event/quiz \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "charlie", "quiz_id": "phys101", "score": 28, "course_id": "physics"}'
```

#### 3.3 Download Materiali

```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/download \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "alice", "materiale_id": "pdf1", "course_id": "math"}'

curl -i -X POST http://producer.$IP.nip.io:$PORT/event/download \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "bob", "materiale_id": "pdf1", "course_id": "math"}'

curl -i -X POST http://producer.$IP.nip.io:$PORT/event/download \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "charlie", "materiale_id": "pdf2", "course_id": "physics"}'
```

#### 3.4 Prenotazione Esami

```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/exam \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "alice", "esame_id": "math1", "course_id": "math"}'

curl -i -X POST http://producer.$IP.nip.io:$PORT/event/exam \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "bob", "esame_id": "phys1", "course_id": "physics"}'
```
### 4\. Leggere le Metriche (Metrics-service)
Infine, interroghiamo il servizio di metriche per vedere l'aggregazione dei dati salvati su MongoDB.

Queste richieste `curl` colpiscono l'host `metrics.$IP.nip.io`, che Kong instrada al servizio `metrics-service`.

```bash
curl -i -H "Authorization: Bearer $TOKEN" http://metrics.$IP.nip.io:$PORT/metrics/logins

curl -i -H "Authorization: Bearer $TOKEN" http://metrics.$IP.nip.io:$PORT/metrics/quiz/success-rate

curl -i -H "Authorization: Bearer $TOKEN" http://metrics.$IP.nip.io:$PORT/metrics/quiz/average-score

curl -i -H "Authorization: Bearer $TOKEN" http://metrics.$IP.nip.io:$PORT/metrics/downloads

curl -i -H "Authorization: Bearer $TOKEN" http://metrics.$IP.nip.io:$PORT/metrics/exams
```
### 5\. Database Clean-up (utility)
  
Recupero password admin dal secret di mongo
```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret --namespace kafka mongo-mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 -d)
```

Trova tutte le collezioni presenti in student_events e cancella il loro contenuto una per una.
```bash
kubectl exec -it deployment/mongo-mongodb -n kafka -- mongosh student_events \
-u root -p $MONGODB_ROOT_PASSWORD \
--authenticationDatabase admin \
--eval "db.getCollectionNames().forEach(function(c){ db[c].deleteMany({}); print('Svuotata: ' + c); })"
```

Cicla su tutte le collezioni e usa printjson per mostrare i dati formattati.
```bash
kubectl exec -it deployment/mongo-mongodb -n kafka -- mongosh student_events \
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

export TOKEN=$(python3 gen_jwt.py)

echo "Target (IP:PORT): $IP:$PORT"
echo "Token:  $TOKEN"
```

### 1\. **Security & Secrets Management**

**Obiettivo:** Verificare la cifratura del canale (TLS), l'autenticazione (SASL) e la protezione delle credenziali.

1.  **Verifica TLS (Data in Transit):**
    Controlla che la comunicazione col broker avvenga su canale cifrato.

    ```bash
    kubectl exec -it -n kafka uni-it-cluster-broker-0 -- \
      openssl s_client -connect uni-it-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief </dev/null
    ```

    > **Expectation:** Output contenente `Protocol version: TLSv1.3` e Cipher Suite robusta (es. `TLS_AES_256_GCM_SHA384`).

2.  **Verifica SASL (Authentication):**
    Tenta una connessione senza credenziali per confermare che venga rifiutata, fallisce restituendo `Unauthorized`.

    ```bash
    curl -X POST http://producer.$IP.nip.io:$PORT/event/login \
      -H "Content-Type: application/json" \
      -d '{"user_id": "test_unauthorized_user"}'
    ```

    > **Expectation:** message: `Unauthorized`.

3.  **Verifica Kubernetes Secrets:**
    Conferma che nessuna password sia in chiaro nei manifest dei Deployment.

    ```bash
    kubectl get deploy -n kafka producer -o yaml | grep -n "MONGO_URI\|SASL_PASSWORD\|value:"
    ```

    > **Expectation:** Nessuna credenziale visibile. I valori vengoo letti attraverso `valueFrom.secretKeyRef`.

    Per ottenere i secret generati:
    ```bash
    kubectl get secret -n kafka mongo-creds -o yaml | head -n 20
    kubectl get secret -n metrics mongo-creds -o yaml | head -n 20
    ```

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
      curl -s -X POST http://producer.$IP.nip.io:$PORT/event/login \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"offline-msg-$i\"}" >/dev/null
    done
    ```

3. **Riaccendi il Consumer (Recovery)**
    Riportiamo il deployment allo stato operativo.

    ```bash
    kubectl scale deploy/consumer -n kafka --replicas=1
    ```

4. **Verifica il processamento dei log**
    Osserva i log: dovresti vedere i messaggi inviati durante il "downtime" (quelli con ID `offline-msg-*`) venire processati immediatamente al riavvio.

    ```bash
    kubectl logs -n kafka -l app=consumer -f --tail=20
    ```

> **Expectation:** Al riavvio, il Consumer processa immediatamente i messaggi `offline-msg-*`. Nessuna perdita di dati.


#### 2.2\. High Availability: Self-Healing del Producer

**Obiettivo:** Dimostrare che il sistema ripristina autonomamente i pod interrotti garantendo High Availability (se replicas>=2), sopravvivendo quindi alla perdita di un nodo applicativo.

Questo test verifica la resilienza dell'infrastruttura simulando un crash improvviso (o un'eliminazione accidentale) di un Pod. L'obiettivo è dimostrare che Kubernetes rileva la discrepanza tra lo stato desiderato e quello attuale, avviando immediatamente una nuova istanza per ripristinare il servizio.

1. **Verifica stato iniziale**
    Prima di causare il guasto, identifichiamo il pod del Producer attivo e notiamo il suo `AGE` (tempo di attività).

    ```bash
    kubectl get pods -n kafka -l app=producer
    ```

    > *Nota:* Prendi nota del nome del pod (es. `producer-5d6f8-...`) e del fatto che è attivo da tempo (es. `5d`).

2. **Verifica del Ripristino Automatico**
    Osserviamo immediatamente lo stato dei pod. Kubernetes dovrebbe terminare il vecchio pod e crearne uno nuovo istantaneamente.

    ```bash
    kubectl get pods -n kafka -l app=producer -w
    ```

    *(Premi `CTRL+C` per uscire quando vedi il nuovo pod in Running)*

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

4. **Test Opzionale: Verifica Continuità del Servizio**
    Per dimostrare che il disservizio è minimo o nullo durante il self-healing, puoi lanciare questo loop in un terminale separato **prima** di uccidere il pod (passo 2).

    ```bash
    # Invia una richiesta ogni 0.5s per monitorare la disponibilità
    while true; do 
      curl -s -o /dev/null -w "%{http_code} " \
      http://producer.$IP.nip.io:$PORT/event/login \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"user_id":"healing-check"}'
      sleep 0.5
    done
    ```
    > **Risultato atteso:** Vedrai una sequenza di codici `200`. Potresti vedere un breve momento di pausa o un singolo errore di connessione durante lo switch, ma il servizio tornerà subito a rispondere `200`.

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
      curl -s -X POST http://producer.$IP.nip.io:$PORT/event/login \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"load-test-$i\"}" >/dev/null
    done
    ```

3. **Validazione1: Producer & Ingress**
    Verifica che le richieste siano state distribuite tra i due pod del Producer.

    ```bash
    kubectl logs -n kafka -l app=producer --tail=50 --prefix=true | grep "load-test"
    ```

    > **Expectation:** Osservando i log, dovresti vedere che le richieste `lb-test-*` sono state gestite alternativamente dai due pod diversi (es. *vv8cg/producer* e *bpn87/producer*), confermando che il carico è stato bilanciato dal Kong Ingress e dal producer-service.

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
    kubectl apply -f K8s/hpa.yaml
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
    curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/login" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"hpa-stress-$i\"}" \
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
    -p '{"metadata":{"annotations":{"konghq.com/plugins":"jwt-auth, global-rate-limit"}}}'
    ```
3. **Esegui il Flood Test**
    ```bash
    for i in {1..20}; do
      curl -s -o /dev/null -w "%{http_code}\n" \
      -X POST http://producer.$IP.nip.io:$PORT/event/login \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"flood-$i\"}"
    done
    ```
    > **Expectation:** Dopo le prime richieste (codice `200`), si ricevono risposte `429 Too Many Requests`.

1. **Rimozione configurazione**
    ```bash
    kubectl delete kongplugin -n kafka global-rate-limit --ignore-not-found
    
    # lascio solo il plugin per autenticazione
    kubectl patch ingress producer-ingress -n kafka \
    -p '{"metadata":{"annotations":{"konghq.com/plugins":"jwt-auth"}}}'
    ```

    > **Expectation:** Si ottengono solo risposte con codice `200` data l'assenza del rate-limiting.



### 6\. Verification & Success Criteria (Final Checklist)

Questa sezione riassume i criteri di accettazione per considerare il sistema **pronto per la produzione**. 

| Area | Controllo (Action) | Comando di Verifica Rapida | Success Criteria (Output Atteso) |
| :--- | :--- | :--- | :--- |
| **Security** | **TLS Encryption** | `kubectl exec -it -n kafka uni-it-cluster-broker-0 -- openssl s_client -connect uni-it-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief </dev/null` | Protocollo: `TLSv1.3` (o v1.2) <br> Cipher Suite: Elevata (es. `TLS_AES_256...`) |
| **Security** | **Auth Reject** | `curl -X POST http://producer.$IP.nip.io:$PORT/event/login -H "Content-Type: application/json" -d '{"user_id": "test_unauthorized_user"}'`| Status Code: `401 Unauthorized` |
| **Availability** | **Pod Status** | `kubectl get pods -A -l "app in (producer, consumer, metrics-service)"` | Tutti i Pod in stato `Running`. |
| **Reliability** | **No Data Loss** | `kubectl logs -n kafka -l app=consumer --tail=100 \| grep "offline-msg"` | Presenza dei log per i messaggi inviati durante il downtime (es. `offline-msg-*`). |
| **Scalability** | **HPA Trigger** | `kubectl get hpa -n kafka` | Colonna `REPLICAS` > `MINPODS` durante il carico. <br> Colonna `TARGETS` mostra % > 50%. |