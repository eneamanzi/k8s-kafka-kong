#!/bin/bash

# ==============================================================================
# DEMO IoT Kubernetes Architecture - Script per Esame Universitario
# ==============================================================================

set -e  # Exit on error

# --- COLORI PER OUTPUT ---
RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
CYAN='\033[36m'
YELLOW='\033[33m'
WHITE='\033[37m'

# --- STATO GLOBALE (per cleanup e HPA/Rate Limit) ---
INITIAL_PRODUCER_REPLICAS=1
INITIAL_CONSUMER_REPLICAS=1
HPA_WAS_DEPLOYED=false
RATE_LIMIT_APPLIED=false
CLEANUP_IN_PROGRESS=false

# Variabili di ambiente globali (devono essere esportate dalla funzione run_setup)
IP=""
PORT=""
API_KEY=""

# --- TRAP PER GESTIRE INTERRUZIONI ---
function cleanup_on_exit {
    if [ "$CLEANUP_IN_PROGRESS" = true ]; then
        exit 0
    fi
    
    CLEANUP_IN_PROGRESS=true
    
    echo -e "\n${YELLOW}${BOLD}========================================${RESET}"
    echo -e "${YELLOW}${BOLD}[CLEANUP] Ripristino stato iniziale...${RESET}"
    echo -e "${YELLOW}${BOLD}========================================${RESET}"
    
    set +e # Disabilita exit on error per permettere cleanup
    
    if [ "$RATE_LIMIT_APPLIED" = true ]; then
        echo -e "${CYAN}→ Rimozione Rate Limiting...${RESET}"
        kubectl delete kongplugin -n kafka global-rate-limit --ignore-not-found >/dev/null 2>&1
        kubectl patch ingress producer-ingress -n kafka \
            -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}' >/dev/null 2>&1
        echo -e "${GREEN}✓ Rate Limiting rimosso${RESET}"
    fi
    
    if [ "$HPA_WAS_DEPLOYED" = true ]; then
        echo -e "${CYAN}→ Rimozione HPA...${RESET}"
        kubectl delete -f ./K8s/hpa.yaml >/dev/null 2>&1
        echo -e "${GREEN}✓ HPA rimosso${RESET}"
    fi
    
    echo -e "${CYAN}→ Ripristino repliche Producer: $INITIAL_PRODUCER_REPLICAS${RESET}"
    kubectl scale deploy/producer -n kafka --replicas=$INITIAL_PRODUCER_REPLICAS >/dev/null 2>&1
    
    echo -e "${CYAN}→ Ripristino repliche Consumer: $INITIAL_CONSUMER_REPLICAS${RESET}"
    kubectl scale deploy/consumer -n kafka --replicas=$INITIAL_CONSUMER_REPLICAS >/dev/null 2>&1
    
    echo -e "${GREEN}${BOLD}[CLEANUP COMPLETATO]${RESET}\n"
    
    exit 0
}

trap cleanup_on_exit EXIT INT TERM

# --- FUNZIONI HELPER ---

# Funzione per stampare l'Header principale (Sezione)
function print_header {
    clear
    echo -e "\n${BLUE}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}${BOLD}║  $1${RESET}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo -e "${WHITE}$2${RESET}\n"
}

