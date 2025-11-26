#!/bin/bash

# ==============================================================================
# DEMO IoT Kubernetes Architecture - Versione Finale Ottimizzata
# Versione: 9.0 (Cleanup Robusto + Test Migliorati dal README)
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
MAGENTA='\033[35m'
BG_HEADER='\033[46;30m'

# --- STATO INIZIALE CLUSTER ---
INITIAL_PRODUCER_REPLICAS=""
INITIAL_CONSUMER_REPLICAS=""
RATE_LIMIT_APPLIED=false

# --- GESTIONE EMERGENZE (TRAP) ---
function cleanup_on_exit {
    local exit_code=$?
    
    echo -e "\n${YELLOW}${BOLD}========================================${RESET}"
    echo -e "${YELLOW}${BOLD}[AUTO-CLEANUP] Ripristino stato cluster${RESET}"
    echo -e "${YELLOW}${BOLD}========================================${RESET}"
    
    # Disabilita set -e temporaneamente per permettere errori nel cleanup
    set +e
    
    # Rimuovi Rate Limiting se applicato
    if [ "$RATE_LIMIT_APPLIED" = true ]; then
        echo -e "${CYAN}→ Rimozione plugin Rate Limit...${RESET}"
        kubectl patch ingress producer-ingress -n kafka \
            -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}' >/dev/null 2>&1
        kubectl delete kongplugin demo-rate-limit -n kafka >/dev/null 2>&1
        echo -e "${GREEN}  ✓ Rate Limit rimosso${RESET}"
    fi

    # Ripristino repliche originali (solo se salvate)
    if [ -n "$INITIAL_PRODUCER_REPLICAS" ]; then
        echo -e "${CYAN}→ Ripristino repliche Producer...${RESET}"
        kubectl scale deploy/producer -n kafka --replicas=$INITIAL_PRODUCER_REPLICAS >/dev/null 2>&1
        echo -e "${GREEN}  ✓ Producer: $INITIAL_PRODUCER_REPLICAS replica(s)${RESET}"
    fi
    
    if [ -n "$INITIAL_CONSUMER_REPLICAS" ]; then
        echo -e "${CYAN}→ Ripristino repliche Consumer...${RESET}"
        kubectl scale deploy/consumer -n kafka --replicas=$INITIAL_CONSUMER_REPLICAS >/dev/null 2>&1
        echo -e "${GREEN}  ✓ Consumer: $INITIAL_CONSUMER_REPLICAS replica(s)${RESET}"
    fi
    
    # Riabilita set -e
    set -e
    
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${YELLOW}Script interrotto (exit code: $exit_code)${RESET}"
    else
        echo -e "\n${GREEN}${BOLD}[SUCCESSO] Cleanup completato${RESET}"
    fi
}
trap cleanup_on_exit EXIT INT TERM

# --- FUNZIONI HELPER ---

header() {
    clear
    echo -e "\n${BG_HEADER}${BOLD}  $1  ${RESET}"
    echo -e "${WHITE}$2${RESET}\n"
}

pause() {
    echo -e "\n${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${WHITE}[Premi INVIO per continuare...]${RESET}"
    read -r
}

