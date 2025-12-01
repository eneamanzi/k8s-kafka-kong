# Speech Demo Live - NFP Validation

## PREPARAZIONE DEMO

**Prima di iniziare, assicurarsi:**
- Cluster Minikube running
- Tutti i servizi deployed (Kong, Kafka, MongoDB, Producer, Consumer, Metrics)
- Terminale pronto con font leggibile
- Browser con tab Lens/k9s (opzionale per visualizzazione)

---

## PARTE 1: TEST FUNZIONAMENTO BASE (~5-7 minuti)

### 1.1 Setup Variabili Ambiente

**Speech:**
"Bene, iniziamo la demo. Per prima cosa devo impostare le variabili d'ambiente che userò per tutta la sessione: l'IP del cluster Minikube, la porta esposta da Kong, e l'API Key per l'autenticazione."

**Comandi:**
```bash
export IP=$(minikube ip)
export PORT=$(minikube service kong-kong-proxy -n kong --url | head -n 1 | awk -F: '{print $3}')
export API_KEY="iot-sensor-key-prod-v1"

echo "Target endpoint: $IP:$PORT"
echo "API Key: $API_KEY"
```

**Speech (continuazione):**
"Perfetto. Come vedete, l'IP del mio cluster è [leggi output], Kong è esposto sulla porta [leggi porta], e l'API Key è quella che ho configurato nei Secret Kubernetes."

---

### 1.2 Verifica Autenticazione

**Speech:**
"Ora il primo test fondamentale: verifico che Kong stia effettivamente bloccando richieste non autenticate. Provo a inviare un evento di boot senza l'header API Key."

**Comando:**
```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "Content-Type: application/json" \
  -d '{"device_id": "unauthorized-device", "zone_id": "unknown"}'
```

**Speech (dopo output):**
"Perfetto. Come vedete, ricevo 401 Unauthorized. Kong ha intercettato la richiesta e l'ha bloccata prima ancora che raggiungesse il Producer. Questo è esattamente il comportamento che vogliamo.

Ora rifaccio la stessa richiesta, ma questa volta includo l'header 'apikey' con la chiave valida."

**Comando:**
```bash
curl -i -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "auth-test-device", "zone_id": "secure-lab", "firmware": "v1.0"}'
```

**Speech (dopo output):**
"Eccellente. Questa volta ricevo 200 OK. Kong ha validato la chiave e inoltrato la richiesta al Producer. Nel response body vedete l'evento arricchito con UUID e timestamp - questo è il lavoro del Producer prima di inviarlo a Kafka."

---

### 1.3 Pipeline Ingestione (Esempi Rapidi)

**Speech:**
"Ora invio velocemente un campione di ogni tipo di evento per dimostrare che l'intera pipeline funziona: boot, telemetria, alert e firmware update. Non leggerò tutti gli output, ma vedrete che ricevo sempre 200 OK."

**Comandi rapidi:**
```bash
# Boot Event
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-01","zone_id":"warehouse-A","firmware":"v1.0"}' \
  && echo " ✓ Boot event sent"

# Telemetry Event
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
  -H "apikey: $API_KEY" -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-01","zone_id":"warehouse-A","temperature":24.5,"humidity":45}' \
  && echo " ✓ Telemetry sent"

# Alert Event
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/alert \
  -H "apikey: $API_KEY" -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-02","error_code":"CRITICAL_OVERHEAT","severity":"high"}' \
  && echo " ✓ Alert sent"

# Firmware Update
curl -s -X POST http://producer.$IP.nip.io:$PORT/event/firmware_update \
  -H "apikey: $API_KEY" -H "Content-Type: application/json" \
  -d '{"device_id":"demo-sensor-01","version_to":"v2.0"}' \
  && echo " ✓ Firmware update sent"
```

**Speech (dopo invio):**
"Bene, ho inviato 4 eventi. Diamo qualche secondo al Consumer per processarli."

```bash
sleep 3
```

**Speech (continuazione):**
"Ora controllo i log del Consumer per verificare che abbia effettivamente processato questi messaggi."

**Comando:**
```bash
kubectl logs -l app=consumer -n kafka --tail=20 | grep -E "(demo-sensor-01|demo-sensor-02)"
```

**Speech (leggendo output):**
"Perfetto. Vedete qui i log: [indicare sullo schermo] il Consumer ha ricevuto tutti e 4 gli eventi, li ha processati correttamente distinguendo per tipo - boot, telemetry, alert, firmware_update - e li ha salvati su MongoDB. 