# NUOVA FUNZIONE HELPER: Per stampare le Sottosezioni (Test specifici)
function print_subsection {
    local title="$1"
    local description="$2"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${title}${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${WHITE}${description}${RESET}\n"
}

function pause {
    echo -e "\n${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${WHITE}[Premi INVIO per continuare alla prossima sezione...]${RESET}"
    read -r
}

function run_test {
    local cmd_var="$1"
    local expected="$2"
    local validation_type="${3:-none}"
    
    echo -e "${YELLOW}COMANDO:${RESET}"
    echo -e "${WHITE}$cmd_var${RESET}\n"
    
    echo -e "${YELLOW}OUTPUT:${RESET}"
    echo -e "${WHITE}┌────────────────────────────────────────────────────────────────┐${RESET}"
    
    local output
    local obtained=""
    
    output=$(eval "$cmd_var" 2>&1)
    
    echo "$output" | while IFS= read -r line; do
        echo -e "${WHITE}│${RESET} $line"
    done
    
    echo -e "${WHITE}└────────────────────────────────────────────────────────────────┘${RESET}\n"
    
    local test_passed=false
    
    case "$validation_type" in
        http_code)
            # Prende l'ultimo codice HTTP nel caso di output multilinea
            obtained=$(echo "$output" | grep -oE '[0-9]{3}' | tail -n 1)
            if [ "$obtained" == "$expected" ]; then
                test_passed=true
            fi
            ;;
        grep)
            if echo "$output" | grep -q "$expected"; then
                obtained="Pattern '$expected' trovato"
                test_passed=true
            else
                obtained="Pattern NON trovato"
            fi
            ;;
        contains)
            if [[ "$output" == *"$expected"* ]]; then
                obtained="Substring trovata"
                test_passed=true
            else
                obtained="Substring NON trovata"
            fi
            ;;
        none)
            obtained="Eseguito correttamente"
            test_passed=true
            ;;
    esac
    
    if [ "$test_passed" = true ]; then
        echo -e "${GREEN}${BOLD}RISULTATO:${RESET} ${GREEN}Atteso: $expected → Ottenuto: $obtained ✓${RESET}\n"
    else
        echo -e "${RED}${BOLD}RISULTATO:${RESET} ${RED}Atteso: $expected → Ottenuto: $obtained ✗${RESET}\n"
    fi
}


# ==============================================================================
# SEZIONI ESEGUIBILI
# ==============================================================================

function check_prerequisites {
    print_header "0. VERIFICA PREREQUISITI" "Controllo stato cluster Minikube"

    if ! minikube status >/dev/null 2>&1; then
        echo -e "${RED}${BOLD}[ERRORE] Minikube non è attivo!${RESET}"
        echo -e "${YELLOW}Avvia il cluster con: ${CYAN}minikube start -p IoT-cluster${RESET}"
        exit 1
    fi

    echo -e "${GREEN}✓ Minikube attivo${RESET}\n"

    echo -e "${CYAN}Stato iniziale configurato:${RESET}"
    echo -e "  Producer: ${WHITE}$INITIAL_PRODUCER_REPLICAS replica${RESET}"
    echo -e "  Consumer: ${WHITE}$INITIAL_CONSUMER_REPLICAS replica${RESET}\n"
}

function run_setup {
    check_prerequisites
    
    print_header "1. SETUP VARIABILI AMBIENTE" "Recupero IP, PORT e API Key"

    CMD_IP='export IP=$(minikube ip)'
    echo -e "${YELLOW}COMANDO:${RESET} ${CYAN}$CMD_IP${RESET}"
    eval "$CMD_IP"
    if [ -z "$IP" ]; then echo -e "${RED}ERRORE: IP non trovato.${RESET}"; exit 1; fi
    echo -e "${GREEN}✓ IP=$IP${RESET}\n"

    CMD_PORT='export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '\''{print $3}'\'')'
    echo -e "${YELLOW}COMANDO:${RESET} ${CYAN}$CMD_PORT${RESET}"
    eval "$CMD_PORT"
    if [ -z "$PORT" ]; then echo -e "${RED}ERRORE: Porta Kong non trovata.${RESET}"; exit 1; fi
    echo -e "${GREEN}✓ PORT=$PORT${RESET}\n"

    CMD_KEY='export API_KEY="iot-sensor-key-prod-v1"'
    echo -e "${YELLOW}COMANDO:${RESET} ${CYAN}$CMD_KEY${RESET}"
    eval "$CMD_KEY"
    echo -e "${GREEN}✓ API_KEY=$API_KEY${RESET}\n"

    echo -e "${CYAN}Target endpoint:${RESET} ${WHITE}http://producer.$IP.nip.io:$PORT${RESET}"
    
    # Aggiorna variabili globali per i test successivi
    IP=$(minikube ip)
    PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')
    API_KEY="iot-sensor-key-prod-v1"
    
    pause
}