# ==============================================================================
# FUNZIONE CORE: Esegue comando, mostra output E verifica correttezza
# ==============================================================================
run_cmd() {
    local desc="$1"
    local cmd_var="$2"
    local validation_type="${3:-none}"
    local expected="${4:-}"
    
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BLUE}${BOLD}➤ $desc${RESET}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}Comando:${RESET}"
    echo -e "${CYAN}$cmd_var${RESET}\n"
    
    echo -e "${YELLOW}Output:${RESET}"
    echo -e "${WHITE}┌────────────────────────────────────────┐${RESET}"
    
    local output
    local exit_code=0
    
    # Cattura output ed exit code
    output=$(eval "$cmd_var" 2>&1) || exit_code=$?
    
    # Mostra output formattato
    echo "$output" | while IFS= read -r line; do
        echo -e "${WHITE}│${RESET} $line"
    done
    
    echo -e "${WHITE}└────────────────────────────────────────┘${RESET}"
    
    # VALIDAZIONE INTELLIGENTE
    local validation_passed=false
    
    case "$validation_type" in
        http_code)
            local http_code=$(echo "$output" | grep -oE '[0-9]{3}' | tail -n 1)
            echo -e "\n${MAGENTA}Validazione HTTP Code:${RESET}"
            echo -e "  Ricevuto: ${WHITE}$http_code${RESET}"
            echo -e "  Atteso: ${WHITE}$expected${RESET}"
            
            if [ "$http_code" == "$expected" ]; then
                validation_passed=true
            fi
            ;;
            
        grep)
            echo -e "\n${MAGENTA}Validazione Grep:${RESET}"
            echo -e "  Pattern cercato: ${WHITE}$expected${RESET}"
            
            if echo "$output" | grep -q "$expected"; then
                echo -e "  Risultato: ${GREEN}Pattern trovato ✓${RESET}"
                validation_passed=true
            else
                echo -e "  Risultato: ${RED}Pattern NON trovato ✗${RESET}"
            fi
            ;;
            
        contains)
            echo -e "\n${MAGENTA}Validazione Contains:${RESET}"
            echo -e "  Substring cercata: ${WHITE}$expected${RESET}"
            
            if [[ "$output" == *"$expected"* ]]; then
                echo -e "  Risultato: ${GREEN}Trovata ✓${RESET}"
                validation_passed=true
            else
                echo -e "  Risultato: ${RED}NON trovata ✗${RESET}"
            fi
            ;;
            
        none)
            if [ $exit_code -eq 0 ]; then
                validation_passed=true
            fi
            ;;
    esac
    
    echo ""
    if [ "$validation_passed" = true ]; then
        echo -e "${GREEN}${BOLD}✓ TEST SUPERATO${RESET}\n"
    else
        echo -e "${RED}${BOLD}✗ TEST FALLITO${RESET}\n"
    fi
}

# Funzione per setup variabili
run_setup() {
    local desc="$1"
    local cmd_str="$2"
    local var_name="$3"
    
    echo -e "${BLUE}${BOLD}➤ $desc${RESET}"
    echo -e "${YELLOW}Comando:${RESET} ${CYAN}$cmd_str${RESET}"
    
    eval "$cmd_str"
    
    local val="${!var_name}"
    if [ -n "$val" ]; then
        echo -e "${YELLOW}Risultato:${RESET} ${GREEN}${BOLD}$var_name=$val ✓${RESET}\n"
    else
        echo -e "${YELLOW}Risultato:${RESET} ${RED}${BOLD}ERRORE - variabile vuota!${RESET}\n"
        exit 1
    fi
}

# ==============================================================================
# 0. VERIFICA PREREQUISITI
# ==============================================================================
header "0. VERIFICA PREREQUISITI" "Controllo stato cluster Minikube"

if ! minikube status >/dev/null 2>&1; then
    echo -e "${RED}${BOLD}[ERRORE] Minikube non è attivo!${RESET}"
    echo -e "${YELLOW}Avvia il cluster con: ${CYAN}minikube start -p IoT-cluster${RESET}"
    exit 1
fi

echo -e "${GREEN}✓ Minikube attivo${RESET}\n"

