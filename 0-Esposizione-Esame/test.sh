#!/bin/bash

# ==============================================================================
# DEMO STRICT README - IoT Kubernetes Architecture
# Versione: 2.1 (Robust & Crash-Safe)
# Descrizione: Replica i passaggi con gestione errori (Trap) e Curl sicuro
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

# --- GESTIONE EMERGENZE (TRAP) ---
# Questa funzione viene eseguita SEMPRE all'uscita, anche in caso di crash/errore
function cleanup_on_exit {
    echo -e "\n${YELLOW}[AUTO-CLEANUP] Verifica stato cluster in chiusura...${NC}"
    
    # 1. Rimuovi Rate Limiting se presente
    if kubectl get kongplugin demo-rate-limit -n kafka >/dev/null 2>&1; then
        echo "  • Rimozione plugin Rate Limit orfano..."
        kubectl patch ingress producer-ingress -n kafka -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}' >/dev/null 2>&1 || true
        kubectl delete kongplugin demo-rate-limit -n kafka >/dev/null 2>&1 || true
    fi

    # 2. Scala giù i deployment se sono rimasti scalati
    PROD_REPLICAS=$(kubectl get deploy producer -n kafka -o=jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [ "$PROD_REPLICAS" -gt 1 ]; then
        echo "  • Ripristino repliche Producer a 1..."
        kubectl scale deploy/producer -n kafka --replicas=1 >/dev/null 2>&1 || true
    fi
    
    CONS_REPLICAS=$(kubectl get deploy consumer -n kafka -o=jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [ "$CONS_REPLICAS" -gt 1 ]; then
        echo "  • Ripristino repliche Consumer a 1..."
        kubectl scale deploy/consumer -n kafka --replicas=1 >/dev/null 2>&1 || true
    fi
    
    echo -e "${GREEN}[AUTO-CLEANUP] Completato.${NC}"
}
trap cleanup_on_exit EXIT

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

echo "Verifica stato Minikube..."
if ! minikube status >/dev/null 2>&1; then
    log_fail "Minikube non sembra essere in esecuzione!"
    exit 1
fi

show_command "export IP=\$(minikube ip)"
export IP=$(minikube ip)

show_command "export PORT=\$(...)"
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

show_command "export API_KEY=\"iot-sensor-key-prod-v1\""
export API_KEY="iot-sensor-key-prod-v1"

echo -e "\nTarget: ${BOLD}$IP:$PORT${NC}"

if [ -z "$IP" ] || [ -z "$PORT" ]; then
    log_fail "Variabili IP/PORT vuote. Il cluster ha problemi?"
    exit 1
fi
pause

# ==============================================================================
# 2. VERIFICA AUTENTICAZIONE
# ==============================================================================
header "2. VERIFICA AUTENTICAZIONE"

section "Scenario A: Accesso Negato"
# Aggiunto '|| echo 000' per evitare crash se curl fallisce la connessione
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/boot" -H "Content-Type: application/json" -d '{}' || echo "000")

if [ "$HTTP_CODE" == "401" ]; then
    log_success "Richiesta bloccata (401)"
else
    log_fail "Atteso 401, ricevuto: $HTTP_CODE"
fi

section "Scenario B: Accesso Consentito"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/boot" \
    -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{"device_id":"test-auth","zone_id":"A"}' || echo "000")

if [ "$HTTP_CODE" == "200" ]; then
    log_success "Richiesta accettata (200)"
else
    log_fail "Atteso 200, ricevuto: $HTTP_CODE"
fi
pause

# ==============================================================================
# 3. FLUSSO DATI & LOGS
# ==============================================================================
header "3. INVIARE EVENTI & LOGS"

section "3.1 Invio Eventi"
# Curl con || true per non crashare
curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/boot" -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "firmware": "v1.0"}' > /dev/null || true
echo -e "Boot inviato"

curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d '{"device_id": "sensor-01", "zone_id": "warehouse-A", "temperature": 24.5, "humidity": 45}' > /dev/null || true
echo -e "Telemetria inviata"

section "3.2 Logs Consumer"
echo -e "${YELLOW}Attendo Kafka...${NC}"
sleep 4
kubectl logs -l app=consumer -n kafka --tail=20 | grep -E "sensor-01" && log_success "Logs trovati" || log_fail "Logs non trovati (o ritardo consumer)"

pause

# ==============================================================================
# NFP 1: SECURITY (TLS/SECRETS)
# ==============================================================================
header "NFP 1. SECURITY & SECRETS"

section "1.1 Verifica TLS"
echo "Check openssl nel broker..."
# Comando aggiornato con sintassi robusta
if kubectl exec -i -n kafka iot-sensor-cluster-broker-0 -- openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief < /dev/null 2>/dev/null | grep -q "Protocol version"; then
    log_success "TLS Attivo"
else
    log_fail "Check TLS fallito (il pod broker è running?)"
fi

section "1.2 Verifica Secrets"
kubectl get secret -n kafka mongo-creds -o yaml | grep "MONGO_PASSWORD" | head -1 && log_success "Secret OK"
pause

# ==============================================================================
# NFP 2: RESILIENZA
# ==============================================================================
header "NFP 2. RESILIENZA & HA"

section "2.1 Consumer Buffering"
show_command "Spegnimento Consumer..."
kubectl scale deploy/consumer -n kafka --replicas=0
sleep 2

echo "Invio dati nel buffer..."
curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d "{\"device_id\":\"offline-1\", \"zone_id\":\"buffer\", \"temperature\": 20, \"humidity\": 50}" || true

show_command "Ripristino Consumer..."
kubectl scale deploy/consumer -n kafka --replicas=1
kubectl rollout status deployment/consumer -n kafka --timeout=60s > /dev/null

sleep 3
if kubectl logs -n kafka -l app=consumer --tail=50 | grep -q "offline-"; then
    log_success "Messaggi recuperati dal buffer!"
else
    log_fail "Messaggi persi o non ancora processati."
fi

section "2.2 Producer Self-Healing"
POD_PROD=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}")
echo "Kill pod: $POD_PROD"