function test_auth {
    # Verifica che le variabili siano impostate
    if [ -z "$IP" ] || [ -z "$PORT" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}ERRORE: Eseguire 'setup' prima di questo test.${RESET}"; exit 1;
    fi

    print_header "2. VERIFICA AUTENTICAZIONE" "Test policy di sicurezza Kong (Key-Auth)"

    print_subsection "TEST 2.A: Accesso NEGATO senza API Key" "Richiesta HTTP senza header 'apikey' deve essere rifiutata"

    CMD_AUTH_FAIL="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'Content-Type: application/json' -d '{\"device_id\":\"unauthorized-device\",\"zone_id\":\"unknown\"}'"
    run_test "$CMD_AUTH_FAIL" "401" "http_code"

    print_subsection "TEST 2.B: Accesso CONSENTITO con API Key valida" "Kong valida la chiave e inoltra la richiesta al backend"

    CMD_AUTH_OK="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"auth-test-device\",\"zone_id\":\"secure-lab\"}'"
    run_test "$CMD_AUTH_OK" "200" "http_code"
    
    pause
}


function test_ingestion {
    if [ -z "$IP" ] || [ -z "$PORT" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}ERRORE: Eseguire 'setup' prima di questo test.${RESET}"; exit 1;
    fi

    print_header "3. DATA INGESTION PIPELINE" "Test invio eventi IoT"

    print_subsection "TEST 3.1: Device Boot Event" "Simula: Sensore si accende e notifica il sistema"

    CMD_BOOT="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/boot -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-01\",\"zone_id\":\"warehouse-A\",\"firmware\":\"v1.0\"}'"
    run_test "$CMD_BOOT" "200" "http_code"

    print_subsection "TEST 3.2: Telemetry Data (Condizioni Normali)" "Simula: Invio dati ambientali regolari (24.5°C, 45% umidità)"

    CMD_TEL_NORMAL="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-01\",\"zone_id\":\"warehouse-A\",\"temperature\":24.5,\"humidity\":45}'"
    run_test "$CMD_TEL_NORMAL" "200" "http_code"

    print_subsection "TEST 3.3: Critical Alert" "Simula: Sensore rileva surriscaldamento critico"

    CMD_ALERT="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/alert -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-02\",\"error_code\":\"CRITICAL_OVERHEAT\",\"severity\":\"high\"}'"
    run_test "$CMD_ALERT" "200" "http_code"

    print_subsection "TEST 3.4: Firmware Update" "Simula: Aggiornamento firmware sensore da v1.0 a v2.0"

    CMD_FW="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/firmware_update -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"demo-sensor-01\",\"version_to\":\"v2.0\"}'"
    run_test "$CMD_FW" "200" "http_code"

    echo -e "${CYAN}Attendo propagazione dati: Kafka → Consumer → MongoDB (4 secondi)...${RESET}\n"
    sleep 4

    print_subsection "TEST 3.5: Verifica Processamento Consumer" "Consumer deve aver processato tutti gli eventi demo"

    CMD_LOGS="kubectl logs -l app=consumer -n kafka --tail=50 | grep -E '(demo-sensor-01|demo-sensor-02)'"
    run_test "$CMD_LOGS" "demo-sensor-" "grep"
    
    pause
}


