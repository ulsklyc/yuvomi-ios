# Fixtures

JSON-Abzüge echter Server-Antworten für Vorschauen, Tests und den Demo-Modus der App.

## `demo/`

Gezogen am 02.11.2026 aus einer lokalen Seed-Instanz auf Yuvomi `v2.84.0` (`client_api: 1`). Die Daten stammen aus `scripts/seed-demo.js --locale en`, die Persona ist `alex`. Alle Lesewege laufen wie in der App über ein Geräte-Credential. Auch `alex` ist damit ein normales Mitglied, obwohl er Admin ist.

- Je Datei eine Antwort, benannt nach der Operation: `tasks.json` ist `GET /api/v1/tasks`, `task.json` ist `GET /api/v1/tasks/{id}` und so weiter. `_meta.json` nennt Quelle, Zeitpunkt und Serverversion.
- Geheimnisse sind ersetzt: Das Credential heißt `ydc_FIXTURE_CREDENTIAL`, der CSRF-Token `FIXTURE_CSRF_TOKEN`.
- Datumswerte hängen am Tag des Abzugs. Wer die Fixtures als „heute“ zeigen will, verschiebt sie relativ zu `captured_at`.
- `dashboard.json` enthält auch `budget`, `health` und `fasting`. Die App liest diese Felder in v1 nicht, ihre Modelle kennen sie nicht. Die Daten bleiben trotzdem drin, damit der Decoder unbekannte Felder nachweislich überspringt.
- `shopping-suggestions.json` ist leer, weil die Seed-Daten dafür keine Historie haben.

## Neu ziehen

1. In einem eigenen Worktree des Server-Repos auf dem gewünschten Tag: `npm ci`.
2. Datenbank befüllen: `node scripts/seed-demo.js --db <pfad>/demo.db --locale en`.
3. Server starten mit `DB_PATH=<pfad>/demo.db SESSION_SECURE=false PORT=3917 BIND_ADDRESS=127.0.0.1 BACKUP_ENABLED=false` und einem `SESSION_SECRET` mit mindestens 32 Zeichen.
4. Hier: `node Fixtures/dump-fixtures.mjs http://127.0.0.1:3917 alex demo1234 Fixtures/demo` (Passwort aus dem Seed-Skript).
5. Gegen die Spec prüfen: `node Fixtures/check-fixtures.mjs <server-worktree> Fixtures/demo`. Das Skript nutzt den Schema-Prüfer von `test:openapi-client-responses`. Beim Abzug vom 02.11.2026 passten alle 21 Antworten.
