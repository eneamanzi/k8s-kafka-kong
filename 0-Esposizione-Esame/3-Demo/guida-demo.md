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

#Stampa il contenuto della Collection sensor_data
kubectl exec -it statefulset/mongo-mongodb -n kafka -- mongosh iot_network \
  -u root -p $MONGODB_ROOT_PASSWORD \
  --authenticationDatabase admin \
  --eval "printjson(db.sensor_data.find().toArray())"
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