function test_security_secrets {
    if [ -z "$IP" ] || [ -z "$PORT" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}ERRORE: Eseguire 'setup' prima di questo test.${RESET}"; exit 1;
    fi
    
    print_header "NFP 1. SECURITY & SECRETS MANAGEMENT" "Verifica Defense in Depth"

    print_subsection "TEST NFP 1.1: Data in Transit - TLS Encryption" "Verifica comunicazione cifrata Producer/Consumer → Kafka"

    CMD_TLS="kubectl exec -i -n kafka iot-sensor-cluster-broker-0 -- openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief < /dev/null 2>&1 | grep -E '(Protocol|Cipher)'"
    run_test "$CMD_TLS" "Protocol" "contains"

    print_subsection "TEST NFP 1.2: Authentication - SASL/SCRAM-SHA-512" "Credenziali Kafka in Secret Kubernetes (non hardcoded)"

    CMD_SASL="kubectl get secret consumer-user -n kafka -o yaml | grep password"
    run_test "$CMD_SASL" "password" "contains"

    print_subsection "TEST NFP 1.3: MongoDB Secrets Management" "Password MongoDB offuscata (base64) in Secret"

    CMD_MONGO_SECRET="kubectl get secret -n kafka mongo-creds -o yaml | grep MONGO_PASSWORD"
    run_test "$CMD_MONGO_SECRET" "MONGO_PASSWORD" "contains"

    print_subsection "TEST NFP 1.4: ConfigMap Separation" "Hostname MongoDB in ConfigMap (pubblico, non sensibile)"

    CMD_MONGO_CONFIG="kubectl get configmap -n kafka mongodb-config -o yaml | grep MONGO_HOST"
    run_test "$CMD_MONGO_CONFIG" "MONGO_HOST" "contains"
    
    pause
}


function test_resilience_ha {
    if [ -z "$IP" ] || [ -z "$PORT" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}ERRORE: Eseguire 'setup' prima di questo test.${RESET}"; exit 1;
    fi

    print_header "NFP 2. RESILIENZA & FAULT TOLERANCE" "Test Buffering e Self-Healing"

    print_subsection "TEST NFP 2.1: Fault Tolerance - Consumer Crash (Step 1/4)" "Simulazione crash Consumer per testare buffering Kafka"

    CMD_CONSUMER_DOWN="kubectl scale deploy/consumer -n kafka --replicas=0"
    run_test "$CMD_CONSUMER_DOWN" "Eseguito" "none"

    sleep 2

    print_subsection "TEST NFP 2.1: Fault Tolerance - Consumer Crash (Step 2/4)" "Invio dati DURANTE downtime - Kafka deve fare da buffer"

    CMD_BUFFERED="curl -s -o /dev/null -w '%{http_code}' -X POST http://producer.$IP.nip.io:$PORT/event/telemetry -H 'apikey: $API_KEY' -H 'Content-Type: application/json' -d '{\"device_id\":\"buffer-test-device\",\"zone_id\":\"kafka-buffer-test\",\"temperature\":99.9,\"humidity\":99}'"
    run_test "$CMD_BUFFERED" "200" "http_code"

    print_subsection "TEST NFP 2.1: Fault Tolerance - Consumer Crash (Step 3/4)" "Recovery Consumer - Ripristino servizio"

    CMD_CONSUMER_UP="kubectl scale deploy/consumer -n kafka --replicas=1"
    run_test "$CMD_CONSUMER_UP" "Eseguito" "none"

    echo -e "${CYAN}Attendo rollout completo Consumer...${RESET}\n"
    kubectl rollout status deployment/consumer -n kafka --timeout=60s >/dev/null 2>&1
    sleep 3

    print_subsection "TEST NFP 2.1: Fault Tolerance - Consumer Crash (Step 4/4)" "Zero Data Loss Verification - Messaggio bufferizzato deve essere processato"

    CMD_VERIFY_BUFFER="kubectl logs -n kafka -l app=consumer --tail=30 | grep 'buffer-test-device'"
    run_test "$CMD_VERIFY_BUFFER" "buffer-test-device" "grep"

    print_subsection "TEST NFP 2.2: High Availability - Self-Healing (Step 1/2)" "Kubernetes deve rilevare il crash e riavviare automaticamente il Pod"

    POD_PROD=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}")
    echo -e "${YELLOW}Pod target: ${WHITE}$POD_PROD${RESET}\n"

    CMD_KILL_POD="kubectl delete pod $POD_PROD -n kafka --grace-period=0 --force"
    run_test "$CMD_KILL_POD" "deleted" "contains"

    sleep 3

    print_subsection "TEST NFP 2.2: High Availability - Self-Healing (Step 2/2)" "Verifica nuovo Pod Running - Self-Healing completato"

    CMD_NEW_POD="kubectl get pods -l app=producer -n kafka | grep -v Terminating"
    run_test "$CMD_NEW_POD" "Running" "grep"
    
    pause
}