La pipeline base funziona. Ora passiamo alla parte interessante: la validazione delle proprietà non funzionali."

---

## PARTE 2: VALIDAZIONE NFP (~15-20 minuti)

### NFP 1: SECURITY & SECRETS MANAGEMENT (~3 min)

**Speech:**
"Iniziamo con la sicurezza. Ho implementato Defense in Depth su tre livelli: TLS per la cifratura del canale, SASL per l'autenticazione, e gestione secrets tramite Kubernetes. Vediamoli uno per uno.

**Test 1A: Verifica TLS sulla comunicazione Kafka.**

Mi collego al pod broker di Kafka e verifico la cifratura TLS sulla porta 9093."

**Comando:**
```bash
kubectl exec -it -n kafka iot-sensor-cluster-broker-0 -- \
  openssl s_client -connect iot-sensor-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093 -brief </dev/null 2>&1 | grep -E "(Protocol|Cipher)"
```

**Speech (dopo output):**
"Eccellente. Vedete qui che la connessione usa TLSv1.3 con cipher suite [leggere output]. Questo conferma che tutto il traffico tra Producer/Consumer e Kafka viaggia cifrato.

**Test 1B: Verifica gestione credenziali SASL.**

Le password SASL non sono hardcoded nel codice - sono gestite tramite Secret Kubernetes. Verifico il secret del Consumer."

**Comando:**
```bash
kubectl get secret consumer-user -n kafka -o yaml | grep password
```

**Speech (dopo output):**
"Come vedete, il campo password esiste ed è codificato in base64. Non è in chiaro, e soprattutto questo Secret è stato generato automaticamente dall'operator Strimzi quando ho creato la risorsa KafkaUser. I microservizi leggono questa password tramite variabili d'ambiente montate dal Secret.

**Test 1C: Verifica separazione ConfigMap/Secret per MongoDB.**

Ora mostro la separazione tra configurazione pubblica e credenziali sensibili."

**Comandi:**
```bash
# Configurazione pubblica
kubectl get configmap -n kafka mongodb-config -o yaml | grep "MONGO_HOST"

# Credenziali sensibili
kubectl get secret -n kafka mongo-creds -o yaml | grep "MONGO_PASSWORD"
```

**Speech (dopo output):**
"Vedete la distinzione: l'hostname MongoDB è nella ConfigMap, visibile in chiaro - va bene, non è sensibile. La password invece è nel Secret, codificata in base64. Questo rispetta il principio 12-factor di separare configurazione da segreti."

---

### NFP 2: RESILIENCE & FAULT TOLERANCE (~5 min)

**Speech:**
"Passiamo ora alla resilienza. Dimostrerò due proprietà: Fault Tolerance, cioè la capacità di non perdere dati durante un failure, e High Availability tramite self-healing.

**Test 2A: Fault Tolerance - Consumer Crash.**

Questo è il test più impressionante. Simulerò un crash totale del Consumer scalandolo a zero repliche. Mentre è offline, invierò eventi che verranno bufferizzati su Kafka. Poi riavvierò il Consumer e verificherò che recuperi tutti i messaggi."

**Step 1: Crash del Consumer**

**Comando:**
```bash
kubectl scale deploy/consumer -n kafka --replicas=0
```

**Speech:**
"Ho scalato il Consumer a zero. Verifico che sia effettivamente terminato."

**Comando:**
```bash
kubectl get pods -n kafka -l app=consumer
```

**Speech (dopo output):**
"Perfetto, nessun pod consumer è in esecuzione. Ora invio 5 eventi mentre il Consumer è offline."

**Step 2: Invio eventi durante downtime**

**Comando:**
```bash
for i in {1..5}; do
  curl -s -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
    -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d "{\"device_id\":\"buffer-test-$i\", \"zone_id\":\"fault-tolerance-test\", \"temperature\":99.0, \"humidity\":50}" \
    && echo " ✓ Event $i sent (Consumer OFFLINE)"
done
```

**Speech (dopo invio):**
"Bene, ho inviato 5 eventi. Il Producer ha risposto 200 OK perché lui sta solo inviando a Kafka, non sa che il Consumer è down. Questi messaggi ora sono persistiti su disco nei broker Kafka ma non ancora processati.

**Step 3: Recovery del Consumer**"

**Comando:**
```bash
kubectl scale deploy/consumer -n kafka --replicas=1
```

