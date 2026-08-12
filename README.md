# infra

Ansible- og shell-automatisering for et Raspberry Pi MANET-cluster med Kubernetes (K3s).

## 01 - Systembeskrivelse

Dette repoet provisjonerer et selvstendig Raspberry Pi-cluster for felttesting av edge-databehandling i mobile, oppkoblingssvake nettverk. Ansible setter opp hver node og kobler dem sammen med B.A.T.M.A.N. mesh-ruting (`batman-adv`) over Wi-Fi ad-hoc. Én node har rollen manager: den kjører K3s-kontrollplanet og deler ut IP-adresser og DNS-navn til resten av mesh-nettverket over `bat0`.

### Komponenter

| Komponent | Kjører på | Beskrivelse |
|---|---|---|
| Mesh-nettverk (`batman-adv`) | Alle noder | Ruter trafikk mellom noder uten fast infrastruktur. |
| K3s | Alle noder | Kubernetes-distribusjon for edge-enheter. Manager kjører kontrollplanet. |
| dnsmasq | Manager | Deler ut DHCP-adresser og DNS-navn (`*.gotham`) på mesh-nettverket. |
| Zot | Manager (pod) | OCI-register for container-images. Se `registry/README.md`. |
| Mosquitto | Cluster (pod) | MQTT-broker. Samler sensor- og lenkedata fra alle noder. |
| Nettverksprobe | Alle noder | Måler lenke-latens og -kapasitet. Publiserer resultatet til MQTT. |
| Feltloggetjeneste | Alle noder | Logger CPU-, minne- og disk-bruk under et eksperiment. |
| Egendefinert scheduler (`k8-scheduler`) | Manager | Plasserer poder etter mesh-topologi i stedet for standard Kubernetes-logikk. |
| venividivici | Manager (pod) | Overvåker det kablede nettet og provisjonerer nye Raspberry Pi-enheter automatisk. |
| Dashboard | Cluster (pod) | Samlesider for cluster-status og apper. Nås på `http://dashboard.gotham`. |

Applikasjoner som kjører på clusteret (objektdeteksjon, radioklassifisering, GPS-klient) ligger i egne repoer ved siden av dette. Se avsnitt 04 for hvordan de distribueres herfra.

## 02 - Installasjon og krav

### Forutsetninger

Krav til styremaskinen (laptopen du kjører Ansible fra):

* `ansible` og `python3`
* `kubectl`
* Passordløs `sudo nmap`. `inventories/discover.py` bruker den til å søke etter Pi-enheter på nettet.
* `fzf`. Kreves av `make deploy` og `make watch`.
* `sshpass`. Kreves av `make watch`. Pi-enhetene bruker passord, ikke SSH-nøkkel, som standard.
* Go med `GOOS=linux GOARCH=arm64` kryss-kompilering. Kreves kun av `make deploy-scheduler`.

Krav til hver Raspberry Pi:

* Uendret Raspberry Pi OS-image.
* Standard SSH-brukernavn og -passord (`pi` / `raspberry`), eller egne verdier satt i `.env`.
* Tilkobling til samme kablede nett som styremaskinen, for førstegangs oppdagelse.

### Installasjonssteg

1. Klon dette repoet.
2. Kjør `cp .env.example .env` i repo-roten.
3. Rediger `.env` hvis standardverdiene ikke passer nettverket ditt. Se avsnitt 03.
4. Koble alle Raspberry Pi-enhetene til det kablede oppsettnettet.
5. Kjør `make discover` for å bekrefte at systemet finner alle enhetene.
6. Kjør `make provision` for å konfigurere mesh-nettverk, K3s og registerklarering.
7. Kjør `make kubeconfig` for å hente cluster-tilgang til styremaskinen.
8. Kjør `kubectl get nodes` for å bekrefte at hver node har status `Ready`.
9. Kjør `kubectl apply -f mosquitto/mosquitto.yml` for å distribuere MQTT-broker.
10. Følg `registry/README.md` for å sette opp Zot-registeret (krever et TLS-sertifikat).

Steg 9 og 10 er nødvendige for et fungerende cluster: nettverksproben publiserer lenkedata til Mosquitto, og appdistribusjon (avsnitt 04) trenger et register å pushe images til.

Provisjonering er idempotent. Kjør `make provision` på nytt for å verifisere eller reparere en node uten risiko.

## 03 - Konfigurasjon

All konfigurasjon skjer i `.env`, kopiert fra `.env.example`. Ansible leser de samme verdiene via `playbooks/group_vars/all.yml`, med de samme standardverdiene som fallback.

Det finnes ingen statisk inventarfil å redigere. `inventories/discover.py` finner Pi-enheter på nettet selv, og lagrer MAC-til-navn-tilordninger i `inventories/discovered_hosts.json`. Denne filen ligger i git og følger med repoet mellom maskiner.

### Mesh-nettverk