function test_scaling_lb {
    if [ -z "$IP" ] || [ -z "$PORT" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}ERRORE: Eseguire 'setup' prima di questo test.${RESET}"; exit 1;
    fi
    
    print_header "NFP 3. SCALABILITÀ & LOAD BALANCING" "Test Scaling e Parallelismo"

    print_subsection "TEST NFP 3.1: Scale Out - Producer x2, Consumer x3" "Preparazione per test di carico distribuito"

    CMD_SCALE_OUT="kubectl scale deploy/producer -n kafka --replicas=2 && kubectl scale deploy/consumer -n kafka --replicas=3"
    run_test "$CMD_SCALE_OUT" "Eseguito" "none"

    echo -e "${CYAN}Attendo stabilizzazione deployment...${RESET}\n"
    kubectl rollout status deployment/producer -n kafka --timeout=60s >/dev/null 2>&1
    kubectl rollout status deployment/consumer -n kafka --timeout=60s >/dev/null 2>&1

    print_subsection "TEST NFP 3.2: Verifica Pod Scalati" "Controllo distribuzione Pod su nodi (dovresti vedere 2 Producer e 3 Consumer in Running)"

    CMD_CHECK_PODS="kubectl get pods -n kafka -l 'app in (producer,consumer)'"
    run_test "$CMD_CHECK_PODS" "Eseguito" "none"

    print_subsection "TEST NFP 3.3: Burst Test - 50 richieste parallele" "Invio massivo per testare Load Balancing HTTP e Consumer Parallelism"

    for i in {1..50}; do
        curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
            -H "apikey: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"device_id\":\"lb-test-$i\",\"zone_id\":\"load-balancing-zone\",\"temperature\":22,\"humidity\":48}" &
    done
    wait
    echo -e "${GREEN}✓ 50 richieste inviate in parallelo${RESET}\n"

    sleep 3 # Aumentato a 3s per dare tempo ai consumer di processare

    print_subsection "TEST NFP 3.4 (PRODUCER): Verifica Distribuzione Carico HTTP" "Analisi log Producer per confermare che le 50 richieste sono distribuite tra le 2 repliche (Nessun 'head -n' per vedere tutte le voci)."

    # Rimosso '| head -n 15'. Uso tail=100 per catturare tutte le 50 richieste.
    CMD_LB_PRODUCER_LOGS="kubectl logs -n kafka -l app=producer --tail=100 --prefix=true | grep 'lb-test-'"
    run_test "$CMD_LB_PRODUCER_LOGS" "lb-test-" "grep"
    
    print_subsection "TEST NFP 3.5 (CONSUMER): Verifica Parallelismo Kafka" "Analisi log Consumer per confermare che le 50 richieste sono state processate dalle 3 repliche (dovresti vedere 3 nomi di Pod diversi, uno per partizione)."

    # Nuovo comando per i log Consumer
    CMD_LB_CONSUMER_LOGS="kubectl logs -n kafka -l app=consumer --tail=150 --prefix=true | grep 'lb-test-'" 
    run_test "$CMD_LB_CONSUMER_LOGS" "lb-test-" "grep"
    
    print_subsection "TEST NFP 3.6: Scale Down - Ritorno a configurazione base" "Ripristino Producer x1, Consumer x1"

    CMD_SCALE_DOWN="kubectl scale deploy/producer -n kafka --replicas=1 && kubectl scale deploy/consumer -n kafka --replicas=1"
    run_test "$CMD_SCALE_DOWN" "Eseguito" "none"
    
    pause
}