**Speech:**
"Ho riavviato il Consumer. Aspetto qualche secondo che si connetta a Kafka."

**Comando:**
```bash
kubectl rollout status deployment/consumer -n kafka --timeout=60s
sleep 3
```

**Speech (continuazione):**
"Ora verifico i log. Dovrei vedere il Consumer che drena il buffer, processando i 5 messaggi che erano in attesa."

**Comando:**
```bash
kubectl logs -n kafka -l app=consumer --tail=30 | grep "buffer-test"
```

**Speech (leggendo output):**
"Eccellente! Vedete qui: [indicare] buffer-test-1, buffer-test-2, fino a buffer-test-5. Tutti e 5 i messaggi sono stati processati. Zero perdita di dati. Questo dimostra che Kafka ha agito da buffer persistente durante il downtime, e il Consumer ha ripreso esattamente dal suo ultimo offset committato."

---

**Test 2B: High Availability - Self-Healing**

**Speech:**
"Ora dimostro il self-healing di Kubernetes. Cancellerò forzatamente il pod del Producer, simulando un crash improvviso. Kubernetes dovrebbe rilevarlo e riavviare automaticamente un nuovo pod.

Prima di tutto, apro un watcher in un altro terminale per vedere il comportamento in real-time."

**Comando (terminale 2 - opzionale):**
```bash
kubectl get pods -n kafka -l app=producer -w
```

**Speech (terminale principale):**
"Ora identifico il pod Producer e lo elimino forzatamente."

**Comando:**
```bash
# Identifica e cancella
POD_NAME=$(kubectl get pod -l app=producer -n kafka -o jsonpath="{.items[0].metadata.name}")
echo "Deleting pod: $POD_NAME"
kubectl delete pod $POD_NAME -n kafka --grace-period=0 --force
```

**Speech (dopo comando):**
"Ho forzato la cancellazione. Ora osserviamo cosa succede."

**Comando:**
```bash
kubectl get pods -n kafka -l app=producer
```

**Speech (leggendo output):**
"Vedete? C'è già un nuovo pod in stato [leggere stato - probabilmente ContainerCreating o Running]. Kubernetes ha rilevato immediatamente che mancava una replica e ne ha avviata una nuova. Questo è avvenuto senza alcun intervento umano - è il controller Deployment che riconcilia lo stato desiderato con quello attuale.

Aspetto che sia completamente Running."

**Comando:**
```bash
kubectl wait --for=condition=Ready pod -l app=producer -n kafka --timeout=60s
```

**Speech (dopo ready):**
"Perfetto. Il nuovo Producer è operativo. Verifico che accetti richieste."

**Comando:**
```bash
curl -s -o /dev/null -w "%{http_code}" -X POST http://producer.$IP.nip.io:$PORT/event/boot \
  -H "apikey: $API_KEY" -H "Content-Type: application/json" \
  -d '{"device_id":"healing-test","zone_id":"ha-test","firmware":"v1.0"}'
```

**Speech (dopo output):**
"200 OK. Il servizio è tornato disponibile. Questo dimostra High Availability tramite self-healing: il sistema sopravvive a failure di singoli componenti senza downtime prolungato."

---

### NFP 3: SCALABILITY & LOAD BALANCING (~5 min)

**Speech:**
"Passiamo alla scalabilità. Dimostrerò che il sistema può scalare orizzontalmente e che il carico viene distribuito correttamente sia a livello HTTP (Kong) che a livello Kafka (Consumer parallelism).

**Step 1: Scale Out**

Scalo il Producer a 2 repliche e il Consumer a 3 repliche - 3 perché il topic telemetry ha 3 partizioni, quindi posso avere fino a 3 consumer paralleli."

**Comandi:**
```bash
kubectl scale deploy/producer -n kafka --replicas=2
kubectl scale deploy/consumer -n kafka --replicas=3
```

**Speech:**
"Aspetto che tutti i pod siano Running."

**Comandi:**
```bash
kubectl rollout status deployment/producer -n kafka --timeout=60s
kubectl rollout status deployment/consumer -n kafka --timeout=60s
```

**Speech (continuazione):**
"Bene, tutti operativi. Verifico lo stato."

**Comando:**
```bash
kubectl get pods -n kafka -l 'app in (producer,consumer)'
```

**Speech (leggendo output):**
"Perfetto. Vedete: 2 pod Producer e 3 pod Consumer, tutti in Running. 

**Step 2: Burst Test**

