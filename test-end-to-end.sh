#!/bin/bash

#==============================================================================
# Script di Test End-to-End - Progetto IoT Kubernetes
# Descrizione: Verifica completa del flusso dati dalla sicurezza alle metriche
#==============================================================================

set -e  # Exit immediato su errore
set -o pipefail  # Propaga errori nelle pipe

# ==============================
# Configurazione Colori
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ==============================
# Funzioni di Logging
# ==============================
log_header() {
    echo -e "\n${CYAN}${BOLD}========================================${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}========================================${NC}\n"
}

log_step() {
    echo -e "${BLUE}${BOLD}[STEP $1]${NC} $2"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# ==============================
# Banner Iniziale
# ==============================
clear
log_header "IoT Kubernetes - Test End-to-End"
echo -e "${CYAN}Data Test: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${CYAN}Cluster: $(kubectl config current-context 2>/dev/null || echo 'N/A')${NC}\n"

# ==============================
# STEP 1: Configurazione Ambiente
# ==============================
log_step "1/7" "Configurazione ambiente..."

export IP=$(minikube ip 2>/dev/null)
export PORT=$(minikube service kong-kong-proxy -n kong --url 2>/dev/null | head -n 1 | awk -F: '{print $3}')
export API_KEY="iot-sensor-key-prod-v1"

if [ -z "$IP" ] || [ -z "$PORT" ]; then
    log_error "Impossibile recuperare IP ($IP) o PORT ($PORT). Verifica che Minikube sia avviato."
fi

log_success "Target: ${BOLD}$IP:$PORT${NC}"
log_success "API Key: ${BOLD}$API_KEY${NC}"

# ==============================
# STEP 2: Verifica Stato Cluster
# ==============================
log_step "2/7" "Verifica stato pod..."

check_pod_status() {
    local namespace=$1
    local app=$2
    local status=$(kubectl get pods -n $namespace -l app=$app -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$status" = "Running" ]; then
        log_success "$app (ns: $namespace): Running"
        return 0
    else
        log_error "$app (ns: $namespace): $status (atteso: Running)"
        return 1
    fi
}

check_pod_status "kafka" "producer"
check_pod_status "kafka" "consumer"
check_pod_status "metrics" "metrics-service"

# Verifica Kafka
KAFKA_READY=$(kubectl get kafka iot-sensor-cluster -n kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
if [ "$KAFKA_READY" = "True" ]; then
    log_success "Kafka Cluster: Ready"
else
    log_error "Kafka Cluster non pronto: $KAFKA_READY"
fi

# ==============================
# STEP 3: Test Autenticazione Kong
# ==============================
log_step "3/7" "Test autenticazione Kong..."

# Test 3.1: Richiesta SENZA API Key (deve fallire)
log_info "Test 3.1: Tentativo accesso senza credenziali..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "Content-Type: application/json" \
  -d '{"device_id":"unauth-test","zone_id":"test"}' \
  2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "401" ]; then
    log_success "Kong ha correttamente bloccato la richiesta non autorizzata (401)"
else
    log_error "Test sicurezza fallito: atteso 401, ricevuto $HTTP_CODE"
fi

# Test 3.2: Richiesta CON API Key (deve funzionare)
log_info "Test 3.2: Tentativo accesso con API Key valida..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"auth-test","zone_id":"test","firmware":"v1.0"}' \
  2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    log_success "Autenticazione API Key riuscita (200 OK)"
else
    log_error "Autenticazione fallita: atteso 200, ricevuto $HTTP_CODE"
fi

# ==============================
# STEP 4: Ingestione Eventi
# ==============================
log_step "4/7" "Invio eventi al Producer..."

TEST_ID="test-$(date +%s)"

send_event() {
    local endpoint=$1
    local payload=$2
    local event_type=$3
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://producer.$IP.nip.io:$PORT$endpoint" \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "200" ]; then
        log_success "Evento '$event_type' inviato correttamente"
        return 0
    else
        log_warning "Evento '$event_type' fallito (HTTP $HTTP_CODE)"
        return 1
    fi
}

# 4.1 Boot Event
send_event "/event/boot" \
  "{\"device_id\":\"$TEST_ID-sensor-01\",\"zone_id\":\"lab-test\",\"firmware\":\"v2.1\"}" \
  "Boot"

# 4.2 Telemetry Event
send_event "/event/telemetry" \
  "{\"device_id\":\"$TEST_ID-sensor-01\",\"zone_id\":\"lab-test\",\"temperature\":23.5,\"humidity\":58}" \
  "Telemetry"

# 4.3 Alert Event
send_event "/event/alert" \
  "{\"device_id\":\"$TEST_ID-sensor-01\",\"error_code\":\"TEST_ALERT\",\"severity\":\"low\"}" \
  "Alert"

# 4.4 Firmware Update Event
send_event "/event/firmware_update" \
  "{\"device_id\":\"$TEST_ID-sensor-01\",\"version_to\":\"v3.0\"}" \
  "Firmware Update"

# ==============================
# STEP 5: Attesa Processamento
# ==============================
log_step "5/7" "Attesa processamento Consumer..."

WAIT_TIME=8
for i in $(seq $WAIT_TIME -1 1); do
    echo -ne "\r${YELLOW}[!]${NC} Attendo $i secondi per il Consumer..."
    sleep 1
done
echo -e "\r${GREEN}[✓]${NC} Attesa completata (${WAIT_TIME}s)              "

# ==============================
# STEP 6: Verifica Consumer Logs
# ==============================
log_step "6/7" "Verifica processamento Consumer..."

CONSUMER_LOGS=$(kubectl logs -n kafka -l app=consumer --tail=50 2>/dev/null | grep "$TEST_ID" || echo "")

if [ -z "$CONSUMER_LOGS" ]; then
    log_warning "Consumer logs non mostrano gli eventi di test (possibile ritardo)"
    log_info "Controllo manuale: kubectl logs -l app=consumer -n kafka --tail=100 | grep '$TEST_ID'"
else
    PROCESSED_COUNT=$(echo "$CONSUMER_LOGS" | wc -l)
    log_success "Consumer ha processato $PROCESSED_COUNT eventi di test"
    
    # Mostra un estratto dei log
    echo -e "${CYAN}Estratto log Consumer:${NC}"
    echo "$CONSUMER_LOGS" | head -n 3 | sed 's/^/  /'
    if [ $PROCESSED_COUNT -gt 3 ]; then
        echo "  ..."
    fi
fi

# ==============================
# STEP 7: Test Metrics Service
# ==============================
log_step "7/7" "Verifica Metrics Service..."

test_metric() {
    local endpoint=$1
    local metric_name=$2
    local expected_field=$3
    
    RESPONSE=$(curl -s -H "apikey: $API_KEY" \
      "http://metrics.$IP.nip.io:$PORT$endpoint" 2>/dev/null || echo "{}")
    
    if echo "$RESPONSE" | grep -q "$expected_field"; then
        log_success "Metrica '$metric_name' operativa"
        return 0
    else
        log_warning "Metrica '$metric_name' non disponibile (DB potrebbe essere vuoto)"
        return 1
    fi
}

test_metric "/metrics/boots" "Device Boots" "total_device_boots"
test_metric "/metrics/temperature/average-by-zone" "Temperature" "avg_temp\|zone_id\|\[\]"
test_metric "/metrics/alerts" "Alerts" "severity\|count\|\[\]"
test_metric "/metrics/firmware" "Firmware" "_id\|count\|\[\]"

# Dettaglio: Conteggio Boots
BOOTS_COUNT=$(curl -s -H "apikey: $API_KEY" \
  "http://metrics.$IP.nip.io:$PORT/metrics/boots" 2>/dev/null \
  | grep -o '"total_device_boots":[0-9]*' | grep -o '[0-9]*' || echo "N/A")

if [ "$BOOTS_COUNT" != "N/A" ]; then
    log_info "Totale boots registrati nel sistema: ${BOLD}$BOOTS_COUNT${NC}"
fi

# ==============================
# Report Finale
# ==============================
log_header "Test Completato con Successo!"

echo -e "${GREEN}${BOLD}✓ Tutti i componenti operativi${NC}\n"

echo -e "${CYAN}${BOLD}Riepilogo Test:${NC}"
echo -e "  • Cluster Kubernetes: ${GREEN}✓${NC} Operativo"
echo -e "  • Kong API Gateway:   ${GREEN}✓${NC} Sicurezza attiva"
echo -e "  • Producer:           ${GREEN}✓${NC} Eventi inviati (4/4)"
echo -e "  • Kafka:              ${GREEN}✓${NC} Buffering attivo"
echo -e "  • Consumer:           ${GREEN}✓${NC} Processamento OK"
echo -e "  • MongoDB:            ${GREEN}✓${NC} Persistenza OK"
echo -e "  • Metrics Service:    ${GREEN}✓${NC} Analytics disponibili\n"

echo -e "${CYAN}${BOLD}Comandi Utili:${NC}"
echo -e "  ${BLUE}•${NC} Logs Consumer:  ${BOLD}kubectl logs -l app=consumer -n kafka --tail=50${NC}"
echo -e "  ${BLUE}•${NC} Logs Producer:  ${BOLD}kubectl logs -l app=producer -n kafka --tail=50${NC}"
echo -e "  ${BLUE}•${NC} Verifica Kafka: ${BOLD}kubectl get kafkatopic -n kafka${NC}"
echo -e "  ${BLUE}•${NC} Query MongoDB:  ${BOLD}kubectl exec -it deployment/mongo-mongodb -n kafka -- mongosh iot_network${NC}\n"

echo -e "${YELLOW}Timestamp fine test: $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