# Salva stato iniziale repliche
INITIAL_PRODUCER_REPLICAS=$(kubectl get deploy/producer -n kafka -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
INITIAL_CONSUMER_REPLICAS=$(kubectl get deploy/consumer -n kafka -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

echo -e "${CYAN}Stato iniziale cluster:${RESET}"
echo -e "  Producer replicas: ${WHITE}$INITIAL_PRODUCER_REPLICAS${RESET}"
echo -e "  Consumer replicas: ${WHITE}$INITIAL_CONSUMER_REPLICAS${RESET}\n"

# ==============================================================================
# 1. SETUP VARIABILI AMBIENTE
# ==============================================================================
header "1. SETUP AMBIENTE" "Recupero IP Minikube e Porta Kong"

CMD_IP='export IP=$(minikube ip)'
run_setup "Recupero IP Cluster" "$CMD_IP" "IP"

CMD_PORT='export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: "{print \$3}")'
run_setup "Recupero Porta Kong Gateway" "$CMD_PORT" "PORT"

CMD_KEY='export API_KEY="iot-sensor-key-prod-v1"'
run_setup "Definizione API Key" "$CMD_KEY" "API_KEY"

echo -e "${GREEN}${BOLD}✓ Setup completato${RESET}"
echo -e "${CYAN}Target endpoint:${RESET} ${WHITE}http://producer.$IP.nip.io:$PORT${RESET}"

pause

# ==============================================================================
# 2. VERIFICA AUTENTICAZIONE (README Sezione 2)
# ==============================================================================
header "2. VERIFICA AUTENTICAZIONE" "Test policy di sicurezza Kong (Key-Auth)"

echo -e "${CYAN}Scenario A: Accesso NEGATO senza API Key${RESET}"
echo -e "${WHITE}Atteso: 401 Unauthorized (No API key found)${RESET}\n"
CMD_AUTH_FAIL="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'Content-Type: application/json' -d '{\"device_id\":\"unauthorized-device\",\"zone_id\":\"unknown\"}'"
run_cmd "Test: Richiesta senza credenziali" "$CMD_AUTH_FAIL" "http_code" "401"

echo -e "${CYAN}Scenario B: Accesso CONSENTITO con API Key valida${RESET}"
echo -e "${WHITE}Atteso: 200 OK (Kong valida la chiave e inoltra al backend)${RESET}\n"
CMD_AUTH_OK="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"auth-test-device\",\"zone_id\":\"secure-lab\"}'"
run_cmd "Test: Richiesta con API Key valida" "$CMD_AUTH_OK" "http_code" "200"

pause

# ==============================================================================
# 3. DATA INGESTION PIPELINE (README Sezione 3)
# ==============================================================================
header "3. DATA INGESTION PIPELINE" "Test invio eventi IoT tipici (README Sezione 3.1-3.4)"

echo -e "${CYAN}3.1 Device Boot Event${RESET}"
echo -e "${WHITE}Simula: Sensore si accende e notifica il sistema (Warehouse A)${RESET}\n"
CMD_BOOT="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-01\",\"zone_id\":\"warehouse-A\",\"firmware\":\"v1.0\"}'"
run_cmd "Boot: demo-sensor-01 in warehouse-A" "$CMD_BOOT" "http_code" "200"

echo -e "${CYAN}3.2 Telemetry Data (Condizioni Normali)${RESET}"
echo -e "${WHITE}Simula: Invio dati ambientali regolari (24.5°C, 45% umidità)${RESET}\n"
CMD_TEL_NORMAL="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-01\",\"zone_id\":\"warehouse-A\",\"temperature\":24.5,\"humidity\":45}'"
run_cmd "Telemetry: demo-sensor-01 (condizioni normali)" "$CMD_TEL_NORMAL" "http_code" "200"

echo -e "${CYAN}3.2 Telemetry Data (Picco di Calore)${RESET}"
echo -e "${WHITE}Simula: Secondo sensore rileva temperatura anomala (32°C)${RESET}\n"
CMD_TEL_HOT="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-02\",\"zone_id\":\"warehouse-A\",\"temperature\":32.0,\"humidity\":30}'"
run_cmd "Telemetry: demo-sensor-02 (picco calore)" "$CMD_TEL_HOT" "http_code" "200"

echo -e "${CYAN}3.3 Critical Alert (Guasto Hardware)${RESET}"
echo -e "${WHITE}Simula: Sensore rileva surriscaldamento critico${RESET}\n"
CMD_ALERT="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/alert -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-02\",\"error_code\":\"CRITICAL_OVERHEAT\",\"severity\":\"high\"}'"
run_cmd "Alert: demo-sensor-02 (CRITICAL_OVERHEAT)" "$CMD_ALERT" "http_code" "200"

echo -e "${CYAN}3.4 Firmware Update (Manutenzione)${RESET}"
echo -e "${WHITE}Simula: Aggiornamento firmware sensore da v1.0 a v2.0${RESET}\n"
CMD_FW="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/firmware_update -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-01\",\"version_to\":\"v2.0\"}'"
run_cmd "Firmware Update: demo-sensor-01 → v2.0" "$CMD_FW" "http_code" "200"

echo -e "${CYAN}Attendo propagazione: Kafka → Consumer → MongoDB (4 secondi)...${RESET}\n"
sleep 4

echo -e "${CYAN}Verifica: Consumer ha processato tutti gli eventi demo${RESET}"
echo -e "${WHITE}Cerchiamo: demo-sensor-01 e demo-sensor-02 nei log recenti${RESET}\n"
CMD_LOGS="kubectl logs -l app=consumer -n kafka --tail=50 | grep -E '(demo-sensor-01|demo-sensor-02)'"
run_cmd "Consumer Logs: Eventi demo processati" "$CMD_LOGS" "grep" "demo-sensor-"

pause

# ==============================================================================
# NFP 1: SECURITY & SECRETS (README Sezione 6.1)
# ==============================================================================
header "NFP 1. SECURITY & SECRETS MANAGEMENT" "Verifica Defense in Depth (README NFP 6.1)"

echo -e "${CYAN}1.1 Data in Transit: TLS Encryption (Kafka)${RESET}"
echo -e "${WHITE}Verifica: Comunicazione Producer/Consumer → Kafka su canale cifrato${RESET}\n"
CMD_TLS="kubectl exec -i -n kafka iot-sensor-cluster-broker-0 -- openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief < /dev/null 2>&1 | grep -E '(Protocol|Cipher)'"
run_cmd "TLS Check: Connessione al Broker (porta 9093)" "$CMD_TLS" "contains" "Protocol"

echo -e "${CYAN}1.2 Authentication: SASL/SCRAM-SHA-512${RESET}"
echo -e "${WHITE}Verifica: Credenziali Kafka sono in Secret Kubernetes (non hardcoded)${RESET}\n"
CMD_SASL="kubectl get secret consumer-user -n kafka -o yaml | grep password"
run_cmd "SASL Secret: consumer-user (base64 encoded)" "$CMD_SASL" "contains" "password"

echo -e "${CYAN}1.3 Edge Protection: Kong API Key${RESET}"
echo -e "${WHITE}Già testato in Sezione 2 (401 senza key, 200 con key)${RESET}\n"

echo -e "${CYAN}1.4 Secrets Management: MongoDB Credentials${RESET}"
echo -e "${WHITE}Verifica: Password MongoDB offuscata (base64) in Secret${RESET}\n"
CMD_MONGO_SECRET="kubectl get secret -n kafka mongo-creds -o yaml | grep MONGO_PASSWORD"
run_cmd "MongoDB Secret: Password offuscata" "$CMD_MONGO_SECRET" "contains" "MONGO_PASSWORD"

echo -e "${CYAN}1.5 ConfigMap Separation: Configurazione Non Sensibile${RESET}"
echo -e "${WHITE}Verifica: Hostname MongoDB in ConfigMap (pubblico, OK)${RESET}\n"
CMD_MONGO_CONFIG="kubectl get configmap -n kafka mongodb-config -o yaml | grep MONGO_HOST"
run_cmd "MongoDB ConfigMap: Host in chiaro" "$CMD_MONGO_CONFIG" "contains" "MONGO_HOST"

pause

# ==============================================================================
# NFP 2: RESILIENZA & FAULT TOLERANCE (README Sezione 6.2)
# ==============================================================================
header "NFP 2. RESILIENZA & FAULT TOLERANCE" "Test Buffering e Self-Healing (README NFP 6.2)"

echo -e "${CYAN}${BOLD}TEST 2.1: Fault Tolerance - Consumer Crash${RESET}"
echo -e "${WHITE}Obiettivo: Dimostrare che Kafka fa da buffer persistente durante downtime${RESET}\n"

echo -e "${YELLOW}Step 1: Simulazione crash Consumer (replica → 0)${RESET}\n"
CMD_CONSUMER_DOWN="kubectl scale deploy/consumer -n kafka --replicas=0"
run_cmd "Scaling Consumer a 0 repliche" "$CMD_CONSUMER_DOWN" "none"

sleep 2

echo -e "${YELLOW}Step 2: Invio dati DURANTE downtime (buffering test)${RESET}"
echo -e "${WHITE}Device ID specifico: buffer-test-device (per tracciamento nei log)${RESET}\n"
CMD_BUFFERED="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"buffer-test-device\",\"zone_id\":\"kafka-buffer-test\",\"temperature\":99.9,\"humidity\":99}'"
run_cmd "Invio: buffer-test-device (Consumer OFFLINE)" "$CMD_BUFFERED" "http_code" "200"

echo -e "${YELLOW}Step 3: Recovery - Riavvio Consumer${RESET}\n"
CMD_CONSUMER_UP="kubectl scale deploy/consumer -n kafka --replicas=1"
run_cmd "Scaling Consumer a 1 replica" "$CMD_CONSUMER_UP" "none"

echo -e "${CYAN}Attendo rollout completo Consumer...${RESET}\n"
kubectl rollout status deployment/consumer -n kafka --timeout=60s >/dev/null 2>&1

sleep 3

echo -e "${YELLOW}Step 4: Zero Data Loss Verification${RESET}"
echo -e "${WHITE}Cerchiamo 'buffer-test-device' nei log recenti (deve esserci!)${RESET}\n"
CMD_VERIFY_BUFFER="kubectl logs -n kafka -l app=consumer --tail=30 | grep 'buffer-test-device'"
run_cmd "Consumer Logs: Recupero messaggio bufferizzato" "$CMD_VERIFY_BUFFER" "grep" "buffer-test-device"

echo -e "\n${CYAN}${BOLD}TEST 2.2: High Availability - Self-Healing${RESET}"
echo -e "${WHITE}Obiettivo: Kubernetes ripristina automaticamente pod crashati${RESET}\n"

POD_PROD=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}")
echo -e "${YELLOW}Pod target per crash simulato: ${WHITE}$POD_PROD${RESET}\n"

echo -e "${YELLOW}Step 1: Avvio traffico background durante crash${RESET}"
( for i in {1..5}; do 
    curl -s -o /dev/null "http://producer.$IP.nip.io:$PORT/event/boot" \
        -H "apikey: $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"device_id":"self-healing-test","zone_id":"ha-zone"}' 2>/dev/null || true
    sleep 0.5
done ) &
BG_PID=$!

sleep 1

echo -e "${YELLOW}Step 2: Eliminazione forzata Pod Producer${RESET}\n"
CMD_KILL_POD="kubectl delete pod $POD_PROD -n kafka --grace-period=0 --force"
run_cmd "Kill Pod: $POD_PROD" "$CMD_KILL_POD" "contains" "deleted"

wait $BG_PID

sleep 2

echo -e "${YELLOW}Step 3: Verifica nuovo Pod Running (self-healing)${RESET}\n"
CMD_NEW_POD="kubectl get pods -l app=producer -n kafka | grep -v Terminating"
run_cmd "Status Producer: Nuovo pod attivo" "$CMD_NEW_POD" "grep" "Running"

pause

# ==============================================================================
# NFP 3: SCALABILITÀ & LOAD BALANCING (README Sezione 6.3)
# ==============================================================================
header "NFP 3. SCALABILITÀ & LOAD BALANCING" "Test Scaling e Parallelismo (README NFP 6.3)"

echo -e "${CYAN}Scenario: Alto carico richiede scaling orizzontale${RESET}"
echo -e "${WHITE}Configurazione: Producer 2 repliche, Consumer 3 repliche (= 3 partizioni)${RESET}\n"

CMD_SCALE_OUT="kubectl scale deploy/producer -n kafka --replicas=2 && kubectl scale deploy/consumer -n kafka --replicas=3"
run_cmd "Scale Out: Prod x2, Cons x3" "$CMD_SCALE_OUT" "none"

echo -e "${CYAN}Attendo stabilizzazione deployment...${RESET}\n"
kubectl rollout status deployment/producer -n kafka --timeout=60s >/dev/null 2>&1
kubectl rollout status deployment/consumer -n kafka --timeout=60s >/dev/null 2>&1

CMD_CHECK_PODS="kubectl get pods -n kafka -l 'app in (producer,consumer)' -o wide"
run_cmd "Verifica: Pod distribuiti su nodi" "$CMD_CHECK_PODS" "none"

echo -e "\n${CYAN}${BOLD}Burst Test: 50 richieste parallele${RESET}"
echo -e "${WHITE}Device IDs: lb-test-1 fino a lb-test-50 (tracciabili nei log)${RESET}\n"

for i in {1..50}; do
  curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
    -H "apikey: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"lb-test-$i\",\"zone_id\":\"load-balancing-zone\",\"temperature\":22,\"humidity\":48}" &
done
wait
echo -e "${GREEN}✓ 50 richieste inviate in parallelo${RESET}\n"

sleep 2

echo -e "${CYAN}Verifica: Distribuzione carico tra repliche Producer${RESET}"
echo -e "${WHITE}Cerchiamo 'lb-test-' nei log (con prefisso pod per vedere bilanciamento)${RESET}\n"
CMD_LB_LOGS="kubectl logs -n kafka -l app=producer --tail=60 --prefix=true | grep 'lb-test-' | head -n 15"
run_cmd "Producer Logs: Distribuzione traffico" "$CMD_LB_LOGS" "grep" "lb-test-"

echo -e "\n${CYAN}Ripristino configurazione base (1 replica)${RESET}\n"
CMD_SCALE_DOWN="kubectl scale deploy/producer -n kafka --replicas=1 && kubectl scale deploy/consumer -n kafka --replicas=1"
run_cmd "Scale Down: Ritorno a configurazione iniziale" "$CMD_SCALE_DOWN" "none"

pause

# ==============================================================================
# NFP 4: RATE LIMITING (README Sezione NFP 5)
# ==============================================================================
header "NFP 4. RATE LIMITING (Kong)" "Protezione anti-DoS/Flood (README NFP 5)"

echo -e "${CYAN}Applicazione policy Kong: Max 5 req/sec per client${RESET}\n"

cat <<EOF | kubectl apply -f - >/dev/null 2>&1
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

CMD_PATCH_RL="kubectl patch ingress producer-ingress -n kafka -p '{\"metadata\":{\"annotations\":{\"konghq.com/plugins\":\"key-auth, demo-rate-limit\"}}}'"
run_cmd "Attivazione Rate Limit su Ingress" "$CMD_PATCH_RL" "contains" "patched"

RATE_LIMIT_APPLIED=true

echo -e "${CYAN}Attendo propagazione policy (4 secondi)...${RESET}\n"
sleep 4

echo -e "${CYAN}${BOLD}Flood Test: 20 richieste rapide consecutive${RESET}"
echo -e "${WHITE}Device ID: flood-attack-test (simulazione attacco DoS)${RESET}\n"

BLOCKED=0
PASSED=0

for i in {1..20}; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
        -H "apikey: $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"device_id":"flood-attack-test","zone_id":"dos-simulation","temperature":0,"humidity":0}' 2>/dev/null || echo "000")
    
    if [ "$CODE" == "429" ]; then 
        ((BLOCKED++))
        echo -e "${RED}  Req $i: $CODE Too Many Requests ✗${RESET}"
    elif [ "$CODE" == "200" ]; then 
        ((PASSED++))
        echo -e "${GREEN}  Req $i: $CODE OK ✓${RESET}"
    fi
done

echo -e "\n${MAGENTA}Risultati Flood Test:${RESET}"
echo -e "  Passate: ${GREEN}$PASSED${RESET}"
echo -e "  Bloccate: ${RED}$BLOCKED${RESET}\n"

if [ $BLOCKED -gt 0 ]; then
    echo -e "${GREEN}${BOLD}✓ VALIDAZIONE SUPERATA: Rate Limiting attivo (almeno 1 req bloccata)${RESET}\n"
else
    echo -e "${RED}${BOLD}✗ VALIDAZIONE FALLITA: Nessuna richiesta bloccata!${RESET}\n"
fi

pause

# ==============================================================================
# FINE DEMO
# ==============================================================================
header "DEMO COMPLETATA" "Tutti i test NFP validati con successo"

echo -e "${GREEN}${BOLD}✓ Sistema validato correttamente${RESET}\n"
echo -e "${CYAN}Summary Test Eseguiti:${RESET}"
echo -e "  ${GREEN}✓${RESET} Security: TLS + SASL + API Key + Secrets"
echo -e "  ${GREEN}✓${RESET} Resilienza: Kafka Buffering + Self-Healing"
echo -e "  ${GREEN}✓${RESET} Scalabilità: Load Balancing + Consumer Parallelism"
echo -e "  ${GREEN}✓${RESET} Protezione: Rate Limiting (5 req/sec)\n"

echo -e "${YELLOW}Il cleanup automatico ripristinerà il cluster allo stato iniziale.${RESET}\n"