Ora genero un carico improvviso: 50 richieste inviate rapidamente in parallelo. Questo forzerà Kong a distribuire il carico tra i 2 Producer, che a loro volta invieranno messaggi su Kafka per essere consumati dai 3 Consumer."

**Comando:**
```bash
echo "Sending 50 parallel requests..."
for i in {1..50}; do
  curl -s -o /dev/null -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
    -H "apikey: $API_KEY" -H "Content-Type: application/json" \
    -d "{\"device_id\":\"load-test-$i\",\"zone_id\":\"scalability-test\",\"temperature\":22,\"humidity\":48}" &
done
wait
echo "✓ All 50 requests sent"
```

**Speech (dopo invio):**
"Perfetto, tutte inviate. Ora analizzo i log per verificare la distribuzione del carico.

**Step 3: Verifica Load Balancing (Producer - HTTP Layer)**"

**Comando:**
```bash
kubectl logs -n kafka -l app=producer --tail=100 --prefix=true | grep "load-test" | head -n 20
```

**Speech (leggendo output):**
"Guardate attentamente il prefisso dei log: [indicare] vedete che ci sono due nomi di pod diversi che hanno gestito le richieste. Ad esempio, 'producer-xxxxx' e 'producer-yyyyy'. Questo conferma che Kong ha distribuito il traffico in Round-Robin tra le due repliche del Producer.

**Step 4: Verifica Consumer Parallelism (Kafka Layer)**"

**Comando:**
```bash
kubectl logs -n kafka -l app=consumer --tail=150 --prefix=true | grep "load-test" | head -n 20
```

**Speech (leggendo output):**
"E anche qui, vedete tre nomi di pod Consumer diversi. Questo significa che Kafka ha assegnato ciascuna delle 3 partizioni del topic a un Consumer diverso, massimizzando il parallelismo. Ogni Consumer legge dalla sua partizione esclusiva.

Questo è esattamente il comportamento che volevamo: scalabilità sia sul data plane HTTP che sul processing layer Kafka.

**Step 5: Scale Down**"

**Comando:**
```bash
kubectl scale deploy/producer -n kafka --replicas=1
kubectl scale deploy/consumer -n kafka --replicas=1
```

**Speech:**
"Riporto tutto alla configurazione base per i test successivi."

---

### NFP 4: HORIZONTAL POD AUTOSCALER (~4 min)

**Speech:**
"Ora dimostro l'elasticità automatica tramite HPA. Applicherò una configurazione che dice: 'Se la CPU media supera il 50%, scala fino a 4 repliche. Se scende sotto, riduci gradualmente.'

**Step 1: Deploy HPA**"

**Comando:**
```bash
kubectl apply -f ./K8s/hpa.yaml
```

**Speech:**
"HPA applicato. Verifico lo stato."

**Comando:**
```bash
kubectl get hpa -n kafka
```

**Speech (leggendo output):**
"Vedete qui: il target è Producer e Consumer, soglia CPU 50%, min 1 max 4 repliche. Al momento le repliche sono 1 e la CPU è probabilmente bassa.

**Step 2: Stress Test**

Ora genero un carico massiccio: 5000 richieste. Questo saturerà la CPU del Producer e triggerà l'autoscaling."

**Comando:**
```bash
echo "Starting stress test: 5000 requests..."
for i in {1..5000}; do
  curl -s -X POST "http://producer.$IP.nip.io:$PORT/event/telemetry" \
    -H "apikey: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"stress-$i\",\"zone_id\":\"hpa-test\",\"temperature\":50,\"humidity\":10}" > /dev/null &
  
  # Batch ogni 50 richieste per non saturare il terminale
  if [ $((i % 50)) -eq 0 ]; then
    wait
    echo "  $i/5000 sent..."
  fi
done
wait
echo "✓ Stress test completed"
```

