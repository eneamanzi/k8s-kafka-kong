[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**English version** | [Versione italiana](README.md)
# Kubernetes Project for the CCT Course

The goal is to implement a microservices architecture on Kubernetes for monitoring an IoT sensor network. The system handles high-frequency telemetry streams via **Kafka** (on priority-differentiated topics), persists data in **MongoDB** (using optimized Time Series collections), and exposes aggregated metrics through **Kong**. Device authentication is handled via **API Key**.

The architecture includes:

  * **Kong**: API Gateway for secure (API Key) exposure of sensor endpoints.
  * **Producer**: Ingestion microservice that receives data from devices (Boot, Telemetry, Alarms) and publishes it to Kafka.
  * **Kafka (Strimzi)**: Message broker for buffering and decoupling the data stream (`sensor-stream`).
  * **Consumer**: Worker that processes raw events and saves them in a structured format to MongoDB.
  * **MongoDB**: NoSQL database for persistence (`iot_network`).
  * **Metrics-service**: Analytics service that calculates averages (e.g. temperature by zone) and operational statistics.

**Key Architectural Choices**
This project implements best practices specific to IoT systems:
   - **API Key**: Appropriate for devices with limited computational capabilities
   - **Separate Kafka topics by priority**: High-volume telemetry vs critical alarms
   - **MongoDB Time Series**: Native optimization for time-based data
   - **ConfigMap/Secret separation**: Security and portability
   - **Hybrid Compression Strategy**:
     - **Transport Layer (Kafka)**: Use of **LZ4** on the telemetry topic to maximize throughput and reduce network traffic
     - **Storage Layer (MongoDB)**: Leveraging native **Zstd** compression of Time Series Collections to minimize disk usage for historical data.
  
## Table of Contents
- [Kubernetes Project for the CCT Course](#kubernetes-project-for-the-cct-course)
  - [Table of Contents](#table-of-contents)
  - [Prerequisites](#prerequisites)
  - [Architecture and Operation](#architecture-and-operation)
    - [Ingestion Flow (Write)](#ingestion-flow-write)
    - [Analytics Flow (Read)](#analytics-flow-read)
  - [Installation Guide](#installation-guide)
    - [0. Initial Cluster Setup](#0-initial-cluster-setup)
    - [1. Namespace Creation](#1-namespace-creation)
    - [2. Strimzi Kafka Operator](#2-strimzi-kafka-operator)
    - [3. MongoDB](#3-mongodb)
      - [3.1. Application User Configuration and Time Series Collection](#31-application-user-configuration-and-time-series-collection)
      - [3.2. ConfigMap and Secret Configuration (for Producer, Consumer and Metrics-service)](#32-configmap-and-secret-configuration-for-producer-consumer-and-metrics-service)
    - [4. Kong API Gateway](#4-kong-api-gateway)
    - [5. Microservices (Producer, Consumer, Metrics)](#5-microservices-producer-consumer-metrics)
      - [5.1. Updating Microservices](#51-updating-microservices)
    - [6. Authentication: API Key](#6-authentication-api-key)
      - [6.1 Key-Auth Configuration](#61-key-auth-configuration)
      - [6.2 API Key Generation](#62-api-key-generation)
      - [6.3 Client-Side Setup](#63-client-side-setup)
    - [7. Deploy Remaining Microservices](#7-deploy-remaining-microservices)
  - [Test Commands: verifying operation + utilities](#test-commands-verifying-operation--utilities)
    - [1. Set Environment Variables (IP, PORT, KEY)](#1-set-environment-variables-ip-port-key)
    - [2. Authentication Verification (Security Check)](#2-authentication-verification-security-check)
    - [3. Sending Events to the Producer](#3-sending-events-to-the-producer)
      - [3.1 Device Boot](#31-device-boot)
      - [3.2 Telemetry Data (Environmental Data)](#32-telemetry-data-environmental-data)
      - [3.3 Critical Alerts (Error Handling)](#33-critical-alerts-error-handling)
      - [3.4 Firmware Updates (Maintenance)](#34-firmware-updates-maintenance)
    - [4. Reading Metrics (Metrics-service)](#4-reading-metrics-metrics-service)
    - [5. Database Clean-up (utility)](#5-database-clean-up-utility)
  - [Non-Functional Properties (NFP)](#non-functional-properties-nfp)
    - [Prerequisites](#prerequisites-1)
    - [1. **Security \& Secrets Management**](#1-security--secrets-management)
    - [2. **Resilience, Fault Tolerance \& High Availability**](#2-resilience-fault-tolerance--high-availability)
      - [2.1. Fault Tolerance: Consumer Failure (Buffering)](#21-fault-tolerance-consumer-failure-buffering)
      - [2.2. High Availability: Producer Self-Healing](#22-high-availability-producer-self-healing)
    - [3. **Scalability \& Load Balancing (without HPA)**](#3-scalability--load-balancing-without-hpa)
    - [4. **Horizontal Pod Autoscaler (HPA)**](#4-horizontal-pod-autoscaler-hpa)
    - [5. **Kong Rate Limiting Policy (Optional)**](#5-kong-rate-limiting-policy-optional)


## Prerequisites

* **Required**
  * **Docker Engine** (NOT Docker Desktop). [Ubuntu installation guide](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository) 
  * **Minikube**
  * **kubectl**

* **Optional**
  * **Lens**
  * **k9s**
  
---
## Architecture and Operation

The system implements an **Event-Driven** pattern with an API Gateway for authentication.

![Architecture](iot-kubernetes-architecture.svg)

### Ingestion Flow (Write)
1.  **HTTP Client** (IoT Sensor): Sends a `POST /event/...` request to the API Gateway (Kong) including the `apikey` header.
2.  **Kong Gateway**: Validates the API Key.
    * **Valid Key**: The request is forwarded to the Producer.
    * **Invalid Key**: Returns `401 Unauthorized`.
3.  **Producer**: Receives the payload, adds metadata, and routes the message to the correct Kafka topic:
    * `sensor-telemetry`: for high-frequency data (Boot, Telemetry, Firmware).
    * `sensor-alerts`: for critical errors (Alarms).
4.  **Kafka**: Persists the messages (the telemetry topic uses LZ4 compression).
5.  **Consumer**: Reads from both topics, converts timestamps, and saves to the **MongoDB** Time Series collection.


### Analytics Flow (Read)
1.  **HTTP Client**: Sends a `GET /metrics/temperature/average-by-zone` request to Kong.
2.  **Kong Gateway**: Validates the API Key.
3.  **Metrics-service**: Receives the request, runs aggregation queries on MongoDB, and returns statistics.

---

## Installation Guide

**(Optional) Reset and Clean Environment:**
    ```bash
    minikube delete --all
    docker system prune -a -f
    ```

### 0. Initial Cluster Setup

1.  **Start Minikube:**
    ```bash
    minikube start -p IoT-cluster
    minikube profile IoT-cluster  # sets the profile as default for minikube commands (no -p flag needed)
    minikube profile list
    minikube addons enable metrics-server -p IoT-cluster
    ```
    *(If you get an error, add your user to the docker group)*:
    ```bash
    sudo usermod -aG docker $USER && newgrp docker
    ```

2.  **Set the Docker environment:**
    To use the Docker daemon internal to Minikube (required to build images that Kubernetes will use):
    ```bash
    eval $(minikube -p IoT-cluster docker-env)
    ```
    **WARNING:** This command must be run in *every terminal* you use to build Docker images. Replace with the name of the running minikube profile.

### 1. Namespace Creation

<div style="margin-left: 40px;">

Create namespaces to isolate components:
```bash
kubectl create namespace kong
kubectl create namespace metrics
kubectl create namespace kafka
```
</div>

### 2. Strimzi Kafka Operator

1. **Install Strimzi** to manage the Kafka cluster via Helm.
    ```bash
    helm repo add strimzi https://strimzi.io/charts/
    helm repo update
    helm install strimzi-cluster-operator strimzi/strimzi-kafka-operator -n kafka
    ```

2. **Deploy the Kafka Cluster.** First, apply the manifests that define the Cluster, Users, and Kafka Topics. This will start the Strimzi operator, which will create the cluster and generate the `iot-sensor-cluster-cluster-ca-cert` secret containing the CA certificates.
    ```bash
    kubectl apply -f ./K8s/kafka/kafka-cluster.yaml
    kubectl apply -f ./K8s/kafka/kafka-users.yaml
    kubectl apply -f ./K8s/kafka/kafka-topics.yaml
    ```

    > **Wait for the cluster to be ready:** it may take a few minutes for the operator to create the cluster.
    ```bash
    kubectl wait kafka/iot-sensor-cluster --for=condition=Ready --timeout=300s -n kafka
    ```
    
    Once the above command completes, verify that the `iot-sensor-cluster-cluster-ca-cert` secret was created successfully:
    ```bash
    kubectl get secret iot-sensor-cluster-cluster-ca-cert -n kafka
    ```

    *Kafka is configured (via YAML files in `K8s/`) to use TLS and SCRAM-SHA-512 authentication.*

3. **Create the Kafka SSL Secret:** Now, create the `kafka-ca-cert` secret. This command reads the CA certificate from the Strimzi-generated secret (`iot-sensor-cluster-cluster-ca-cert`) and saves it into a new secret that our pods (Producer and Consumer) will use to communicate via TLS with Kafka.

    ```bash
    kubectl create secret generic kafka-ca-cert -n kafka \
      --from-literal=ca.crt="$(kubectl get secret iot-sensor-cluster-cluster-ca-cert -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d)"
    ```

### 3. MongoDB

<div style="margin-left: 40px;">

**Install MongoDB** using Helm as a **StatefulSet**.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami

helm install mongo-mongodb bitnami/mongodb --namespace kafka --version 18.1.1 \
    --set architecture=replicaset \
    --set replicaCount=1 \
    --set arbiter.enabled=false \
    --set auth.enabled=true
```
>*If the installation fails due to connection errors, try again.*

Wait for completion (press CTRL+C when you see Running):
```bash
# Check the StatefulSet
kubectl get sts -n kafka
# Check the Pods
kubectl get pods -n kafka -l app.kubernetes.io/name=mongodb -w
```

</div>

#### 3.1. Application User Configuration and Time Series Collection

1.  **Retrieve the root password:**

    ```bash
    export MONGODB_ROOT_PASSWORD=$(kubectl get secret -n kafka mongo-mongodb -o jsonpath='{.data.mongodb-root-password}' | base64 -d)
    ```

    *(Note the generated password, e.g.: `A36NCeYzH4`)*

2.  **Access the Mongo shell:**

    ```bash
    kubectl exec -it statefulset/mongo-mongodb -n kafka -- mongosh -u root -p $MONGODB_ROOT_PASSWORD --authenticationDatabase admin
    ```

3.  **Create the user**
    
    1.  Switch to the `iot_network` database:
        ```mongo
        use iot_network;
        ```
    2.  Create the user that will be used to access the DB:
        ```mongo
        db.createUser({
          user: "db_user",
          pwd: "segreta",
          roles: [ { role: "readWrite", db: "iot_network" } ]
        });
        ```

4. **Create the Time Series Collection for telemetry:**
    ```mongo
    db.createCollection("sensor_data", {
      timeseries: {
        timeField: "timestamp",
        metaField: "device_id",
        granularity: "seconds"
      },
      expireAfterSeconds: 2592000  // 30-day auto-cleanup
    });
    ```

5.  **Verify creation:**

    ```mongo
    use iot_network;
    ```

    ```mongo
    db.getUsers()
    ```
    ```mongo
    // Verify creation
    db.getCollectionInfos();
    ```

    Applications will use this connection string: `mongodb://db_user:segreta@mongo-mongodb-headless.kafka.svc.cluster.local:27017/iot_network?authSource=iot_network`

#### 3.2. ConfigMap and Secret Configuration (for Producer, Consumer and Metrics-service)

<div style="margin-left: 40px;">

We separate configuration (ConfigMap) from credentials (Secret).

We use Kubernetes Secrets instead of plain passwords to allow the Producer, Consumer and Metrics-service to connect to MongoDB.

```bash
# Apply ConfigMaps (Host, Port, DB Name)
kubectl apply -f ./K8s/mongodb-config.yaml

# Secret for the kafka namespace (Producer and Consumer)
kubectl create secret generic mongo-creds -n kafka \
  --from-literal=MONGO_USER="db_user" \
  --from-literal=MONGO_PASSWORD="segreta"

# Secret for the metrics namespace
kubectl create secret generic mongo-creds -n metrics \
  --from-literal=MONGO_USER="db_user" \
  --from-literal=MONGO_PASSWORD="segreta"
```
</div>


### 4. Kong API Gateway

<div style="margin-left: 40px;">

**Install Kong** and configure it to monitor the correct namespaces.

```bash
helm repo add kong https://charts.konghq.com
helm repo update
helm install kong kong/kong -n kong
```
</div>

1. **Update Kong** to make it "see" ingresses in other namespaces:
    ```bash
    helm upgrade kong kong/kong -n kong \
      --set ingressController.watchNamespaces="{kong,kafka,metrics}"
    ```
2. **Verify Kong installation:** check the services inside the cluster in the 'kong' namespace:
    ```bash
    kubectl get svc -n kong
    ```
    > The output should look like this (the important row is `kong-kong-proxy`):

    ```text
    NAME                           TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
    kong-kong-manager              NodePort       10.109.18.217   <none>        8002:31545/TCP,8445:30670/TCP
    kong-kong-metrics              ClusterIP      10.101.88.235   <none>        10255/TCP,10254/TCP
    kong-kong-proxy                LoadBalancer   10.105.61.105   <pending>     80:31260/TCP,443:32030/TCP
    kong-kong-validation-webhook   ClusterIP      10.110.97.78    <none>        443/TCP
    ```
3. **Get the public URL** to access Kong from your machine:
    ```bash
    minikube service kong-kong-proxy -n kong --url
    ```

    > This is a Minikube-specific command that creates a network tunnel from your machine to the `kong-kong-proxy` service inside the cluster. The output will print the URLs you can use to send requests to the API Gateway (one for HTTP and one for HTTPS):

    ```text
    http://192.168.49.2:31260
    http://192.168.49.2:32030
    ```

### 5. Microservices (Producer, Consumer, Metrics)

We need to build the Docker images for our Python microservices.

1. **Run `eval $(minikube -p IoT-cluster  docker-env)` in this terminal**
   
2. **Build the images:**

    ```bash
    docker build -t producer:latest ./Producer
    docker build -t consumer:latest ./Consumer
    docker build -t metrics-service:latest ./Metrics-service
    ```

    To verify that the images were created in the Minikube environment:
    ```bash
    docker images
    ```

#### 5.1. Updating Microservices

<div style="margin-left: 40px;">

If you modify the code (e.g. `app.py`), you need to rebuild the image and restart the deployment:

```bash
# Rebuild the image (e.g. producer)
docker build -t producer:latest ./Producer

# Restart the deployment
kubectl rollout restart deployment/producer -n kafka
kubectl rollout restart deployment/consumer -n kafka
kubectl rollout restart deployment/metrics-service -n metrics
```

To restart all deployments in a namespace:
```bash
kubectl rollout restart deployment -n kafka
kubectl rollout restart deployment -n metrics
```

</div>

### 6. Authentication: API Key
<div style="margin-left: 40px;">

The goal is to protect the exposed endpoints (`producer` and `metrics`) by blocking any unauthenticated request (`401 Unauthorized`) and only allowing access (`200 OK`) when a valid API Key is present in the `apikey` header.

**Components used:**
  * 2x `KongPlugin` (one per namespace: `kafka` and `metrics`) - type `key-auth`
  * 1x `KongConsumer` (logical identity "iot-devices")
  * 2x Kubernetes `Secret` (API Key per namespace `kafka` and `metrics`)

> **Production Note:** In this project we use a **single shared API Key** (`iot-sensor-key-prod-v1`) for simplicity. In production, each IoT device should have its own unique key, which can be generated with `openssl rand -hex 32`.

#### 6.1 Key-Auth Configuration
<div style="margin-left: 40px;">

Enable the `key-auth` plugin on Kong and create the "iot-devices" consumer identity.

```bash
# Enable the plugin for the namespaces
kubectl apply -f ./K8s/auth-apikey/apikey-plugin-kafka.yaml
kubectl apply -f ./K8s/auth-apikey/apikey-plugin-metrics.yaml

# Create the logical consumer
kubectl apply -f ./K8s/auth-apikey/apikey-consumer.yaml
```
> Kong applies security through plugins associated with namespaces or Ingresses. Since we have Ingresses in different namespaces, we enable the `apikey` plugin specifically for each of them.
</div>


#### 6.2 API Key Generation
<div style="margin-left: 40px;">

Create the secret key and associate it with the consumer.

```bash
# Create the secret with the key
kubectl apply -f ./K8s/auth-apikey/apikey-credential.yaml

# Associate the credential with the Kong consumer
kubectl patch kongconsumer iot-devices -n kafka \
  --type=json \
  -p='[{"op": "add", "path": "/credentials", "value": ["iot-devices-apikey"]}]'
```
Since Kong shares consumers across namespaces but not credentials, we need to create a second API Key secret for the `metrics` namespace:
```bash
kubectl apply -f ./K8s/auth-apikey/apikey-credential-metrics.yaml
```

Verify:
```bash
kubectl get secret -A | grep iot-devices-apikey
```

You should see **2 secrets** (one for kafka, one for metrics).
</div>

#### 6.3 Client-Side Setup
<div style="margin-left: 40px;">

Export the key for use in tests:

```bash
export API_KEY="iot-sensor-key-prod-v1"
echo "API Key: $API_KEY"
```
</div>

### 7. Deploy Remaining Microservices
<div style="margin-left: 40px;">

Now that the base infrastructure and security are configured, we can deploy the remaining manifests (Deployment, Service, Ingress).
The Ingresses (`producer-ingress` and `metrics-ingress`) are already configured with the `konghq.com/plugins: key-auth` annotation, so they will be protected immediately upon creation.

```bash
# Consumer (Backend worker, no Ingress)
kubectl apply -f ./K8s/micro-services/consumer-deployment.yaml

# Metrics Service (Backend + Ingress)
kubectl apply -f ./K8s/micro-services/metrics-deployment.yaml
kubectl apply -f ./K8s/micro-services/metrics-ingress.yaml

# Producer (Backend + Ingress)
kubectl apply -f ./K8s/micro-services/producer-deployment.yaml
kubectl apply -f ./K8s/micro-services/producer-ingress.yaml
```

>**Attention:** The Ingress files in K8s/micro-services/ are configured for IP **192.168.58.2**. If `minikube ip` returns a different value, update `producer-ingress.yaml` and `metrics-ingress.yaml` with your IP:
>```yaml
># In producer-ingress.yaml and metrics-ingress.yaml, change:
>host: producer.YOUR_IP.nip.io   
>host: metrics.YOUR_IP.nip.io    
>```

</div>

## Test Commands: verifying operation + utilities
We will use the `nip.io` service to resolve subdomains (`producer` and `metrics`) directly to the Minikube cluster IP, allowing us to test host-based Ingresses. \
We use `curl` to simulate sensor behavior and verify the pipeline operation.

### 1. Set Environment Variables (IP, PORT, KEY)
Before starting, export the necessary variables so we don't have to manually edit every `curl` command.

```bash
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

export API_KEY="iot-sensor-key-prod-v1"

echo "Target (IP:PORT): $IP:$PORT"
echo "API Key: $API_KEY"
```

### 2. Authentication Verification (Security Check)

Verify that the Gateway correctly blocks unauthorized requests and accepts valid ones.

**Scenario A: Access Denied (No API Key or wrong key)**

1. **Try contacting `producer` without credentials:**
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "Content-Type: application/json" \
      -d '{"device_id": "hacker-device", "zone_id": "unknown"}'
    ```
    > **Expected Result:** `HTTP/1.1 401 Unauthorized`

2. **Try contacting `metrics` without credentials:**
    ```bash
    curl -i http://metrics.$IP.nip.io:$PORT/metrics/boots
    ```
    > **Expected Result:** `401 Unauthorized`

**Scenario B: Access Granted (With API Key)**
Retry the same requests adding the `apikey` header with the corresponding API key.

1. **Try contacting `producer`:**
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"device_id": "test-sensor", "zone_id": "lab", "firmware": "v1.0"}'
    ```
    > **Expected Result:** `HTTP/1.1 200 OK`

2. **Try contacting `metrics`:**
    ```bash
    curl -i  http://metrics.$IP.nip.io:$PORT/metrics/boots \
      -H "apikey: $API_KEY"
    ```
    > **Expected Result:** `HTTP/1.1 200 OK`
   
  
### 3. Sending Events to the Producer
Now that we have verified access, let's populate the system with different types of events to test the full pipeline (Producer -> Kafka -> Consumer -> MongoDB).

These `curl` requests hit the `producer.$IP.nip.io` host, which Kong routes to the `producer` service.

**Log Monitoring**: In another terminal, watch the consumer process the data:
  ```bash
  kubectl logs -l app=consumer -n kafka -f
  ```

#### 3.1 Device Boot
Signals that a sensor has turned on and is online.
```bash
# Sensor 1 (Warehouse A)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "firmware": "v1.0"}'

# Sensor 2 (Warehouse A)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "zone_id": "warehouse-A", "firmware": "v1.0"}'
```

#### 3.2 Telemetry Data (Environmental Data)
Periodic sending of temperature and humidity readings.
```bash
# Normal data (Sensor 1)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "temperature": 24.5, "humidity": 45}'

# Heat spike (Sensor 2)
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "zone_id": "warehouse-A", "temperature": 32.0, "humidity": 30}'
```

#### 3.3 Critical Alerts (Error Handling)
Simulates a hardware failure.

```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/alert \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-02", "error_code": "CRITICAL_OVERHEAT", "severity": "high"}'
```

#### 3.4 Firmware Updates (Maintenance)
```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/firmware_update \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "sensor-01", "version_to": "v2.0"}'
```

### 4. Reading Metrics (Metrics-service)
Query the system to view aggregated data.

These `curl` requests hit the `metrics.$IP.nip.io` host, which Kong routes to the `metrics-service`.

```bash
# 1. Total booted devices
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/boots | json_pp

# 2. Average temperature by zone
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/temperature/average-by-zone | json_pp

# 3. Critical alarm count
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/alerts | json_pp

# 4. Firmware update statistics
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/firmware | json_pp

# 5. Activity trend for the last 7 days
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/activity/last7days | json_pp
```

### 5. Database Clean-up (utility)
  
Retrieve the admin password from the mongo secret:
```bash
export MONGODB_ROOT_PASSWORD=$(kubectl get secret --namespace kafka mongo-mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 -d)
```

Print the contents of the sensor_data collection:
```bash
kubectl exec -it statefulset/mongo-mongodb -n kafka -- mongosh iot_network \
  -u root -p $MONGODB_ROOT_PASSWORD \
  --authenticationDatabase admin \
  --eval "printjson(db.sensor_data.find().toArray())"
```

Empty the sensor_data collection:
```bash
kubectl exec -it statefulset/mongo-mongodb -n kafka -- mongosh iot_network \
  -u root -p $MONGODB_ROOT_PASSWORD \
  --authenticationDatabase admin \
  --eval "db.sensor_data.deleteMany({}); print('sensor_data cleared');"
```

## Non-Functional Properties (NFP)

This section documents the validation of the non-functional properties (NFP) of the infrastructure. \
The goal is to certify the `security`, `resilience, fault tolerance and HA`, and `scalability and load balancing` including `metrics-based autoscaling` of the implemented microservices architecture.

### Prerequisites
Dynamic extraction of Gateway IP and Port (Minikube)

```bash
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

export API_KEY="iot-sensor-key-prod-v1"
echo "Target (IP:PORT): $IP:$PORT"
echo "API Key: $API_KEY"
```

### 1. **Security & Secrets Management**

**Objective:** Verify channel encryption (TLS), authentication (SASL), and credentials protection.

- **Authentication Verification:**
    Attempt a connection without credentials to confirm it is rejected, failing with `No API key found in request` or `Unauthorized`.

    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "Content-Type: application/json" \
      -d '{"device_id": "unauth-sensor", "zone_id": "test"}'
    ```
    It is also rejected if a key other than the registered one is used:
    ```bash
    curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
      -H "apikey: bad-key" \
      -H "Content-Type: application/json" \
      -d '{"device_id": "test-sensor", "zone_id": "lab", "firmware": "v1.0"}'
    ```


1.  **TLS Verification (Data in Transit):**
    Verify that broker communication occurs over an encrypted channel.
    ```bash
    kubectl exec -it -n kafka iot-sensor-cluster-broker-0 -- \
      openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief </dev/null
    ```
    > **Expectation:** Output containing `Protocol version: TLSv1.3` and a strong Cipher Suite (e.g. `TLS_AES_256_GCM_SHA384`).

2.  **Authentication - SASL/SCRAM-SHA-512:** Kafka credentials stored in Kubernetes Secrets (not hardcoded).
    ```bash
    kubectl get secret consumer-user -n kafka -o yaml | grep password
    ```

3.  **MongoDB Secrets Management:** Verify that credentials are not stored in plaintext (MongoDB password obfuscated (base64) in Secret).
    ```bash
    # Verify Secret (encrypted credentials)
    kubectl get secret -n kafka mongo-creds -o yaml | grep "MONGO_"
    ```
    > * In the Secret, the `MONGO_USER` and `MONGO_PASSWORD` values are in base64 (not directly readable).

4.  **MongoDB ConfigMap Separation:** Verify that configuration is separated.
    ```bash
    # Verify ConfigMap (plaintext configuration)
    kubectl get configmap -n kafka mongodb-config -o yaml | grep "MONGO_"
    ```
    > * In the ConfigMap, the `MONGO_HOST`, `MONGO_PORT`, etc. values are in plaintext (OK, they are not sensitive).

### 2. **Resilience, Fault Tolerance & High Availability**

#### 2.1. Fault Tolerance: Consumer Failure (Buffering)

**Objective:** Demonstrate that the system does not lose data in case of component crashes.

This scenario simulates an unexpected Consumer crash while data continues to arrive at the Producer. It demonstrates Kafka's ability to act as a persistent buffer.

1. **Shut down the Consumer (Crash Simulation)**
    Scale the deployment to 0 to simulate a total service interruption.

    ```bash
    kubectl scale deploy/consumer -n kafka --replicas=0
    ```

2. **Send events while the Consumer is offline**
    These messages cannot be processed immediately, but will be saved in the Kafka topic.

    ```bash
    for i in {1..5}; do
      curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"device_id\":\"offline-sensor-$i\", \"zone_id\":\"buffer-test\", \"temperature\": 20.0, \"humidity\": 50.0}" >/dev/null
    done
    ```

3. **Restart the Consumer (Recovery)**
    Bring the deployment back to its operational state.

    ```bash
    kubectl scale deploy/consumer -n kafka --replicas=1
    ```

4. **Verify log processing**
    Watch the logs: you should see the messages sent during the "downtime" (those with ID `offline-sensor-*`) being processed immediately upon restart.

    ```bash
    kubectl logs -n kafka -l app=consumer -f --tail=20
    ```

> **Expectation:** Upon restart, the Consumer immediately processes the `offline-sensor-*` messages. No data loss.


#### 2.2. High Availability: Producer Self-Healing

**Objective:** Demonstrate that the system autonomously restores interrupted pods, guaranteeing High Availability (if replicas>=2), thus surviving the loss of an application node.

This test verifies infrastructure resilience by simulating a sudden crash (or accidental deletion) of a Pod. The goal is to demonstrate that Kubernetes detects the discrepancy between the desired and actual state, immediately starting a new instance to restore the service.

1. **Watch the producer**
    Before causing the failure, identify the active Producer pod and note its `AGE` (uptime).

     ```bash
    kubectl get pods -n kafka -l app=producer -w
    ```
    > When we simulate the crash, Kubernetes should terminate the old pod and create a new one instantly.

2. **Verify Service Continuity**
    To demonstrate that the disruption is minimal or zero during self-healing, run this loop in a separate terminal **before** killing the pod (next step).
    ```bash
    # Send a request every 0.5s to monitor availability
    while true; do 
      curl -s -o /dev/null -w "%{http_code} " \
      http://producer.$IP.nip.io:$PORT/event/boot \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"device_id":"healing-check", "zone_id":"ha-test"}'
      sleep 0.5
    done
    ```
    > **Expected Result:** You will see a sequence of `200` codes. You may see a brief pause or a single connection error during the switch, but the service will immediately resume responding with `200`.

3. **Failure Simulation (Kill Pod)**
    Force delete the currently running pod. This simulates a fatal application crash.

    ```bash
    # Automatically delete the first producer pod found
    kubectl delete pod $(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}") -n kafka
    ```

    > **Expectation:**
    > 1.  The old pod enters `Terminating` state.
    > 2.  A **new pod** (with a different name) immediately appears in `Pending` -> `ContainerCreating` -> `Running` state.
    > 3.  The operation occurs without human intervention.

4. **Zero Downtime**
    If we deploy more than one producer and one crashes, requests are routed to the other, completely avoiding downtime:
    ```bash
    kubectl scale deploy/producer -n kafka --replicas=2
    ```

    

### 3. **Scalability & Load Balancing (without HPA)**

**Objective:** Verify that traffic is distributed among producer and consumer replicas.

> **WARNING:** Make sure the Horizontal Pod Autoscaler (HPA) is **NOT** active before running this test. If you have already applied `hpa.yaml`, delete it with `kubectl delete -f K8s/hpa.yaml` to prevent Kubernetes from interfering with manual scaling.

This test simulates a high-load scenario to simultaneously verify two critical behaviors: \
  **Ingress Load Balancing:** The distribution of HTTP traffic across Producer replicas. \
  **Consumer Parallelism:** The ability to parallelize Kafka message reading by leveraging partitioning.


1. **Preparation: Service Scaling**
    Scale the **Producer** to 2 replicas (to test HTTP Round-Robin) and the **Consumer** to 3 replicas (to align with the 3 Kafka topic partitions and ensure maximum parallelism).

    ```bash
    # Scale the Producer (HTTP Layer)
    kubectl scale deploy/producer -n kafka --replicas=2

    # Scale the Consumer (Kafka Layer)
    kubectl scale deploy/consumer -n kafka --replicas=3

    # Wait for pods to be ready
    kubectl get pods -n kafka -l "app in (producer, consumer)"
    ```

2. **Load Injection (Burst)**
    Run a loop of 50 rapid API calls. The high frequency will force the Service to distribute the load across Producers, which will send messages to Kafka to be consumed in parallel.

    ```bash
    for i in {1..50}; do
      curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"device_id\":\"load-test-$i\", \"zone_id\":\"LB-test\", \"temperature\": 22.5, \"humidity\": 48.0}" >/dev/null
    done
    ```

3. **Validation 1: Producer & Ingress**
    Verify that requests were distributed between the two Producer pods.

    ```bash
    kubectl logs -n kafka -l app=producer --tail=50 --prefix=true | grep "load-test"
    ```

    > **Expectation:** Looking at the logs, you should see that `load-test-*` requests were handled alternately by two different pods (e.g. *vv8cg/producer* and *bpn87/producer*), confirming that the load was balanced by Kong Ingress and the producer-service.

4. **Validation 2: Consumer & Partitions**
    Verify that messages were processed by all three Consumer replicas.

    ```bash
    kubectl logs -n kafka -l app=consumer --tail=50 --prefix=true | grep "load-test"
    ```

    > **Expectation:** Logs must come from **all 3 Consumer pods**. This confirms that each replica is reading from its assigned partition, maximizing throughput.


    > **HA Note:** Even though this test validates performance, it indirectly demonstrates High Availability. If a Producer failed, traffic would naturally be redirected to the other one; the same applies to the consumer.

5. **Restore Replicas**
    Bring both the Producer and Consumer back to a single replica.

    ```bash
    kubectl scale deployment producer -n kafka --replicas=1
    kubectl scale deployment consumer -n kafka --replicas=1
    ```

    > **Expectation:** Kubernetes will terminate the excess pods (in `Terminating` state), freeing up CPU and RAM on the cluster, while the service remains active with the surviving replicas.

### 4. **Horizontal Pod Autoscaler (HPA)**

**Objective:** Verify that consumer and producer pod replicas increase/decrease based on workload, managed autonomously by HPA.

1.  **Initial Setup:** Deploy the HPA configuration.
    ```bash
    kubectl apply -f ./K8s/hpa.yaml
    ```

    Commands to verify it is actually deployed and its values:
    ```bash
    kubectl get hpa -n kafka
    kubectl describe hpa producer-hpa -n kafka | head -n 15
    ```

2.  **HPA Trigger (Stress Test):**
    Generate enough load to saturate the CPU threshold defined in the HPA.

    ```bash
    for i in {1..5000}; do
      curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
        -H "apikey: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"stress-sensor-$i\", \"zone_id\":\"HPA-test\", \"temperature\": 50.0, \"humidity\": 10.0}" \
        > /dev/null
    done
    ```

3.  **Scaling Monitoring:**
  
    Updates only when there is a change in the logs, but keeps track of changes:
    ```bash
    kubectl get hpa -n kafka -w
    ```
    More dynamic (updates every 1 second):
    ```bash
    watch -n 1 kubectl get hpa -n kafka
    ```

    > **Expectation:** The number of replicas (`REPLICAS`) automatically increases (e.g. from 1 to 4) as the CPU target rises.

4. **Elasticity & Scale Down**
After testing peak loads, it is essential to demonstrate the system's reverse **elasticity**: the ability to release resources when they are no longer needed (*scale down*), returning the cluster to standard operating state; managed automatically by HPA.
   
1.  **Restore:**
Remove the HPA configuration from the cluster:
    ```bash
    kubectl delete -f K8s/hpa.yaml
    ```

### 5. **Kong Rate Limiting Policy (Optional)**

**Objective:** Verify API Gateway protection against flood attacks.

We define a `KongPlugin` resource that enforces a limit of **5 requests per second** per client. This protects the service from overload or DoS (Denial of Service) attacks.

1. **Apply the plugin to the cluster**
    Use this command to create the Kubernetes object directly from the command line.

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
2. **Enable the Rate Limiting plugin on Kong (5 req/sec)**
    ```bash
    kubectl patch ingress producer-ingress -n kafka \
    -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth, global-rate-limit"}}}'
    ```
3. **Run the Flood Test**
    ```bash
    for i in {1..20}; do
      curl -s -o /dev/null -w "%{http_code}\n" \
        -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
        -H "apikey: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"flood-$i\", \"zone_id\":\"DoS-test\", \"temperature\": 0, \"humidity\": 0}"
    done
    ```
    > **Expectation:** After the first few requests (code `200`), responses of `429 Too Many Requests` are received.

1. **Remove configuration**
    ```bash
    kubectl delete kongplugin -n kafka global-rate-limit --ignore-not-found
    
    # leave only the authentication plugin
    kubectl patch ingress producer-ingress -n kafka \
    -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}'
    ```

    > **Expectation:** Only `200` status code responses are received due to the absence of rate-limiting.