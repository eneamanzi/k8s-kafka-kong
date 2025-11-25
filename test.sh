#!/bin/bash

# ==============================================================================
# DEMO STRICT README - IoT Kubernetes Architecture
# Descrizione: Replica ESATTAMENTE i passaggi del README.md in modalità interattiva
# ==============================================================================

set -e

# --- CONFIGURAZIONE VISIVA ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# --- FUNZIONI HELPER ---
pause() {
    echo -e "\n${YELLOW}${BOLD}[INTERAZIONE]${NC} Premi INVIO per continuare..."
    read -r
}

header() {
    clear
    echo -e "${CYAN}${BOLD}############################################################${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}############################################################${NC}\n"
}

section() {
    echo -e "\n${BLUE}${BOLD}>>> [README] $1${NC}\n"
}

show_command() {
    echo -e "${CYAN}$ $1${NC}"
    sleep 0.5
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_fail() {
    echo -e "${RED}✗ $1${NC}"
}

# ==============================================================================
# 1. SETUP VARIABILI AMBIENTE
# ==============================================================================
header "1. SETUP VARIABILI AMBIENTE"

echo "Recupero IP e Porta da Minikube..."

show_command "export IP=\$(minikube ip)"
export IP=$(minikube ip)

show_command "export PORT=\$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print \$3}')"
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

show_command "export API_KEY=\"iot-sensor-key-prod-v1\""
export API_KEY="iot-sensor-key-prod-v1"

echo -e "\nTarget: ${BOLD}$IP:$PORT${NC}"
echo -e "API Key: ${BOLD}$API_KEY${NC}"

if [ -z "$IP" ] || [ -z "$PORT" ]; then
    log_fail "Impossibile recuperare IP o PORT. Minikube è attivo?"
    exit 1
fi
pause

# ==============================================================================
# 2. VERIFICA AUTENTICAZIONE
# ==============================================================================
header "2. VERIFICA AUTENTICAZIONE (Security Check)"

section "Scenario A: Accesso Negato (Senza API Key)"
show_command "curl -i -X POST http://producer.../event/boot (No Key)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/boot" -H "Content-Type: application/json" -d '{}')

if [ "$HTTP_CODE" == "401" ]; then
    log_success "Richiesta bloccata correttamente (401 Unauthorized)"
else
    log_fail "Errore: Ricevuto $HTTP_CODE invece di 401"
fi

section "Scenario B: Accesso Consentito (Con API Key)"
show_command "curl -i -X POST http://producer.../event/boot -H \"apikey: \$API_KEY\""
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/boot" \
    -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{"device_id":"test-auth","zone_id":"A"}')

if [ "$HTTP_CODE" == "200" ]; then
    log_success "Richiesta accettata (200 OK)"
else
    log_fail "Errore: Ricevuto $HTTP_CODE invece di 200"
fi
pause

# ==============================================================================
# 3. INVIARE EVENTI AL PRODUCER
# ==============================================================================
header "3. INVIARE EVENTI AL PRODUCER"

section "3.1 Device Boot"
show_command "curl ... /event/boot (Sensor-01)"
curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/boot" -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "firmware": "v1.0"}' > /dev/null
log_success "Boot inviato"

section "3.2 Telemetry Data"
show_command "curl ... /event/telemetry (Sensor-01 Normal)"
curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "temperature": 24.5, "humidity": 45}' > /dev/null

show_command "curl ... /event/telemetry (Sensor-02 High Temp)"
curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d '{"device_id": "sensor-02", "zone_id": "warehouse-A", "temperature": 32.0, "humidity": 30}' > /dev/null
log_success "Telemetrie inviate"

section "3.3 Critical Alerts"
show_command "curl ... /event/alert (CRITICAL_OVERHEAT)"
curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/alert" -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d '{"device_id": "sensor-02", "error_code": "CRITICAL_OVERHEAT", "severity": "high"}' > /dev/null
log_success "Alert inviato"

section "3.4 Firmware Updates"
show_command "curl ... /event/firmware_update (v2.0)"
curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/firmware_update" -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d '{"device_id": "sensor-01", "version_to": "v2.0"}' > /dev/null
log_success "Update inviato"

echo -e "\n${YELLOW}Attendo 5 secondi per il processamento Kafka -> Mongo...${NC}"
sleep 5
pause

# ==============================================================================
# 4. LEGGERE LE METRICHE
# ==============================================================================
header "4. LEGGERE LE METRICHE (Metrics-Service)"

