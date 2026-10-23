# task-service-delphi

Task-Service des Task-Management-Systems - verwaltet Aufgaben pro Benutzer.
Geschrieben in Delphi (Indy fuer HTTP + TCP, FireDAC/SQLite fuer Persistenz).

Der Vertrag (Endpoints, Felder, Event-Format) liegt im separaten Repo
[`contracts`](https://github.com/LevinWiederkehr/task-management-contracts) -
siehe dort `openapi/task-service.yaml` und `asyncapi/task-events.yaml`
(implementierte Version: **1.1.0**). Bei Aenderungen zuerst dort anpassen,
Vorgehen siehe `EVOLUTION.md` im contracts-Repo.

## Funktionen

- `GET /health` (oeffentlich, prueft auch die DB, zeigt `pendingEvents`)
- `GET|POST /v1/tasks`, `GET|PUT|DELETE /v1/tasks/{id}`
- `/tasks...` ohne Version: **deprecated** Alias aus Vertrag 1.0.0, Antwort
  mit Header `Deprecation: true` (Expand-Phase, siehe EVOLUTION.md)
- **Authentifizierung**: Bearer-Token von Keycloak, **Signatur wird geprueft**
  (RS256 gegen die JWKS des Realms, per Windows CNG/`bcrypt.dll`), dazu
  Issuer und Ablaufzeit. `alg: none` oder manipulierte Tokens -> 401.
- **Autorisierung**: ressourcenbasiert - jede Aufgabe gehoert genau einem
  Benutzer (`sub`-Claim), andere Benutzer bekommen 404
- **Persistenz**: SQLite (`tasks.db`, statisch gelinkt, keine DLL noetig)
- **Transactional Outbox**: jede Aenderung schreibt in derselben Transaktion
  ein Event in die Tabelle `outbox`. Ein Hintergrund-Thread versendet es per
  STOMP an RabbitMQ, wartet auf die Broker-Bestaetigung (`RECEIPT`) und
  versucht es bei Fehlern mit exponentiellem Backoff (1-30 s) erneut.
  -> Ein Broker-Ausfall verzoegert nur die Events, **nie** einen
  HTTP-Request, und es geht kein Event verloren (at-least-once).
- **Observability**: Header `X-Correlation-ID` wird uebernommen (oder neu
  erzeugt), in der Response zurueckgegeben, in jedem Log-Eintrag und im
  Event (`correlationId` + AMQP-Property `correlation_id`) mitgegeben. Logs
  sind JSON-Zeilen (CLEF), optional zentral an Seq (`SEQ_URL`).
- Validierung: `title` 1-200 Zeichen, `description` max. 2000 Zeichen
- Sauberes Herunterfahren bei Ctrl+C (Server stoppen, Outbox-Thread beenden)

## Struktur

| Datei | Zweck |
| --- | --- |
| `TaskService.dpr` | Hauptprogramm: HTTP-Server, Routing, Request-Kontext (Correlation-ID, Logging) |
| `TaskModel.pas` | Domaenenmodell + Abbildung auf API-DTO und Event (Vertrags-Mapping) |
| `TaskStore.pas` | SQLite-Persistenz + Transactional Outbox |
| `OutboxPublisher.pas` | Hintergrund-Thread: Outbox -> RabbitMQ (STOMP, Receipt, Retry) |
| `JwtAuth.pas` | Token-Pruefung inkl. RS256-Signatur gegen JWKS |
| `AppLog.pas` | Strukturiertes JSON-Logging, optional Versand an Seq |

## Starten

Voraussetzung: gemeinsame Infrastruktur laeuft (`contracts`-Repo). Am
einfachsten startet man das **ganze System** mit `start-all.ps1` im
contracts-Repo. Nur diesen Service:

```
start.cmd          (ohne Delphi: startet die mitgelieferte TaskService.exe)
run.cmd            (mit Delphi: baut neu per dcc64 und startet)
```

Ohne Port-Angabe wird 8090 verwendet; ist 8090 belegt (z.B. durch
Wondershare NativePush), automatisch 8095. Fester Port: `start.cmd 8095`.

Die mitgelieferte `TaskService.exe` ist ein Snapshot - nach Code-Aenderungen
mit `run.cmd` neu bauen und committen.

Konfiguration per Umgebungsvariable (Defaults passen zur gemeinsamen Infra):

| Variable | Default |
| --- | --- |
| `PORT` | `8090` |
| `DB_PATH` | `tasks.db` neben der .exe |
| `RABBITMQ_HOST` / `RABBITMQ_STOMP_PORT` | `localhost` / `61613` |
| `RABBITMQ_USER` / `RABBITMQ_PASS` | `guest` / `guest` |
| `OIDC_JWKS_URL` | `http://localhost:8082/realms/task-mgmt/protocol/openid-connect/certs` |
| `OIDC_ISSUER` | `http://localhost:8082/realms/task-mgmt` |
| `SEQ_URL` | leer (kein Versand); im Gesamtsystem `http://localhost:5341` |

## Manuell testen

```
# Token holen (siehe contracts/README.md fuer Demo-User)
curl -X POST http://localhost:8082/realms/task-mgmt/protocol/openid-connect/token ^
  -H "Content-Type: application/x-www-form-urlencoded" ^
  -d "grant_type=password&client_id=task-mgmt-client&username=levin&password=levin123"

# Aufgabe anlegen (access_token aus der Antwort oben einsetzen)
curl -i -X POST http://localhost:8090/v1/tasks -H "Authorization: Bearer <token>" ^
  -H "X-Correlation-ID: demo-123" ^
  -H "Content-Type: application/json" -d "{\"title\":\"Rechnung schreiben\"}"
```

Automatisierter End-to-End-Test des Gesamtsystems: `scripts/e2e-test.ps1`
im contracts-Repo.

## Bekannte Grenzen

- Der Service ist (wegen SQLite) **eine** Instanz; horizontal skaliert wird
  der History-Service. Fuer mehrere Task-Service-Instanzen muesste die DB
  auf einen Server (z.B. Postgres) wechseln - der Code ist dafuer bereits
  zustandslos (keine Daten im Speicher, IDs aus der DB).
- `bcrypt.dll` ist Windows-only. Ein Linux-Build (fuer einen Linux-Container)
  braeuchte den Delphi-Linux-Compiler und eine OpenSSL-Variante von
  `VerifyRs256` in `JwtAuth.pas`.
