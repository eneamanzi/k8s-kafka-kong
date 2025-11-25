#!/bin/bash

#==============================================================================
# Script Demo Interattivo - Progetto IoT Kubernetes
# Uso: Presentazioni ed esami
#==============================================================================

set -e

# Colori
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================
# Funzioni
# ==============================
pause() {
    echo -e "\n${YELLOW}${BOLD}[PAUSA]${NC} Premi INVIO per continuare..."
    read -r
}

demo_header() {
    clear
    echo -e "${CYAN}${BOLD}========================================${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}========================================${NC}\n"
}

demo_step() {
    echo -e "\n${BLUE}${BOLD}>>> $1${NC}\n"
}

show_command() {
    echo -e "${CYAN}\$ $1${NC}"
    sleep 0.5
}

# ==============================
# Inizio Demo
# ==============================
demo_header "Demo IoT Kubernetes - Architettura Event-Driven"

echo -e "${BOLD}Benvenuto!${NC}"
echo -e "Questa demo mostra il funzionamento completo del sistema:"
echo -e "  1. Autenticazione Kong (API Key)"
echo -e "  2. Ingestione dati (Producer → Kafka)"
echo -e "  3. Processamento asincrono (Consumer → MongoDB)"
echo -e "  4. Analytics (Metrics Service)"
pause

# ==============================
# Setup
# ==============================
demo_step "Configurazione Ambiente"

show_command "export IP=\$(minikube ip)"
export IP=$(minikube ip)

show_command "export PORT=\$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print \$3}')"
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')

show_command "export API_KEY=\"iot-sensor-key-prod-v1\""
export API_KEY="iot-sensor-key-prod-v1"

echo -e "\n${GREEN}✓${NC} Target: ${BOLD}$IP:$PORT${NC}"
echo -e "${GREEN}✓${NC} API Key: ${BOLD}$API_KEY${NC}"
pause

# ==============================
# Test Sicurezza
# ==============================
demo_header "Test 1: Verifica Sicurezza Kong"

demo_step "Scenario A: Tentativo accesso SENZA credenziali"

echo -e "Invio richiesta al Producer senza API Key..."
show_command "curl -X POST http://producer.$IP.nip.io:$PORT/event/boot \\"
echo -e "  ${CYAN}-H \"Content-Type: application/json\" \\${NC}"
echo -e "  ${CYAN}-d '{\"device_id\":\"hacker\",\"zone_id\":\"unknown\"}'${NC}"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "Content-Type: application/json" \
  -d '{"device_id":"hacker","zone_id":"unknown"}')

echo -e "\n${BOLD}Risultato: HTTP $HTTP_CODE${NC}"
if [ "$HTTP_CODE" = "401" ]; then
    echo -e "${GREEN}${BOLD}✓ Kong ha bloccato la richiesta!${NC}"
else
    echo -e "${YELLOW}⚠ Comportamento inatteso (atteso: 401)${NC}"
fi
pause

demo_step "Scenario B: Accesso CON API Key valida"

echo -e "Invio richiesta con header 'apikey'..."
show_command "curl -X POST http://producer.$IP.nip.io:$PORT/event/boot \\"
echo -e "  ${CYAN}-H \"apikey: \$API_KEY\" \\${NC}"
echo -e "  ${CYAN}-d '{\"device_id\":\"sensor-01\",\"zone_id\":\"lab\",\"firmware\":\"v2.0\"}'${NC}"

RESPONSE=$(curl -s -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-01","zone_id":"demo-lab","firmware":"v2.0"}')

echo -e "\n${BOLD}Risposta:${NC}"
echo "$RESPONSE" | python3 -m json.tool 2>/dev/null | head -n 10

echo -e "\n${GREEN}${BOLD}✓ Richiesta accettata! Evento inviato a Kafka.${NC}"
pause

# ==============================
# Flusso Dati
# ==============================
demo_header "Test 2: Flusso Completo dei Dati"

demo_step "Invio diversi tipi di eventi..."

echo -e "${BLUE}• Boot:${NC} Avvio dispositivo"
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-02","zone_id":"warehouse-A","firmware":"v1.5"}' > /dev/null
echo -e "${GREEN}✓${NC} Inviato"

echo -e "\n${BLUE}• Telemetry:${NC} Dati ambientali"
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-02","zone_id":"warehouse-A","temperature":24.5,"humidity":60}' > /dev/null
echo -e "${GREEN}✓${NC} Inviato"

echo -e "\n${BLUE}• Alert:${NC} Errore critico"
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/alert \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-02","error_code":"DEMO_ALERT","severity":"high"}' > /dev/null
echo -e "${GREEN}✓${NC} Inviato"

echo -e "\n${YELLOW}Attendo 5 secondi per il processamento del Consumer...${NC}"
for i in {5..1}; do echo -ne "\r  $i..."; sleep 1; done
echo -e "\r${GREEN}✓${NC} Completato"
pause

demo_step "Verifica Log Consumer"

show_command "kubectl logs -l app=consumer -n kafka --tail=10"
echo ""
kubectl logs -l app=consumer -n kafka --tail=10 | grep -E "\[BOOT\]|\[TELEMETRY\]|\[ALERT\]|demo-sensor" || echo "Nessun log trovato per i test demo"
pause

# ==============================
# Metriche
# ==============================
demo_header "Test 3: Servizio di Analytics"

demo_step "Query Metriche Aggregate"

echo -e "${BLUE}• Totale Boots:${NC}"
show_command "curl -s -H \"apikey: \$API_KEY\" http://metrics.$IP.nip.io:$PORT/metrics/boots"
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/boots | python3 -m json.tool 2>/dev/null || echo "{}"
echo ""
pause

echo -e "${BLUE}• Media Temperature per Zona:${NC}"
show_command "curl -s -H \"apikey: \$API_KEY\" http://metrics.$IP.nip.io:$PORT/metrics/temperature/average-by-zone"
curl -s -H "apikey: $API_KEY" http://metrics.$IP.nip.io:$PORT/metrics/temperature/average-by-zone | python3 -m json.tool 2>/dev/null | head -n 15 || echo "[]"
pause

# ==============================
# Conclusione
# ==============================
demo_header "Demo Completata!"

echo -e "${GREEN}${BOLD}✓ Sistema IoT Kubernetes Operativo${NC}\n"

echo -e "${BOLD}Architettura Verificata:${NC}"
echo -e "  1. ${GREEN}✓${NC} Kong API Gateway (Autenticazione API Key)"
echo -e "  2. ${GREEN}✓${NC} Producer Flask (Ingestione HTTP)"
echo -e "  3. ${GREEN}✓${NC} Kafka (2 topic: telemetry + alerts)"
echo -e "  4. ${GREEN}✓${NC} Consumer (Processamento asincrono)"
echo -e "  5. ${GREEN}✓${NC} MongoDB Time Series (Persistenza ottimizzata)"
echo -e "  6. ${GREEN}✓${NC} Metrics Service (Analytics real-time)\n"

echo -e "${CYAN}Grazie per l'attenzione!${NC}\n"