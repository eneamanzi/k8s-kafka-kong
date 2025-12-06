# Speech per Presentazione Esame CCT (10 minuti)

## SLIDE 1 \- Intro (30 secondi) (Architettura Microservizi Event-Driven su Kubernetes)

Buongiorno. Oggi vi presento un'architettura a microservizi **event-driven** su Kubernetes per il monitoraggio IoT industriale. 

## SLIDE 2 \- Obiettivi Architetturali & Requisiti (1:30 min)

Il progetto integra i requisiti del **Project 1 su Apache Kafka** — implementando *fault tolerance*, *high availability* e *sicurezza avanzata* con TLS e SASL — e del **Project 3 su Kong API Gateway**, centralizzando *autenticazione* e *traffic control all'edge*.

Lo scenario simula una rete di sensori eterogenei che generano flussi continui di telemetria, alert critici e aggiornamenti firmware. Questo contesto richiede una **Qualità del Servizio (QoS) differenziata** per due macro-flussi:

* I **dati operativi ad alta frequenza** (telemetria, eventi di boot, aggiornamenti firmware), che richiedono *efficienza* e *compressione*.  
* Gli **eventi critici** (allarmi), sporadici ma che esigono **Zero Data Loss** (massima garanzia di consegna).

## SLIDE 3 \- Architettura e Flusso Dati (2:00 min)

il sistema adotta un pattern puramente **Event-Driven** per disaccoppiare completamente l'ingestione dei dati dal loro processamento

L'infrastruttura è divisa in tre namespace logici per garantire la *Separation of Concerns*: `kong` per l'ingress, `kafka` per la logica core, e `metrics` per l'analisi.

Il flusso è il seguente:

1. **Sensori** \+ **Ingress** (**Kong**)

   1. Tutto inizia dai sensori che inviano richieste HTTP `POST`. Il traffico non colpisce mai direttamente i servizi, ma passa per **Kong**. Qui applichiamo il pattern di *Gateway Offloading*: Kong agisce da Reverse Proxy verificando l'**API Key**. Se la chiave non è valida, la richiesta viene respinta all'edge, proteggendo il backend.

2. **Ingestion (Producer):** Le richieste valide arrivano al **Producer**. Questo è un microservizio *stateless* fondamentale per due motivi:

   1. Primo, **arricchisce il dato**: aggiunge un UUID univoco che fungerà da *idempotency token* e un timestamp di ingestione preciso.

   2. Secondo, esegue il **routing intelligente**: invia i dati operativi sul topic `sensor-telemetry` e gli allarmi su `sensor-alerts`, permettendo di applicare policy di retention e compressione differenziate.

3. **Streaming (Kafka):** Qui entra in gioco Kafka come **buffer persistente**. Grazie alla sua natura asincrona, Kafka gestisce la *backpressure*: se il database rallenta o il Consumer va offline, i messaggi si accumulano su disco nei broker e non vengono persi.

4. **Processing & Storage (Consumer & MongoDB):** Il **Consumer** legge da Kafka, normalizza i formati e scrive su **MongoDB**. Abbiamo scelto di utilizzare le **Time Series Collections** native di Mongo, che ci garantiscono efficienza in scrittura e una compressione Zstd automatica sui dati storici.

5. **Analytics (Metrics Service):** Infine, parallelamente al flusso di scrittura, abbiamo il flusso di lettura. Il **Metrics Service** interroga direttamente MongoDB sfruttando gli indici temporali ottimizzati per calcolare aggregazioni in tempo reale, come la media della temperatura per zona, ed esporle via API REST.

## SLIDE 4 \- Apache Kafka: Topic Strategy & Durability (1:45 min)

Entriamo nel dettaglio di Kafka.

Primo pilastro: **KRaft Mode.**   
L'architettura abbandona il vecchio modello con ***ZooKeeper*** in favore di una gestione dei metadati interna basata sul protocollo Raft.  
 Ho definito due KafkaNodePool distinti per **Controller** e **Broker**. Questo non solo semplifica l'operatività, ma riduce drasticamente il consumo di risorse (CPU/RAM) e la superficie di attacco, rendendo il cluster più leggero e cloud-native.

Secondo punto: **strategia dei topic**.

