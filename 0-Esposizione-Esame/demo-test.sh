#!/bin/bash

# ==============================================================================
# DEMO STRICT README - IoT Kubernetes Architecture
# Versione: 5.1 (Real Output & Firmware Update)
# Descrizione: Esegue comandi espliciti mostrando Input e Output Reale
# ==============================================================================

set -e

# --- CONFIGURAZIONE VISIVA ---
RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
CYAN='\033[36m'
YELLOW='\033[33m'
WHITE='\033[37m'
BG_HEADER='\033[46;30m' # Background Ciano, testo nero

# --- GESTIONE EMERGENZE (TRAP) ---
function cleanup_on_exit {
    echo -e "\n${YELLOW}${BOLD}[AUTO-CLEANUP] Verifica stato cluster in chiusura...${RESET}"
    
    # Rimuovi Rate Limiting se presente
    if kubectl get kongplugin demo-rate-limit -n kafka >/dev/null 2>&1; then
        echo "  • Rimozione plugin Rate Limit..."
        kubectl patch ingress producer-ingress -n kafka -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}' >/dev/null 2>&1 || true
        kubectl delete kongplugin demo-rate-limit -n kafka >/dev/null 2>&1 || true
    fi

    # Ripristino Repliche
    kubectl scale deploy/producer -n kafka --replicas=1 >/dev/null 2>&1 || true
    kubectl scale deploy/consumer -n kafka --replicas=1 >/dev/null 2>&1 || true
    
    echo -e "${GREEN}[AUTO-CLEANUP] Completato.${RESET}"
}
trap cleanup_on_exit EXIT

# --- ENGINE DI TEST ---

header() {
    clear
    echo -e "\n${BG_HEADER}${BOLD}  $1  ${RESET}"
    echo -e "${WHITE}$2${RESET}\n"
}

# Funzione per Setup Variabili (Esegue nel contesto corrente, NO subshell)
run_setup_cmd() {
    local desc="$1"
    local cmd_str="$2"
    local var_name="$3" # Nome variabile per verifica
    
    echo -e "${BLUE}${BOLD}➤ STEP: $desc${RESET}"
    echo -e "  ${YELLOW}Comando:${RESET}  ${CYAN}$cmd_str${RESET}"
    
    # Esecuzione reale nel contesto corrente
    eval "$cmd_str"
    
    # Verifica valore
    local val=${!var_name}
    if [ -n "$val" ]; then
        echo -e "  ${YELLOW}Risultato:${RESET} ${GREEN}${BOLD}✓ OK${RESET} ($var_name=$val)\n"
    else
        echo -e "  ${YELLOW}Risultato:${RESET} ${RED}${BOLD}✗ FAIL${RESET} ($var_name è vuota)\n"
        exit 1
    fi
}

# Funzione Core: Stampa comando -> Esegue -> Valuta (Usa subshell per cattura output)
run_test() {
    local desc="$1"
    local cmd="$2"
    local expected="$3"
    local type="$4" # opzionale: "http_code", "grep"

    echo -e "${BLUE}${BOLD}➤ STEP: $desc${RESET}"
    echo -e "  ${YELLOW}Comando:${RESET}  ${CYAN}$cmd${RESET}"
    
    # MODIFICA: Rimosso output "Atteso: XYZ" per maggiore sincerità
    # echo -e "  ${YELLOW}Atteso:${RESET}   $expected"

    # Esecuzione
    local output
    if [ "$type" == "http_code" ]; then
        output=$(eval "$cmd" || echo "ERR")
    elif [ "$type" == "grep" ]; then
        if eval "$cmd"; then output="FOUND"; else output="NOT_FOUND"; fi
    else
        output=$(eval "$cmd" 2>&1 || echo "ERR")
    fi

    # Verifica
    if [[ "$output" == *"$expected"* ]]; then
         # Qui stampiamo l'output reale ottenuto
         echo -e "  ${YELLOW}Risultato:${RESET} ${GREEN}${BOLD}✓ OK${RESET} (Ricevuto: $output)\n"
    else
         echo -e "  ${YELLOW}Risultato:${RESET} ${RED}${BOLD}✗ FAIL${RESET} (Ricevuto: $output)\n"
    fi
}

pause() {
    echo -e "${WHITE}[Premi INVIO per procedere...]${RESET}"
    read -r
}

# ==============================================================================
# 1. SETUP VARIABILI AMBIENTE
# ==============================================================================
header "1. SETUP AMBIENTE" "Recupero IP Minikube e Porta Kong"

if ! minikube status >/dev/null 2>&1; then
    echo -e "${RED}Minikube non è attivo!${RESET}"
    exit 1
fi

CMD_IP="export IP=\$(minikube ip)"
run_setup_cmd "Recupero IP Cluster" "$CMD_IP" "IP"

CMD_PORT="export PORT=\$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print \$3}')"
run_setup_cmd "Recupero Porta Kong Gateway" "$CMD_PORT" "PORT"

CMD_KEY="export API_KEY=\"iot-sensor-key-prod-v1\""
run_setup_cmd "Definizione API Key" "$CMD_KEY" "API_KEY"