| Variabel | Standardverdi | Beskrivelse |
|---|---|---|
| `MESH_MANAGER_IP` | `192.168.42.1` | Managerens faste IP på `bat0`. |
| `MESH_DHCP_START` / `MESH_DHCP_END` | `192.168.42.2` – `192.168.42.254` | DHCP-området manager deler ut til workere på `bat0`. |
| `MESH_DHCP_LEASE_HOURS` | `12` | Lengden på hver DHCP-leieavtale, i timer. |
| `MESH_SSID` | `meshnet` | Wi-Fi-navnet ad-hoc-nettverket bruker. Alle noder må bruke samme verdi. |
| `MESH_CHANNEL` | `1` | Wi-Fi-kanalen ad-hoc-nettverket bruker. |
| `MESH_DOMAIN` | `gotham` | DNS-endelsen manager sin dnsmasq svarer på, f.eks. `manager0.gotham`. |

### Kablet oppsettnett

| Variabel | Standardverdi | Beskrivelse |
|---|---|---|
| `WIRED_SCAN_SUBNET` | `192.168.67.0/24` | Nettet `discover.py` søker gjennom for å finne Pi-enheter. |
| `MANAGER_WIRED_IP` | (tom) | Managerens faste `eth0`-IP. Kun nødvendig uten ruter i felt. Se `field-phase-one`/`field-phase-two` i avsnitt 04. |
| `MANAGER_HOST` | `manager0.local` | Managerens mDNS-navn, brukt av `watchctl.sh`. |

### Pi-tilgang

| Variabel | Standardverdi | Beskrivelse |
|---|---|---|
| `PI_SSH_USER` | `pi` | Brukernavn for SSH mot hver Pi. |
| `PI_SSH_PASSWORD` | `raspberry` | Passord for SSH mot hver Pi. Dette er Raspberry Pi OS sin offentlig kjente standardverdi, ikke en hemmelighet. |

### K3s og register

| Variabel | Standardverdi | Beskrivelse |
|---|---|---|
| `K3S_API_PORT` | `6443` | Porten K3s sin API-server lytter på. |
| `REGISTRY_HOST` / `REGISTRY_PORT` | `manager0.gotham` / `30500` | Adressen til Zot-registeret. Hver image-referanse i clusteret må matche denne verdien nøyaktig. |

TLS-sertifikatet for registeret genereres manuelt, utenfor repoet. Se `registry/README.md`.

### Feltlogging

| Variabel | Standardverdi | Beskrivelse |
|---|---|---|
| `FIELDLOG_INTERVAL` | `5` | Sekunder mellom hver måling av CPU/minne/disk. |
| `FIELDLOG_MAX_SIZE_KB` | `10240` | Maksimal filstørrelse før loggfilen roteres. |
| `FIELDLOG_ALL_ROUTES` | `false` | `true` logger også ruter som ikke er i bruk. Kun til feilsøking. |
| `SCHEDULER_LOG_WINDOW` | `2 hours ago` | Hvor langt tilbake `make collect-logs` henter scheduler-logger. |
| `APP_LOG_WINDOW` | `2h` | Hvor langt tilbake `make collect-logs` henter applikasjonslogger. |

### Nettverksprobe og MQTT

| Variabel | Standardverdi | Beskrivelse |
|---|---|---|
| `PROBE_MQTT_HOST` / `PROBE_MQTT_PORT` | `127.0.0.1` / `31883` | MQTT-brokeren hver node publiserer lenkedata til. |
| `MQTT_TOPIC_LINKDATA` | `network/linkdata` | MQTT-topicet lenkedata publiseres på. |

### venividivici

**Merk:** venividivici er på et veldig tidlig utviklingsstadium (WIP). Bruk med forsiktighet.

| Variabel | Standardverdi | Beskrivelse |
|---|---|---|
| `VENIVIDIVICI_POLL_INTERVAL` | `30` | Sekunder mellom hvert søk etter nye Pi-enheter. |
| `VENIVIDIVICI_SSH_PROBE_TIMEOUT` | `5` | Sekunder før et SSH-forsøk mot en ny node gir opp. |
| `VENIVIDIVICI_MQTT_BROKER` / `VENIVIDIVICI_MQTT_PORT` | `mosquitto.default.svc.cluster.local` / `1883` | MQTT-brokeren i clusteret, brukt internt av venividivici. |

## 04 - Bruk

### Hurtigstart

```bash
cp .env.example .env
make discover
make provision
make kubeconfig
```

Kjør `make help` for full liste over kommandoer, med beskrivelse. De fleste kommandoer godtar `LIMIT=<node>` for å begrense kjøringen til én node. `<node>` er hostnavnet fra `make discover` (`manager0`, `worker0`, `worker1`, ...). Eksempel: `make provision LIMIT=worker0`.

### Kjernekommandoer

**Oppdagelse**

* `make discover`: Lister Pi-enheter funnet på nettet. Ingen SSH-tilkobling.
* `make discover-model`: Som over, men kobler til hver enhet og viser Pi-modell.
* `make ping`: Ansible-ping mot alle oppdagede noder.
* `make status`: Viser apt/dpkg-aktivitet på alle noder. Brukes til å se om provisjonering henger.
* `make identify LIMIT=<node>`: Blinker en Pi sin aktivitets-LED i 30 sekunder.