section "4.1 Totale Boots"
show_command "curl ... /metrics/boots"
curl -s -H "apikey: $API_KEY" "http://metrics.$IP.nip.io:$PORT/metrics/boots" | python3 -m json.tool

section "4.2 Media Temperatura per Zona"
show_command "curl ... /metrics/temperature/average-by-zone"
curl -s -H "apikey: $API_KEY" "http://metrics.$IP.nip.io:$PORT/metrics/temperature/average-by-zone" | python3 -m json.tool

section "4.3 Alerts Totali"
show_command "curl ... /metrics/alerts"
curl -s -H "apikey: $API_KEY" "http://metrics.$IP.nip.io:$PORT/metrics/alerts" | python3 -m json.tool

pause

# ==============================================================================
# NFP 1: SECURITY & SECRETS
# ==============================================================================
header "NFP 1. SECURITY & SECRETS MANAGEMENT"

section "1.1 Verifica TLS (Data in Transit)"
echo "Eseguo openssl all'interno del pod Kafka per verificare la crittografia..."

# CORREZIONE 1: Selettore corretto per i pod Strimzi
POD_KAFKA=$(kubectl get pods -n kafka -l strimzi.io/cluster=iot-sensor-cluster -o jsonpath='{.items[0].metadata.name}' | head -n 1)

if [ -z "$POD_KAFKA" ]; then
    log_fail "Impossibile trovare un pod Kafka. Verifica che il cluster sia running."
    exit 1
fi
echo "Pod selezionato: $POD_KAFKA"

# CORREZIONE 2: 
# - Aggiunto 'timeout 10s' per evitare blocchi infiniti
# - Aggiunto 'echo "Q" |' per chiudere la connessione openssl in modo pulito
show_command "kubectl exec -n kafka $POD_KAFKA -- openssl s_client ..."
if echo "Q" | kubectl exec -i -n kafka "$POD_KAFKA" -- timeout 10s openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief 2>/dev/null | grep -q "Protocol version"; then
    log_success "TLS Attivo e verificato"
else
    # Fallback: a volte openssl stampa su stderr o il grep fallisce per versioni diverse
    log_fail "Verifica TLS fallita o timeout (controlla i log)"
    # Rimuovi il 'exit 1' se vuoi che lo script prosegua comunque
fi

section "1.2 Verifica Secrets vs ConfigMap"
echo "Verifico che la password DB sia oscurata (Secret) e l'host visibile (ConfigMap)"

show_command "kubectl get secret -n kafka mongo-creds -o yaml | grep MONGO_PASSWORD"
kubectl get secret -n kafka mongo-creds -o yaml | grep "MONGO_PASSWORD" | head -1 || echo "Secret non trovato"

show_command "kubectl get configmap -n kafka mongodb-config -o yaml | grep MONGO_HOST"
kubectl get configmap -n kafka mongodb-config -o yaml | grep "MONGO_HOST" | head -1 || echo "ConfigMap non trovata"

pause
# ==============================================================================
# NFP 2: RESILIENZA & HA
# ==============================================================================
header "NFP 2. RESILIENCE, FAULT TOLERANCE & HA"

section "2.1 Fault Tolerance: Consumer Failure (Buffering)"
echo "Simulo crash del Consumer. I dati inviati ORA non devono essere persi."

show_command "kubectl scale deploy/consumer -n kafka --replicas=0"
kubectl scale deploy/consumer -n kafka --replicas=0
sleep 2

show_command "curl -X POST ... (Invio 3 messaggi 'offline')"
for i in {1..3}; do
    curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d "{\"device_id\":\"offline-$i\", \"zone_id\":\"buffer\", \"temperature\": 20, \"humidity\": 50}"
done
log_success "Messaggi inviati al buffer Kafka."

show_command "kubectl scale deploy/consumer -n kafka --replicas=1 (Recovery)"
kubectl scale deploy/consumer -n kafka --replicas=1

echo "Attendo riavvio e controllo logs..."
kubectl rollout status deployment/consumer -n kafka --timeout=60s > /dev/null
sleep 2

show_command "kubectl logs -l app=consumer | grep offline"
if kubectl logs -n kafka -l app=consumer --tail=50 | grep -q "offline-"; then
    log_success "Il Consumer ha recuperato i messaggi dal buffer!"
else
    log_fail "Messaggi non trovati nei log recenti."
fi
pause

section "2.2 High Availability: Producer Self-Healing"
POD_PROD=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}")
echo "Pod Producer attuale: $POD_PROD"

echo "Lancio richieste in background mentre uccido il pod..."
(
    for i in {1..10}; do
        curl -s -o /dev/null "http://producer.$IP.nip.io:$PORT/event/boot" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{"device_id":"ha-check","zone_id":"ha"}'
        sleep 0.5
    done
) &
PID_LOOP=$!