pause

# ==============================================================================
# 2. VERIFICA AUTENTICAZIONE
# ==============================================================================
header "2. VERIFICA AUTENTICAZIONE" "Verifica policy di sicurezza Kong"

CMD_AUTH_FAIL="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'Content-Type: application/json' -d '{}'"
run_test "Scenario A: Accesso Negato (No Key)" "$CMD_AUTH_FAIL" "401" "http_code"

CMD_AUTH_OK="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"test-auth\",\"zone_id\":\"A\"}'"
run_test "Scenario B: Accesso Consentito (Con Key)" "$CMD_AUTH_OK" "200" "http_code"

pause

# ==============================================================================
# 3. DATA INGESTION & LOGS
# ==============================================================================
header "3. DATA INGESTION PIPELINE" "Invio eventi (Boot, Telemetry, Alert) e verifica Logs"

# 3.1 Invio
CMD_BOOT="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\": \"sensor-01\", \"zone_id\": \"wh-A\", \"firmware\": \"v1.0\"}'"
run_test "Invio Evento: BOOT" "$CMD_BOOT" "200" "http_code"

CMD_TEL="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\": \"sensor-01\", \"zone_id\": \"wh-A\", \"temperature\": 24.5, \"humidity\": 45}'"
run_test "Invio Evento: TELEMETRY" "$CMD_TEL" "200" "http_code"

# AGGIUNTA FIRMWARE UPDATE
CMD_FW="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/firmware_update -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\": \"sensor-01\", \"version_to\": \"v2.0\"}'"
run_test "Invio Evento: FIRMWARE UPDATE" "$CMD_FW" "200" "http_code"

CMD_ALERT="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/alert -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\": \"sensor-02\", \"error_code\": \"CRIT\", \"severity\": \"high\"}'"
run_test "Invio Evento: ALERT" "$CMD_ALERT" "200" "http_code"

# 3.2 Logs
echo -e "${WHITE}Attendo propagazione Kafka (4s)...${RESET}"
sleep 4
CMD_LOGS="kubectl logs -l app=consumer -n kafka --tail=50 | grep -q 'sensor-01'"
run_test "Verifica Logs Consumer" "$CMD_LOGS" "FOUND" "grep"

pause

# ==============================================================================
# NFP 1: SECURITY
# ==============================================================================
header "NFP 1. SECURITY & SECRETS" "Verifica crittografia e offuscamento credenziali"

# 1.1 TLS
CMD_TLS="kubectl exec -i -n kafka iot-sensor-cluster-broker-0 -- openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief < /dev/null 2>&1 | grep 'Protocol version'"
run_test "Verifica TLS (Data in Transit)" "$CMD_TLS" "TLS" "standard"

# 1.2 Secrets
CMD_SECRET="kubectl get secret -n kafka mongo-creds -o yaml | grep 'MONGO_PASSWORD'"
run_test "Verifica Secret (Credenziali DB)" "$CMD_SECRET" "MONGO_PASSWORD" "standard"

# 1.3 ConfigMap
CMD_CM="kubectl get configmap -n kafka mongodb-config -o yaml | grep 'MONGO_HOST'"
run_test "Verifica ConfigMap (Configurazione non sensibile)" "$CMD_CM" "MONGO_HOST" "standard"

pause

# ==============================================================================
# NFP 2: RESILIENZA
# ==============================================================================
header "NFP 2. RESILIENZA & FAULT TOLERANCE" "Test Buffer Kafka e Self-Healing"

# 2.1 Buffering
echo -e "${BLUE}${BOLD}➤ STEP: Fault Tolerance (Consumer Buffering)${RESET}"
echo -e "  ${WHITE}1. Spengo Consumer...${RESET}"
kubectl scale deploy/consumer -n kafka --replicas=0 >/dev/null
sleep 2

CMD_OFFLINE="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"offline-data\", \"zone_id\":\"buf\", \"temperature\": 99, \"humidity\": 99}'"
run_test "Invio dati con Consumer Offline" "$CMD_OFFLINE" "200" "http_code"

echo -e "  ${WHITE}2. Riaccendo Consumer...${RESET}"
kubectl scale deploy/consumer -n kafka --replicas=1 >/dev/null
kubectl rollout status deployment/consumer -n kafka --timeout=60s > /dev/null

sleep 3
CMD_CHECK_BUF="kubectl logs -n kafka -l app=consumer --tail=50 | grep -q 'offline-data'"
run_test "Verifica Recupero Messaggi (Zero Data Loss)" "$CMD_CHECK_BUF" "FOUND" "grep"


# 2.2 Self Healing
echo -e "\n${BLUE}${BOLD}➤ STEP: High Availability (Self-Healing)${RESET}"
POD_PROD=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}")
CMD_KILL="kubectl delete pod $POD_PROD -n kafka --now"