**Provisjonering**

* `make provision`: Kjører full provisjonering. Bruk `TAGS=<navn>` eller `SKIP=<navn>` for å begrense omfanget.
* `make reset`: Fjerner K3s, mesh-konfigurasjon og alle provisjoneringsspor fra alle noder. Ber om bekreftelse.
* `make reboot`: Starter alle noder på nytt. Ber om bekreftelse.

**Automatisert provisjonering (venividivici)**

* `make venividivici-build`: Bygger og pusher venividivici sitt image til Zot.
* `make venividivici-apply`: Distribuerer venividivici-poden på manager.
* `make venividivici-logs`: Følger venividivici sin logg live.
* `make venividivici-delete`: Fjerner venividivici-distribusjonen.
* `make venividivici-rollout`: Starter venividivici-poden på nytt.

**Cluster-administrasjon**

* `make kubeconfig`: Henter kubeconfig fra manager til `~/.kube/config`.
* `make kubeconfig-copy HOST=<node>`: Kopierer kubeconfig til en annen Pi.
* `make label`: Kjører kapabilitetsdeteksjon på nytt og oppdaterer k8s-labels. Fjerner ikke gamle labels.

**Distribusjon**

* `make deploy ACTION=<apply|logs|delete|build|rollout>`: Velger en Kubernetes-distribusjon fra dette repoet eller et naboprepo, og kjører valgt handling. Uten `ACTION` velges handlingen interaktivt.
* `make deploy-scheduler`: Bygger og distribuerer den egendefinerte scheduleren. Krever `SCHEDULER_DIR` satt til scheduler-repoet, standard `../scheduler`.

**Register**

* `make registry-trust`: Setter opp denne maskinen til å pushe til Zot-registeret. Se `registry/README.md`.

**Observasjon**

* `make watch`: Velger og strømmer en live cluster-visning (scheduler-logg, poder, noder, tjenester).

**Feltlogging**

* `make start-logging`: Synkroniserer klokken på alle noder, deretter starter feltlogging. Bruk `SESSION=<id>` for å gjenoppta en økt.
* `make stop-logging`: Stopper feltlogging på alle noder.
* `make collect-logs`: Henter logger fra alle noder til `collected-logs/synced/`.

**Vedlikehold**

* `make known-hosts-reset`: Fjerner gamle SSH-nøkler for alle noder. Kjør etter at en Pi er re-flashet, eller når SSH varsler om at en host key ikke stemmer (`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`).

**Felteksperiment uten ruter**

* `make field-phase-one`: Setter managerens faste `eth0`-IP. Kjør før du flytter kabelen fra ruter til laptop.
* `make field-phase-two`: Bekrefter manager etter kabelbyttet.

## 05 - Feilsøking

* Symptom: `make provision` eller `make reset` feiler underveis.
  * Løsning: Kjør kommandoen på nytt. Vanlige årsaker er en låst apt-fil, en treg K3s-installasjon eller en node som ikke er ferdig oppstartet. En ny kjøring løser som regel dette.
* Symptom: En worker er ikke synlig i mesh-trafikken (mangler i `batctl n`, eller svarer ikke på ping over `bat0`).
  * Løsning: Kjør `make reboot LIMIT=<node>`. Løser som regel problemet.
* Symptom: En worker svarer normalt i mesh-trafikken, men mangler eller er `NotReady` i `kubectl get nodes`.
  * Løsning: Koble til noden med SSH og kjør `systemctl restart k3s-agent`. Tjenesten kan ha startet på `eth0` før `bat0` var klar.
* Symptom: En fjernet enhet (f.eks. GPS) har fortsatt sin kapabilitets-label på noden.
  * Løsning: Fjern labelen manuelt med `kubectl label node <node> capability/<navn>-`. Kapabilitetsdeteksjon fjerner aldri gamle labels automatisk.
* Symptom: Tidsstempler i feltlogger stemmer ikke med klokkeslettet.
  * Løsning: Bruk `make start-logging`, ikke en manuell `systemctl start`. Den synkroniserer klokken mot laptopen først. Manager har ikke nødvendigvis internett i felt.
* Symptom: `docker push` mot registeret feiler med en sertifikatfeil.
  * Løsning: Kjør `make registry-trust` på maskinen som pusher.
* Symptom: Et pushet image lar seg ikke hente ned på clusteret.
  * Løsning: Kontroller at image-referansen matcher `REGISTRY_HOST:REGISTRY_PORT` nøyaktig, satt i din `.env` (standardverdi `manager0.gotham:30500`, se avsnitt 03). Avvik fra denne strengen feiler.
* Symptom: `make deploy ACTION=build` gjør ingenting for et image.
  * Løsning: Kjør byggekommandoen i det aktuelle repoet direkte. `deployctl.sh` har ingen generisk byggefunksjon.
* Symptom: Clusteret mister all tilgang når manager går offline.
  * Løsning: Ingen automatisk løsning finnes i dag. Clusteret har verken manager-failover eller valg av ny manager. Start manager på nytt, eller provisjoner en ny manager manuelt.