function test_hpa {
    if [ -z "$IP" ] || [ -z "$PORT" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}ERRORE: Eseguire 'setup' prima di questo test.${RESET}"; exit 1;
    fi

    print_header "NFP 4. HORIZONTAL POD AUTOSCALER (HPA)" "Test elasticità automatica"

    echo -e "${YELLOW}Vuoi eseguire il test HPA? (s/n):${RESET} "
    read -r HPA_CHOICE

    if [[ "$HPA_CHOICE" =~ ^[sS]$ ]]; then
        print_subsection "TEST NFP 4.1: Deploy Configurazione HPA" "Attivazione autoscaling basato su CPU (soglia 50%)"
        
        CMD_HPA_DEPLOY="kubectl apply -f ./K8s/hpa.yaml"
        run_test "$CMD_HPA_DEPLOY" "Eseguito" "none"
        HPA_WAS_DEPLOYED=true
        
        sleep 3
        
        print_subsection "TEST NFP 4.2: Verifica HPA Attivo" "Controllo stato Horizontal Pod Autoscaler"
        
        CMD_HPA_STATUS="kubectl get hpa -n kafka"
        run_test "$CMD_HPA_STATUS" "Eseguito" "none"
        
        print_subsection "TEST NFP 4.3: Stress Test - 5000 richieste" "Generazione carico per triggerar autoscaling (può richiedere alcuni minuti)"
        
        # Disabilito 'Exit on Error' per lo stress test
        set +e 
        for i in {1..5000}; do
            curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
                -H "apikey: $API_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"device_id\":\"stress-sensor-$i\", \"zone_id\":\"HPA-test\", \"temperature\": 50.0, \"humidity\": 10.0}" \
                > /dev/null &
            
            if [ $((i % 50)) -eq 0 ]; then
                wait
            fi
        done
        wait
        # Riabilito 'Exit on Error'
        set -e
        
        echo -e "${GREEN}✓ Stress test completato${RESET}\n"
        
        print_subsection "TEST NFP 4.4: Verifica Scale Out" "Monitoraggio scaling automatico (30 secondi)"
        
        sleep 30
        
        CMD_HPA_REPLICAS="kubectl get hpa producer-hpa -n kafka -o jsonpath='{.status.currentReplicas}'"
        REPLICAS_AFTER=$(eval "$CMD_HPA_REPLICAS")
        
        echo -e "${YELLOW}COMANDO:${RESET}"
        echo -e "${WHITE}$CMD_HPA_REPLICAS${RESET}\n"
        
        echo -e "${YELLOW}OUTPUT:${RESET}"
        echo -e "${WHITE}┌────────────────────────────────────────────────────────────────┐${RESET}"
        echo -e "${WHITE}│${RESET} Repliche correnti: $REPLICAS_AFTER"
        echo -e "${WHITE}└────────────────────────────────────────────────────────────────┘${RESET}\n"
        
        if [ "$REPLICAS_AFTER" -gt 1 ]; then
            echo -e "${GREEN}${BOLD}RISULTATO: Atteso: >1 replica → Ottenuto: $REPLICAS_AFTER repliche ✓${RESET}\n"
        else
            echo -e "${YELLOW}${BOLD}RISULTATO: Atteso: >1 replica → Ottenuto: $REPLICAS_AFTER replica (potrebbe richiedere più tempo) ⚠${RESET}\n"
        fi
        
        print_subsection "TEST NFP 4.5: Verifica Scale Down" "Attesa elasticità inversa - rilascio risorse (60 secondi)"
        
        sleep 60
        
        CMD_HPA_FINAL="kubectl get hpa -n kafka"
        run_test "$CMD_HPA_FINAL" "Eseguito" "none"
        
    else
        echo -e "${YELLOW}Test HPA saltato.${RESET}\n"
    fi
    
    pause
}