echo -e "  ${WHITE}Pod Target: $POD_PROD${RESET}"
# Background traffic
( for i in {1..5}; do curl -s -o /dev/null "http://producer.$IP.nip.io:$PORT/event/boot" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{}' || true; sleep 0.5; done ) & 
PID=$!

run_test "Crash Simulato (Kill Pod)" "$CMD_KILL" "pod \"$POD_PROD\" deleted" "standard"
wait $PID

CMD_CHECK_HEAL="kubectl get pods -l app=producer -n kafka | grep -q 'Running'"
run_test "Verifica Riavvio Automatico" "$CMD_CHECK_HEAL" "FOUND" "grep"

pause

# ==============================================================================
# NFP 3: SCALABILITÀ
# ==============================================================================
header "NFP 3. SCALABILITÀ (MANUALE)" "Load Balancing e Scaling Orizzontale"

# 3.1 Scale Out
CMD_SCALE="kubectl scale deploy/producer -n kafka --replicas=2 && kubectl scale deploy/consumer -n kafka --replicas=3"
echo -e "${BLUE}${BOLD}➤ STEP: Scale Out Cluster${RESET}"
echo -e "  ${YELLOW}Comando:${RESET}  ${CYAN}$CMD_SCALE${RESET}"
eval "$CMD_SCALE"
echo -e "  ${WHITE}Attendo Pods...${RESET}"
kubectl rollout status deployment/producer -n kafka --timeout=60s > /dev/null
echo -e "  ${YELLOW}Risultato:${RESET} ${GREEN}✓ CLUSTER SCALATO${RESET} (Prod: 2, Cons: 3)\n"

# 3.2 Burst
echo -e "${BLUE}${BOLD}➤ STEP: Burst Test (Load Balancing)${RESET}"
echo -e "  ${YELLOW}Comando:${RESET}  ${CYAN}for i in {1..20}; do curl ... & done${RESET}"
for i in {1..20}; do
  curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d "{\"device_id\":\"lb-$i\", \"zone_id\":\"LB\", \"temperature\": 22, \"humidity\": 48}" &
done
wait
echo -e "  ${YELLOW}Risultato:${RESET} ${GREEN}✓ 20 Richieste Inviate in Parallelo${RESET}\n"

# 3.3 Cleanup
echo -e "${BLUE}${BOLD}➤ STEP: Scale Down (Cleanup)${RESET}"
kubectl scale deploy/producer -n kafka --replicas=1 > /dev/null
kubectl scale deploy/consumer -n kafka --replicas=1 > /dev/null
echo -e "  ${YELLOW}Risultato:${RESET} ${GREEN}✓ Repliche ripristinate a 1${RESET}\n"

pause

# ==============================================================================
# NFP 5: RATE LIMITING
# ==============================================================================
header "NFP 5. RATE LIMITING (Kong)" "Protezione DoS/Flood"

# 5.1 Apply
echo -e "${BLUE}${BOLD}➤ STEP: Applicazione Policy (Limit 5 req/sec)${RESET}"
CMD_PLUGIN="cat <<EOF | kubectl apply -f -
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: demo-rate-limit
  namespace: kafka
config:
  second: 5
  policy: local
plugin: rate-limiting
EOF"

CMD_PATCH="kubectl patch ingress producer-ingress -n kafka -p '{\"metadata\":{\"annotations\":{\"konghq.com/plugins\":\"key-auth, demo-rate-limit\"}}}'"

# Eseguo (senza eval complesso per heredoc, uso apply diretto per pulizia)
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
eval "$CMD_PATCH" > /dev/null

echo -e "  ${YELLOW}Comandi:${RESET}  ${CYAN}kubectl apply KongPlugin && kubectl patch ingress ...${RESET}"
echo -e "  ${WHITE}Attendo propagazione (4s)...${RESET}"
sleep 4
echo -e "  ${YELLOW}Risultato:${RESET} ${GREEN}✓ Plugin Applicato${RESET}\n"

# 5.2 Flood
echo -e "${BLUE}${BOLD}➤ STEP: Flood Test (15 richieste rapide)${RESET}"
BLOCKED=0
PASSED=0
for i in {1..15}; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" -H "apikey: $API_KEY" -H "Content-Type: application/json" -d '{"device_id":"flood","zone_id":"DoS","temperature":0,"humidity":0}' || echo "000")
    if [ "$CODE" == "429" ]; then ((BLOCKED++)); elif [ "$CODE" == "200" ]; then ((PASSED++)); fi
done

echo -e "  ${YELLOW}Atteso:${RESET}   Almeno 1 richiesta bloccata (429)"
echo -e "  ${YELLOW}Reale:${RESET}    Passate: $PASSED | Bloccate: $BLOCKED"

if [ $BLOCKED -gt 0 ]; then
    echo -e "  ${YELLOW}Risultato:${RESET} ${GREEN}${BOLD}✓ SUCCESSO${RESET} (Rate Limiting Attivo)\n"
else
    echo -e "  ${YELLOW}Risultato:${RESET} ${RED}${BOLD}✗ FALLITO${RESET} (Nessun blocco)\n"
fi

echo -e "${CYAN}${BOLD}>>> DEMO COMPLETATA <<<${RESET}"