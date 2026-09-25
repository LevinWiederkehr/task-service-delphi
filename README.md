# task-service-delphi

Task-Service des Task-Management-Systems - verwaltet Aufgaben pro Benutzer.
Geschrieben in Delphi (Indy fuer HTTP-Server + TCP), **lauffaehiges
Grundgerueest**, kein fertiges Produkt.

Der Vertrag (Endpoints, Felder, Event-Format) liegt im separaten Repo
[`contracts`](../contracts) - siehe dort `openapi/task-service.yaml` und
`asyncapi/task-events.yaml`. Bei Aenderungen zuerst dort anpassen.

## Was schon funktioniert (Ende-zu-Ende getestet)

- `GET /health` (oeffentlich)
- `GET /tasks`, `POST /tasks`, `GET /tasks/{id}`, `PUT /tasks/{id}`, `DELETE /tasks/{id}`
- Login-Pruefung per Bearer-Token (aus Keycloak) - **Achtung, siehe TODO unten**
- Ressourcenbasierte Autorisierung: jede Aufgabe gehoert genau einem
  Benutzer (`sub`-Claim), andere Benutzer bekommen 404 statt der Aufgabe
- Bei jeder Aenderung (create/update/complete/delete) wird ein Event an
  RabbitMQ published (Fanout-Exchange `task-events`, per STOMP) - verifiziert
  per Python/pika-Consumer, dass die Events korrekt ankommen

## Was noch fehlt (TODO fuer die Weiterentwicklung)

- **Wichtig, sicherheitsrelevant**: `JwtAuth.pas` prueft aktuell NUR die
  Ablaufzeit, NICHT die Signatur des Tokens. Vor echtem Einsatz: Signatur
  (RS256) gegen die JWKS von Keycloak verifizieren - siehe Kommentar am
  Anfang von `JwtAuth.pas` fuer Optionen (z.B. Library
  `Delphi-JOSE-JWT`, oder Referenzimplementierung in Java aus dem
  M321-Demo-Projekt).
- Persistenz: `TaskModel.pas` haelt Aufgaben nur im Arbeitsspeicher (weg
  beim Neustart). Ersetzen durch echte Datenbank (z.B. FireDAC + SQLite).
- Fehlerbehandlung/Validierung verfeinern (z.B. Titel-Laenge, Pagination
  bei `GET /tasks`).
- `.dproj`/IDE-Projektdatei existiert bewusst noch nicht - beim ersten
  Oeffnen in der IDE (Datei `TaskService.dpr` oeffnen) legt Delphi sie
  automatisch an.

## Struktur

| Datei | Zweck |
| --- | --- |
| `TaskService.dpr` | Hauptprogramm: HTTP-Server (Indy `TIdHTTPServer`), Routing |
| `TaskModel.pas` | Datenmodell + Thread-sicherer In-Memory-Store |
| `JwtAuth.pas` | Access-Token pruefen (Bearer) - **TODO Signaturpruefung, s.o.** |
| `TaskEventPublisher.pas` | Published Events per STOMP an RabbitMQ (Fanout) |

## Starten

Voraussetzung: gemeinsame Infrastruktur laeuft (siehe
[`../contracts/README.md`](../contracts/README.md) -
`docker compose up --build` im `contracts`-Repo, startet Keycloak + RabbitMQ).

```
dcc64 TaskService.dpr
TaskService.exe
```

Konfiguration per Umgebungsvariable (Defaults passen zur gemeinsamen Infra):

| Variable | Default |
| --- | --- |
| `PORT` | `8090` |
| `RABBITMQ_HOST` | `localhost` |
| `RABBITMQ_STOMP_PORT` | `61613` |

## Manuell testen

```
# Token holen (siehe contracts/README.md fuer Demo-User)
curl -X POST http://localhost:8082/realms/task-mgmt/protocol/openid-connect/token ^
  -H "Content-Type: application/x-www-form-urlencoded" ^
  -d "grant_type=password&client_id=task-mgmt-client&username=levin&password=levin123"

# Aufgabe anlegen (access_token aus der Antwort oben einsetzen)
curl -X POST http://localhost:8090/tasks -H "Authorization: Bearer <token>" ^
  -H "Content-Type: application/json" -d "{\"title\":\"Rechnung schreiben\"}"
```