* Per `sensor-telemetry`, che gestisce il bulk dei dati, ho configurato **3 partizioni** per massimizzare il parallelismo di lettura — fino a 3 consumer concorrenti — e **compressione LZ4** a livello di transport. 

  * LZ4 è ottimale per IoT: bassissimo overhead CPU, alta velocità di decompressione, e riduce il traffico di rete fino al 60% su payload JSON ripetitivi. La retention è limitata a **7 giorni** per mantenere i dati operativi “caldi".

* Per `sensor-alerts`, invece, priorità assoluta alla **durabilità**. Ho impostato `min.insync.replicas: 2` con `replicas: 2`: Kafka **rifiuta** la scrittura se non può garantire la copia su entrambi i broker. Questo è un **trade-off consapevole**: riduco leggermente la disponibilità durante manutenzioni, ma garantisco zero data loss su eventi critici. Retention estesa a **30 giorni** per audit.

Ultimo punto: **compressione ibrida**.   
A livello di storage, MongoDB applica nativamente **Zstd** sulle *Time Series Collections* — questo è trasparente per noi, ma garantisce un ulteriore risparmio su disco del 70% circa sui dati storici.   
Quindi: LZ4 per il transport, Zstd per lo storage a lungo termine.

## SLIDE 5 \- Kong API Gateway: Edge Computing & Security (1:30 min)

Kong implementa il pattern di **Gateway Offloading**: spostiamo logica trasversale dal codice applicativo all'infrastruttura.

**Autenticazione**  
Il plugin `key-auth` intercetta ogni richiesta HTTP e verifica l'header `apikey` contro i Secret Kubernetes. Se la chiave è valida, la richiesta passa; altrimenti, Kong restituisce `401 Unauthorized` **senza mai raggiungere il backend**. Questo significa che posso revocare l'accesso a un dispositivo compromesso semplicemente aggiornando il Secret — **zero downtime, zero redeploy.**

**Rate Limiting**  
Ho configurato una policy dichiarativa di 5 richieste al secondo per client. Durante la demo, vedremo come Kong risponde con `429 Too Many Requests` quando un client supera la soglia, proteggendo i microservizi da flood o attacchi DoS.

**Load Balancing**  
Kong distribuisce il traffico tra le repliche del Producer tramite round-robin. Questo è automatico: **Kubernetes Service** \+ **Kong Ingress** gestiscono tutto nativamente.

Notate che l'intera configurazione è **Infrastructure as Code**: plugin, consumer, credential — tutto è definito come **CRD Kubernetes.** Nessuna UI, nessun click manuale. Questo è essenziale per CI/CD e per garantire la riproducibilità.

## SLIDE 6 \- MongoDB: Persistenza e Ottimizzazione Dati (1:30 min)

Per lo storage ho scelto MongoDB con **Time Series Collections** native.

I **vantaggi** sono tre:

1. **Compressione Zstd nativa**: MongoDB organizza i dati in *bucket colonnari* compressi per intervallo temporale. Rispetto ai documenti standard, questo garantisce un risparmio di disco di circa il 70%.

2. **Efficienza analitica**: Le aggregazioni del Metrics Service beneficiano di **indici clustered automatici** sul campo `timestamp`. Query su range temporali — tipo "media temperatura ultima ora" — leggono solo i bucket necessari, massimizzando throughput.

3. **TTL automatico**: Ho configurato `expireAfterSeconds: 2592000` — 30 giorni. MongoDB elimina automaticamente i dati "freddi" senza intervento manuale.

**Infrastruttura**  
Infrastrutturalmente, la scelta critica è stata l'uso di uno **StatefulSet** invece di un classico Deployment. Con un Deployment, i pod sono effimeri e con identità casuali: in caso di crash, il nuovo pod non riusciva a ricollegarsi al volume persistente (PVC) precedente.   
Lo **StatefulSet** garantisce invece un'**identità di rete stabile** (es. mongo-0) e l'associazione persistente con il disco. Questo è essenziale per un database in ambiente Kubernetes per garantire che i dati sopravvivano al riavvio del pod.

**Configurazione**  
Infine, **configurazione cloud-native**: 

* Parametri **non sensibili** — *host, porta, nome database* — iniettati via **ConfigMap**.