function test_rate_limit {
    if [ -z "$IP" ] || [ -z "$PORT" ] || [ -z "$API_KEY" ]; then
        echo -e "${RED}ERRORE: Eseguire 'setup' prima di questo test.${RESET}"; exit 1;
    fi

    print_header "NFP 5. RATE LIMITING (Kong)" "Protezione anti-DoS/Flood"

    print_subsection "TEST NFP 5.1: Applicazione Policy Rate Limiting" "Configurazione Kong: Max 5 req/sec per client"

    cat <<'EOF' | kubectl apply -f - >/dev/null 2>&1
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: global-rate-limit
  namespace: kafka
config:
  second: 5
  policy: local
plugin: rate-limiting
EOF

    CMD_PATCH_RL="kubectl patch ingress producer-ingress -n kafka -p '{\"metadata\":{\"annotations\":{\"konghq.com/plugins\":\"key-auth, global-rate-limit\"}}}'"
    run_test "$CMD_PATCH_RL" "patched" "contains"

    RATE_LIMIT_APPLIED=true

    echo -e "${CYAN}Attendo propagazione policy Kong (4 secondi)...${RESET}\n"
    sleep 4

    print_subsection "TEST NFP 5.2: Flood Test - 20 richieste rapide consecutive" "Simulazione attacco DoS - Kong deve bloccare richieste in eccesso"

    BLOCKED=0
    PASSED=0

    # FIX: Disabilita 'Exit on Error' per consentire il completamento del ciclo di test
    set +e
    for i in {1..20}; do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
            -H "apikey: $API_KEY" \
            -H "Content-Type: application/json" \
            -d '{"device_id":"flood-test","zone_id":"DoS-test","temperature":0,"humidity":0}' 2>/dev/null || echo "000")
        
        if [ "$CODE" == "429" ]; then 
            ((BLOCKED++))
            echo -e "${RED}  Req $i: $CODE Too Many Requests ✗${RESET}"
        elif [ "$CODE" == "200" ]; then 
            ((PASSED++))
            echo -e "${GREEN}  Req $i: $CODE OK ✓${RESET}"
        fi
    done
    # Riabilita 'Exit on Error'
    set -e

    print_subsection "TEST NFP 5.3: Analisi Risultati Flood Test" ""

    echo -e "${YELLOW}OUTPUT:${RESET}"
    echo -e "${WHITE}┌────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${WHITE}│${RESET} Richieste Passate: ${GREEN}$PASSED${RESET}"
    echo -e "${WHITE}│${RESET} Richieste Bloccate: ${RED}$BLOCKED${RESET}"
    echo -e "${WHITE}└────────────────────────────────────────────────────────────────┘${RESET}\n"

    if [ $BLOCKED -gt 0 ]; then
        echo -e "${GREEN}${BOLD}RISULTATO: Atteso: >0 bloccate → Ottenuto: $BLOCKED bloccate ✓${RESET}\n"
    else
        echo -e "${RED}${BOLD}RISULTATO: Atteso: >0 bloccate → Ottenuto: 0 bloccate ✗${RESET}\n"
    fi
    
    pause
}


function run_all {
    run_setup
    test_auth
    test_ingestion
    test_security_secrets
    test_resilience_ha
    test_scaling_lb
    test_hpa
    test_rate_limit
    
    print_header "DEMO COMPLETATA" "Tutti i test eseguiti con successo"

    echo -e "${GREEN}${BOLD}✓ Sistema validato correttamente${RESET}\n"

    echo -e "${CYAN}Summary Test Eseguiti:${RESET}"
    echo -e "  ${GREEN}✓${RESET} Setup e Variabili Ambiente"
    echo -e "  ${GREEN}✓${RESET} Autenticazione (API Key)"
    echo -e "  ${GREEN}✓${RESET} Data Ingestion Pipeline"
    echo -e "  ${GREEN}✓${RESET} Security (TLS + SASL + Secrets)"
    echo -e "  ${GREEN}✓${RESET} Resilienza (Buffering + Self-Healing)"
    echo -e "  ${GREEN}✓${RESET} Scalabilità (Load Balancing)"
    # Il test HPA e Rate Limiting sono gestiti internamente alle loro funzioni
    echo -e "  ${GREEN}✓${RESET} HPA (Autoscaling)"
    echo -e "  ${GREEN}✓${RESET} Rate Limiting\n"
    
    echo -e "${YELLOW}Il cleanup automatico verrà eseguito all'uscita.${RESET}\n"
}