**Speech (durante l'esecuzione):**
"Questo richiederà alcuni secondi. Nel frattempo, apro un watcher per osservare l'HPA in azione."

**Comando (terminale 2 - opzionale):**
```bash
watch -n 2 kubectl get hpa -n kafka
```

**Speech (dopo completamento stress test):**
"Stress test completato. Ora aspetto circa 30 secondi che Kubernetes rilevi la CPU alta e inizi lo scaling."

**Comando:**
```bash
sleep 30
kubectl get hpa producer-hpa -n kafka
```

**Speech (leggendo output):**
"Guardate: [leggere valore REPLICAS]. Dovrebbe essere salito a 2, 3 o forse già 4 repliche a seconda del carico CPU rilevato. Questo è l'HPA che ha scalato automaticamente il Producer per gestire il carico.

Verifico i pod."

**Comando:**
```bash
kubectl get pods -n kafka -l app=producer
```

**Speech (leggendo output):**
"Perfetto, vedete [numero] pod Producer in Running. L'HPA ha fatto il suo lavoro: ha rilevato la saturazione CPU e ha aggiunto repliche per assorbire il carico.

**Step 3: Scale Down**

Ora che il carico è terminato, l'HPA dovrebbe gradualmente ridurre le repliche. La configurazione prevede una stabilization window di 60 secondi prima dello scale-down per evitare flapping. Aspetto un minuto."

**Comando:**
```bash
echo "Waiting 60s for scale-down stabilization..."
sleep 60
kubectl get hpa -n kafka
```

**Speech (leggendo output):**
"Come vedete, le repliche stanno tornando verso 1. Questo è il comportamento di elasticità: il sistema scala automaticamente su e giù in base al carico effettivo, ottimizzando l'uso delle risorse.

Rimuovo l'HPA per evitare interferenze nei test successivi."

**Comando:**
```bash
kubectl delete -f K8s/hpa.yaml
```

---

### NFP 5: RATE LIMITING (~3 min)

**Speech:**
"Ultimo test: protezione DoS tramite Rate Limiting su Kong. Applicherò una policy che limita a 5 richieste al secondo per client. Poi tenterò un flood attack di 20 richieste rapide e vedremo che Kong blocca quelle eccessive.

**Step 1: Applicazione Policy**"

**Comando:**
```bash
cat <<'EOF' | kubectl apply -f -
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
```

**Speech:**
"Plugin creato. Ora lo attivo sull'Ingress del Producer."

**Comando:**
```bash
kubectl patch ingress producer-ingress -n kafka \
  -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth, global-rate-limit"}}}'
```

**Speech:**
"Perfetto. Policy attiva. Aspetto qualche secondo che Kong ricarichi la configurazione."

**Comando:**
```bash
sleep 4
```

**Speech (continuazione):**
"Ora eseguo il flood test: 20 richieste inviate il più velocemente possibile.

**Step 2: Flood Test**"

**Comando:**
```bash
echo "Flood test: 20 rapid requests"
for i in {1..20}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://producer.$IP.nip.io:$PORT/event/telemetry \
    -H "apikey: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"flood-$i\",\"zone_id\":\"dos-test\",\"temperature\":0,\"humidity\":0}")
  
  if [ "$CODE" == "429" ]; then
    echo "  Request $i: $CODE Too Many Requests ✗"
  else
    echo "  Request $i: $CODE OK ✓"
  fi
done
```

**Speech (leggendo output mentre scorre):**
"Guardate: le prime 5-7 richieste ricevono 200 OK, ma poi iniziate a vedere 429 Too Many Requests. Kong sta bloccando le richieste eccessive, proteggendo il backend da sovraccarico.

Questo è esattamente il comportamento che volevamo: se un sensore malfunzionante o un attaccante tenta di inondare il sistema, Kong li blocca all'edge prima che raggiungano Kafka o MongoDB.

**Step 3: Cleanup**"

**Comando:**
```bash
kubectl delete kongplugin -n kafka global-rate-limit
kubectl patch ingress producer-ingress -n kafka \
  -p '{"metadata":{"annotations":{"konghq.com/plugins":"key-auth"}}}'
```

**Speech:**
"Ho rimosso il rate limiting per ripristinare la configurazione normale."

---

## CONCLUSIONE DEMO

**Speech finale:**
"Questo conclude la demo. Abbiamo visto:

Primo, che il sistema funziona correttamente: autenticazione, ingestione dati, processamento e storage.

Secondo, e più importante, che soddisfa tutte e 5 le proprietà non funzionali che avevo dichiarato:
- Sicurezza con TLS, SASL e API Key
- Fault Tolerance con Kafka buffering e zero data loss
- High Availability con Kubernetes self-healing
- Scalabilità con load balancing e consumer parallelism  
- Elasticità con HPA automatico

Questi test non sono teorici - sono validazioni concrete che dimostrano che questo sistema è production-ready e può gestire carichi reali mantenendo le garanzie dichiarate.

Sono disponibile per domande su qualsiasi aspetto dell'architettura o dell'implementazione."

---