* **Credenziali** — *user e password* — iniettate via **Secret** come variabili d'ambiente. **Mai hardcoded.**

## SLIDE 7 \- Microservices Implementation (1 min)

Tre microservizi Python 3.11, tutti containerizzati e orchestrati su Kubernetes.

**Producer**  
Flask REST API stateless. Riceve HTTP da Kong, aggiunge UUID e timestamp — questo è il nostro **idempotency token** per gestire la semantica at-least-once di Kafka — e pubblica su Kafka via TLS porta 9093 con autenticazione SASL/SCRAM-SHA-512.

**Consumer**  
Worker stateful che mantiene l'offset di lettura. Sottoscrive entrambi i topic, normalizza i timestamp, e salva su MongoDB. Durante un crash del Consumer, i messaggi si accumulano in Kafka; al riavvio, vengono processati immediatamente — **zero data loss**.

**Metrics Service**  
Espone 5 endpoint di analytics — totale boot, media temperatura per zona, breakdown allarmi, trend attività 7 giorni, stato firmware. Tutte query eseguite direttamente su MongoDB, sfruttando l'efficienza delle Time Series.

Notate che il Consumer è scalato a 3 repliche per allinearsi alle 3 partizioni del topic telemetry — questo massimizza il parallelismo di lettura.

## SLIDE 8 \- Non-Functional Properties: Validation Matrix (1:30 min)

Le NFP sono state validate tramite scenari di test specifici che eseguirò nella demo.

**Security**  
Tre layer:

* Primo, **data in transit**: **TLS** sulla porta 9093 con autenticazione **SASL**/**SCRAM**\-SHA-512 — credenziali mai in chiaro, sempre iniettate via Secret.   
* Secondo, **edge** protection: Kong plugin API Key blocca richieste non autenticate, rate limiting mitiga DoS.   
* Terzo, **secret** management: nessuna password hardcoded — tutto via Kubernetes Secrets.

**Resilience, Fault Tolerance e HA**  
Kafka agisce da buffer persistente. Durante la demo, spegnerò il Consumer, invierò messaggi, e al riavvio vedrete che vengono processati immediatamente — il disaccoppiamento asincrono garantisce **zero data loss**.   
Inoltre, **self-healing:** Kubernetes rileva crash dei pod e riavvia automaticamente i container.

**Scalabilità e Load Balancing**  
Manuale e automatico. Manualmente, scalo il Producer a 2 repliche e verifico la distribuzione del traffico tramite round-robin nei log. Il Consumer scala fino a 3 repliche per sfruttare le 3 partizioni Kafka. Automaticamente, ho configurato HPA con soglia CPU al 50%: durante uno stress test, il sistema scala autonomamente da 1 a 4 repliche, e dopo il picco fa scale down rilasciando risorse.

## SLIDE 9 \- Sfide Tecniche & Soluzioni (1 min)

Tre sfide principali risolte durante lo sviluppo.

**Networking**  
L'isolamento di rete del driver Docker Desktop impediva il routing corretto verso gli Ingress Controller. La soluzione è stata adottare Minikube con driver nativo, che permette di esporre l'IP del cluster direttamente all'host, rendendo accessibili i domini nip.io definiti nelle regole di Ingress.

**Garanzia di Consegna e Idempotenza**  
La semantica at-least-once di Kafka rischia duplicazioni se il Consumer crasha dopo la scrittura su MongoDB ma prima del commit dell'offset. Ho implementato UUID univoci nel Producer — l'architettura è **predisposta** per **upsert** su MongoDB usando l'`event_id` come chiave univoca, anche se attualmente accetto la duplicazione per massimizzare il throughput.

**StatefulSet**  
MongoDB deployato inizialmente come Deployment causava instabilità: dopo un crash, il pod sostitutivo non poteva reclamare la PVC. La migrazione a **StatefulSet** risolve garantendo identità stabile e riacquisizione immediata del disco.

## SLIDE 10 \- Demo Roadmap (45 secondi)

Nella demo eseguirò la validation completa: auth check, pipeline end-to-end  
NFP: fault tolerance con consumer crash, self-healing, scaling manuale e automatico, e rate limiting.

## SLIDE 11 \- Q\&A (15 secondi)

Grazie per l'attenzione. Sono disponibile per domande prima di passare alla demo live.