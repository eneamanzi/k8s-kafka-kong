
# Guida
## Gestione Terminali Durante la Demo

**Terminale Principale** (Tab 0):
- Comandi principali della demo
- Test e validazioni

**Tab 1** - Consumer Logs (Parte 1: Pipeline Test):
```bash
kubectl logs -l app=consumer -n kafka -f --tail=0
```
- Aprire durante test pipeline (Sezione 1.2)
- Chiudere dopo verifica metriche

**Tab 2** - Consumer Recovery Logs (Parte 2: Fault Tolerance):
```bash
kubectl logs -n kafka -l app=consumer -f --tail=20
```
- Aprire durante recovery post-crash (Sezione 2.2)
- Chiudere dopo conferma processamento messaggi

**Tab 3** - Pod Watcher (Parte 2: Self-Healing):
```bash
kubectl get pods -n kafka -l app=producer -w
```
- Aprire durante test self-healing (Sezione 2.3)
- Chiudere dopo ripristino pod

**Tab 4** - Availability Monitor (Parte 2: Self-Healing - Opzionale):
```bash
# Loop continuo per monitorare disponibilità
while true; do 
  curl -s -o /dev/null -w "%{http_code} " ...
  sleep 0.5
done
```
- Aprire prima del kill pod (Sezione 2.3)
- Chiudere dopo dimostrazione zero-downtime

**Tab 5** - HPA Monitor (Parte 2: Elasticità):
```bash
watch -n 1 'kubectl get hpa -n kafka; echo ""; kubectl get pods -n kafka'
```
- Aprire dopo stress test (Sezione 2.5)
- Chiudere quando HPA torna a 1 replica


## Troubleshooting Rapido

### Se un comando fallisce:

**Problema**: `curl` restituisce "Connection refused" o timeout
```bash
# Verifica che Minikube sia attivo
minikube status

# Verifica IP e porta Kong
minikube service kong-kong-proxy -n kong --url

# Riexporta variabili
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')
```

### Reset Veloce del Sistema

```bash
# Restart tutti i microservizi
kubectl rollout restart deploy/producer -n kafka
kubectl rollout restart deploy/consumer -n kafka
kubectl rollout restart deploy/metrics-service -n metrics

# Attendi che siano ready
kubectl rollout status deploy/producer -n kafka
kubectl rollout status deploy/consumer -n kafka
kubectl rollout status deploy/metrics-service -n metrics
```

### Pulizia Database MongoDB

```bash
# Recupera password root
export MONGODB_ROOT_PASSWORD=$(kubectl get secret --namespace kafka mongo-mongodb -o jsonpath="{.data.mongodb-root-password}" | base64 -d)

# Svuota collection sensor_data
kubectl exec -it statefulset/mongo-mongodb -n kafka -- mongosh iot_network \
  -u root -p $MONGODB_ROOT_PASSWORD \
  --authenticationDatabase admin \
  --eval "db.sensor_data.deleteMany({}); print('Collection svuotata');"

# Verifica pulizia
kubectl exec -it statefulset/mongo-mongodb -n kafka -- mongosh iot_network \
  -u root -p $MONGODB_ROOT_PASSWORD \
  --authenticationDatabase admin \
  --eval "print('Documenti rimanenti: ' + db.sensor_data.countDocuments())"
```

### Verifica Stato Completo Cluster

```bash
# Overview tutti i namespace
kubectl get all -n kafka
kubectl get all -n metrics
kubectl get all -n kong

# Check risorse Kafka (Strimzi)
kubectl get kafka,kafkatopic,kafkauser -n kafka

# Check configurazione Kong
kubectl get kongplugin,kongconsumer,ingress -A

# Verifica Secret e ConfigMap critici
kubectl get secret,configmap -n kafka | grep -E "(kafka-ca-cert|mongo-creds|mongodb-config|producer-user|consumer-user)"
```