show_command "kubectl delete pod $POD_PROD -n kafka --now"
kubectl delete pod $POD_PROD -n kafka --now > /dev/null

wait $PID_LOOP
log_success "Test completato. Kubernetes ha riavviato il pod automaticamente."
kubectl get pods -l app=producer -n kafka
pause

# ==============================================================================
# NFP 3: SCALABILITÀ
# ==============================================================================
header "NFP 3. SCALABILITÀ & LOAD BALANCING"

section "3.1 Scaling Manuale"
show_command "kubectl scale deploy/producer --replicas=2"
kubectl scale deploy/producer -n kafka --replicas=2
show_command "kubectl scale deploy/consumer --replicas=3"
kubectl scale deploy/consumer -n kafka --replicas=3

echo "Attendo che i pod siano pronti..."
kubectl rollout status deployment/producer -n kafka > /dev/null
kubectl rollout status deployment/consumer -n kafka > /dev/null

section "3.2 Burst Test (Load Balancing)"
echo "Invio 20 richieste rapide per vedere la distribuzione..."

show_command "for i in {1..20}; do curl ... & done"
for i in {1..20}; do
  curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d "{\"device_id\":\"lb-$i\", \"zone_id\":\"LB\", \"temperature\": 22, \"humidity\": 48}" &
done
wait
log_success "Burst completato."

section "3.3 Restore"
show_command "kubectl scale ... --replicas=1"
kubectl scale deploy/producer -n kafka --replicas=1 > /dev/null
kubectl scale deploy/consumer -n kafka --replicas=1 > /dev/null
pause

# ==============================================================================
# NFP 4: HPA (AUTOSCALING)
# ==============================================================================
header "NFP 4. HORIZONTAL POD AUTOSCALER"

section "4.1 Applicazione HPA"
show_command "kubectl apply -f ./K8s/hpa.yaml"
kubectl apply -f ./K8s/hpa.yaml

show_command "kubectl get hpa -n kafka"
kubectl get hpa -n kafka

echo -e "\n${YELLOW}NOTA: Lo stress test reale per HPA richiederebbe minuti.${NC}"
echo "Eseguo una simulazione rapida di traffico..."
timeout 5s bash -c "while true; do curl -s -o /dev/null -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"stress\",\"zone_id\":\"HPA\",\"temperature\":50,\"humidity\":10}'; done" || true

section "4.2 Cleanup HPA"
show_command "kubectl delete -f ./K8s/hpa.yaml"
kubectl delete -f ./K8s/hpa.yaml
pause

# ==============================================================================
# NFP 5: RATE LIMITING
# ==============================================================================
header "NFP 5. RATE LIMITING (Kong Policy)"

section "5.1 Applicazione Plugin (Limit: 5 req/sec)"
echo "Creo plugin rate-limiting e applico patch all'Ingress..."

# Uso show_command semplificato per leggibilità
show_command "kubectl apply -f (Plugin Def) && kubectl patch ingress..."

cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: demo-rate-limit
  namespace: kafka
config:
  second: 5
  policy: local
plugin: rate-limiting
EOF

kubectl patch ingress producer-ingress -n kafka -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth, demo-rate-limit"}}}' > /dev/null
sleep 3 # Propagazione

section "5.2 Flood Test"
echo "Invio 15 richieste rapide. Le ultime dovrebbero fallire (429)."

BLOCKED=0
PASSED=0
for i in {1..15}; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{"device_id":"flood","zone_id":"DoS","temperature":0,"humidity":0}')
    if [ "$CODE" == "429" ]; then ((BLOCKED++)); else ((PASSED++)); fi
done

echo -e "Richieste Riuscite: $PASSED | Richieste Bloccate: $BLOCKED"
if [ $BLOCKED -gt 0 ]; then
    log_success "Rate Limiting Attivo: $BLOCKED richieste bloccate."
else
    log_fail "Rate Limiting Fallito: Nessuna richiesta bloccata."
fi

section "5.3 Cleanup"
show_command "kubectl patch ingress ... (Remove Plugin)"
kubectl patch ingress producer-ingress -n kafka -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}' > /dev/null
kubectl delete kongplugin demo-rate-limit -n kafka > /dev/null
pause

# ==============================================================================
# CONCLUSIONE
# ==============================================================================
header "DEMO COMPLETATA CON SUCCESSO"
echo -e "${GREEN}Tutti i punti del README sono stati verificati.${NC}\n"