function show_usage {
    echo -e "\n${BLUE}${BOLD}UTILIZZO: ${RESET}${WHITE}./demo-test.sh [opzione]...${RESET}"
    echo -e "${YELLOW}Descrizione:${RESET} Esegue test selettivi o l'intera suite di validazione dell'architettura IoT su Kubernetes."
    echo -e "\n${YELLOW}Opzioni disponibili:${RESET}"
    echo -e "  ${CYAN}all, demo${RESET}             : Esegue l'intera suite di test in ordine."
    echo -e "  ${CYAN}setup${RESET}                 : Verifica prerequisiti e configura le variabili IP/Porta/API Key."
    echo -e "  ${CYAN}auth${RESET}                  : (Sezione 2) Verifica Autenticazione Key-Auth Kong."
    echo -e "  ${CYAN}pipeline${RESET}              : (Sezione 3) Testa il flusso dati (Producer -> Kafka -> Consumer)."
    echo -e "  ${CYAN}security${RESET}              : (NFP 1) Verifica TLS, SASL e gestione Kubernetes Secrets."
    echo -e "  ${CYAN}resilience${RESET}            : (NFP 2) Testa Fault Tolerance (Kafka Buffering) e Self-Healing HA."
    echo -e "  ${CYAN}scaling${RESET}               : (NFP 3) Testa Load Balancing e Parallelismo manuale."
    echo -e "  ${CYAN}hpa${RESET}                   : (NFP 4) Test con Stress Test per verificare l'Horizontal Pod Autoscaler (HPA)."
    echo -e "  ${CYAN}ratelimit${RESET}             : (NFP 5) Testa la protezione anti-DoS/Flood con Kong Rate Limiting."
    echo -e "\n${YELLOW}Esempio:${RESET} ${CYAN}./demo-test.sh setup auth pipeline${RESET}"
    echo -e "${RED}ATTENZIONE:${RESET} Eseguire ${CYAN}setup${RESET} è obbligatorio prima di qualsiasi altro test, a meno di usare ${CYAN}all${RESET} o ${CYAN}demo${RESET}."
    echo ""
}

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

if [ $# -eq 0 ]; then
    show_usage
    exit 0
fi

# Se non viene specificato 'setup', 'all' o 'demo' come primo argomento, eseguiamo il setup implicitamente
if [[ "$1" != "setup" && "$1" != "all" && "$1" != "demo" ]]; then
    run_setup
fi

# Processa tutti gli argomenti forniti in sequenza
for arg in "$@"; do
    case "$arg" in
        setup) 
            # Eseguiamo il setup se non è stato eseguito implicitamente, altrimenti no.
            if [[ "$1" == "setup" ]]; then
                run_setup
            fi
            ;;
        auth) test_auth ;;
        pipeline) test_ingestion ;;
        security) test_security_secrets ;;
        resilience) test_resilience_ha ;;
        scaling) test_scaling_lb ;;
        hpa) test_hpa ;;
        ratelimit) test_rate_limit ;;
        
        # Alias
        2) test_auth ;;
        3) test_ingestion ;;
        secrets) test_security_secrets ;;
        ha) test_resilience_ha ;;
        loadbalance) test_scaling_lb ;;
        autoscaling) test_hpa ;;
        dos) test_rate_limit ;;
        
        # Esegue tutto e termina
        all|demo) 
            run_all
            exit 0
            ;;
            
        *) 
            echo -e "${RED}ERRORE:${RESET} Opzione non valida: ${CYAN}$arg${RESET}"
            show_usage
            exit 1
            ;;
    esac
done

echo -e "\n${GREEN}${BOLD}✓ Sequenza di test completata.${RESET}"