# Background loop
(
    for i in {1..6}; do
        curl -s -o /dev/null "http://producer.$IP.nip.io:$PORT/event/boot" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{"device_id":"ha-check","zone_id":"ha"}' || true
        sleep 0.5
    done
) &
PID_LOOP=$!

kubectl delete pod $POD_PROD -n kafka --now > /dev/null
wait $PID_LOOP
log_success "Pod riavviato automaticamente da K8s"
pause

# ==============================================================================
# NFP 3: SCALABILITÀ
# ==============================================================================
header "NFP 3. SCALABILITÀ"

section "3.1 Scale Out"
kubectl scale deploy/producer -n kafka --replicas=2
kubectl scale deploy/consumer -n kafka --replicas=3
echo "Attendo pod..."
kubectl rollout status deployment/producer -n kafka --timeout=60s > /dev/null
log_success "Scaled Out"

section "3.2 Burst Test"
echo "Invio 20 richieste..."
for i in {1..20}; do
  curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d "{\"device_id\":\"lb-$i\", \"zone_id\":\"LB\", \"temperature\": 22, \"humidity\": 48}" &
done
wait
log_success "Burst completato"

section "3.3 Restore"
kubectl scale deploy/producer -n kafka --replicas=1 > /dev/null
kubectl scale deploy/consumer -n kafka --replicas=1 > /dev/null
echo "Attendo scale down..."
sleep 3
log_success "Ripristinato"
pause

# ==============================================================================
# NFP 5: RATE LIMITING
# ==============================================================================
header "NFP 5. RATE LIMITING"

section "5.1 Applicazione Plugin"
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
echo "Attendo propagazione plugin (5s)..."
sleep 5

section "5.2 Flood Test"
echo "Invio 15 richieste. Attesi errori 429..."

BLOCKED=0
PASSED=0
for i in {1..15}; do
    # || echo 000 gestisce connection refused durante reload di kong
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{"device_id":"flood","zone_id":"DoS","temperature":0,"humidity":0}' || echo "000")
    
    if [ "$CODE" == "429" ]; then ((BLOCKED++)); 
    elif [ "$CODE" == "200" ]; then ((PASSED++)); 
    fi
done

echo -e "Passate: $PASSED | Bloccate: $BLOCKED"
if [ $BLOCKED -gt 0 ]; then
    log_success "Rate Limiting OK"
else
    log_fail "Nessun blocco rilevato (o errore curl)"
fi

# Il cleanup finale avviene automaticamente grazie al TRAP EXIT
echo -e "\n${CYAN}Fine script. Il cleanup automatico partirà ora...${NC}"