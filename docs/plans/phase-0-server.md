# Phase 0: Server-Vorbereitung für den iOS-Client

Stand 01.11.2026, geprüft gegen `ulsklyc/yuvomi` bei `f7dbd295b` (v2.83.0). Grundlage sind die [Studie](https://claude.ai/artifact/BWAEz4MEjox6g7vZYTzUYW) und die Entscheidungen vom 01.11.2026. Aufwand gesamt 3 bis 4 PW, alle Größen sind Schätzungen.

**Ziel:** Ein Release von Yuvomi, gegen das die App ohne Sonderwege gebaut werden kann. Alle Änderungen sind abwärtskompatibel, und nichts davon ist iOS-spezifisch.

## Überblick

| # | Slice | Größe | Hängt ab von | Release-Spur |
|---|---|---|---|---|
| S1 | Instanz-Merkmal in `/version` | < 0,1 PW | - | Server |
| S2 | Geräte-Credential | ~1 PW | - | Server |
| S3 | QR-Kopplung | ~0,5 PW | S2 | Interface (Mi/So) |
| S4 | Kommende Erinnerungen | ~0,5 PW | - | Server |
| S5 | Spec-Hardening mit Guard | ~1 PW | S1 bis S4 | Server |
| S6 | Review-Instanz, Icon, Fixtures | ~0,5 PW | S1 bis S4 | - |

Jeder Slice ist ein eigenes Issue und ein eigener PR. Es gelten die Repo-Regeln: neuer Test mit eigener `test:<suite>` und rot gesehen, Migration nur am Ende von `MIGRATIONS`, Nummer erst direkt vor dem Merge, `MIGRATIONS_SQL` mitziehen, neue UI-Texte in allen 27 Locales über den Skill `locale-add`, keine Werkzeug-Attribution in Commits und PRs.

---

## S1: Instanz-Merkmal

**Problem:** `/version` nennt anonym nur `app_name`, `setup_required` und `password_reset_enabled`. Die Version steht hinter der Anmeldung, und `app_name` ist umbenennbar. Die App kann also weder eine Yuvomi-Instanz erkennen noch vor dem Login sagen, dass der Server zu alt ist.

**Änderung:** Zwei öffentliche Felder in `buildVersionPayload()` (`server/index.js`):

```json
{ "product": "yuvomi", "client_api": 1, "app_name": "...", "setup_required": false }
```

- `client_api` ist eine ganze Zahl, die nur steigt, wenn sich der Vertrag für native Clients ändert.
- Sie verrät nur eine grobe Generation, die exakte Version bleibt hinter der Anmeldung.

**Vorschlag, der die Studie ändert:** Die App prüft `client_api` vor dem Login statt der Mindestversion danach. Das ist einfacher und gibt eine klare Meldung, bevor jemand ein Passwort eintippt. Ein alter Server ohne das Feld gilt als "zu alt".

**Falle:** `/version` läuft mit Credential durch `requireAuth`. Ein ungültiges Token ergibt also 401. Die App muss die Probe ohne `Authorization`-Header senden.

**Dateien:** `server/index.js:430-445`, `server/openapi/schemas.js:839`. **Test:** Erweiterung der Suite um `/version`, anonym und angemeldet.

---

## S2: Geräte-Credential

**Grundentscheidung:** Das Credential ist eine Zeile in `api_tokens` mit `kind = 'device'`, keine neue Tabelle. Damit gelten automatisch: Bearer-Auth, CSRF-Ausnahme (`csrf.js:32`), `last_used_at`, Widerruf beim Deaktivieren (#1381) und der Riegel gegen ehemalige Konten.

**Migration:**

```sql
ALTER TABLE api_tokens ADD COLUMN kind TEXT NOT NULL DEFAULT 'integration';
ALTER TABLE api_tokens ADD COLUMN platform TEXT;
ALTER TABLE api_tokens ADD COLUMN device_id TEXT;
CREATE UNIQUE INDEX idx_api_tokens_active_device
  ON api_tokens (subject_user_id, device_id)
  WHERE kind = 'device' AND revoked_at IS NULL;
```

**Routen unter `/api/v1/auth`:**

| Route | Auth | Zweck |
|---|---|---|
| `POST /device-tokens` | nur Sitzung, CSRF | Sitzung gegen Credential tauschen |
| `GET /device-tokens` | Sitzung oder Credential | eigene Geräte listen |
| `DELETE /device-tokens/current` | Credential | Abmelden in der App |
| `DELETE /device-tokens/:id` | Sitzung oder Credential | eigenes Gerät widerrufen |

Body von `POST`: `{ "name": "iPhone von ...", "platform": "ios", "device_id": "<uuid>" }`. Dieselbe `device_id` ersetzt das aktive Credential, statt ein zweites anzulegen. Der Klartext erscheint genau einmal in der Antwort, wie bei `POST /api-tokens`.

**Ablauf beim Login:** `POST /auth/login`, bei 2FA `POST /auth/2fa/verify`, dann `POST /device-tokens` mit dem `csrfToken` aus der Login-Antwort, dann `POST /auth/logout`. Die App verwirft ihre Cookies und arbeitet nur noch mit Bearer. Damit laufen Rate-Limit, 2FA und `canSignIn` über die vorhandenen Wege.

**Regeln, die vor dem ersten Code feststehen:**

1. **Wer darf:** `canSignIn()` und `householdMemberSql()`. `canSignIn` deckt Personal, Displays und Ehemalige ab, lässt Ausgaben-Gäste aber durch. Das Mitglieds-Prädikat schließt sie aus, die `users`-Zeile allein reicht nicht.
2. **Keine Kette:** Ein Credential stellt kein weiteres Credential aus und keinen Kopplungscode. `POST /device-tokens` verlangt `req.authMethod === 'session'`, und `POST /api-tokens` weist Geräte-Credentials ab, auch bei Admins. Ein verlorenes Telefon darf keine dauerhafte Hintertür hinterlassen. Bei den späteren Admin-Funktionen wird das neu bewertet.
3. **Gleitend 90 Tage:** `apiTokenUsableSql()` bekommt die Bedingung für `kind = 'device'` auf Basis von `COALESCE(last_used_at, created_at)`. Die Funktion ist die eine Schreibweise für Anmelden und Aufräumen (D#1672), die Zahl kommt aus `SESSION_MAX_AGE_MS` und nicht als zweite Konstante. `expires_at` bleibt bei Geräten leer.
4. **Widerruf:** `invalidateUserSessions()` hat fünf Aufrufer: Passwort-Reset (`auth.js:2000`), "Auf anderen Geräten abmelden" (`:2345`), 2FA einschalten (`:3042`), Admin-Passwort (`:3746`) und eigener Passwortwechsel (`:4034`). Dort kommt der Widerruf aller Geräte hinein, der Kommentar "API-Tokens bleiben unberührt" muss angepasst werden. Integrations-Tokens bleiben stehen. Das Löschen eines Kontos läuft nicht über diese Funktion, es wird im Test eigens geprüft. Die Sitzung bleibt bei allen fünf ausgenommen, ein Gerät nie, auch nicht das aufrufende.
5. **Admin-Liste:** `GET /api-tokens` zeigt nur `kind = 'integration'`. Welche Geräte jemand benutzt, geht den Admin nichts an (DECISIONS Eintrag 1). Ein Admin beendet fremde Geräte über Deaktivieren oder Passwort-Reset.
6. **Fremde Rechte:** Credentials sind ungescopt, sonst scheitert `/auth/me` am Gate in `auth.js:572`. Sie handeln mit den Rollenrechten ihres Subjekts, nie mit mehr.

**Dateien:** `server/auth.js` (Tokens ab `:3230`, `:893`, `:921`), `server/db.js`, `server/db-schema-test.js`, `server/openapi/paths/auth.js`.

**Test `test:device-tokens` (rot sehen):** Mitglied darf, Personal, Display, Gast und Ehemalige nicht. Keine Ausstellung per Bearer. Kein neues API-Token per Credential. 90 Tage: Grenze knapp darunter und darüber bei eingefrorener Uhr, und Nutzung verlängert. Jeder der fünf Aufrufer aus Regel 4 beendet Geräte und lässt Integrations-Tokens stehen, das Löschen eines Kontos ebenfalls. Dieselbe `device_id` ersetzt. Fremdes Gerät ergibt 404. `/auth/me` funktioniert.

---

## S3: QR-Kopplung

**Kernpunkt: eigene Tabelle, nicht `display_pairing_codes`.** `redeemPairingCode()` prüft keinen Zweck. Läge ein Personen-Code in derselben Tabelle, ließe er sich über `POST /displays/pair` einlösen, und diese Route legt ein Display-Gerät an und beendet Sitzungen. Getrennte Tabellen machen diesen Fehler unmöglich.

```sql
CREATE TABLE device_pairing_codes (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
```

**Routen unter `/api/v1/auth`:**

| Route | Auth | Zweck |
|---|---|---|
| `POST /device-pairings` | nur Sitzung, CSRF | Code und QR erzeugen, älteren Code entwerten |
| `POST /device-pairings/redeem` | öffentlich, Rate-Limit | Code gegen Credential tauschen |

- QR-Inhalt: `yuvomi://pair?server=<origin>&code=<code>`. Der Scan in der App setzt beides, die URL muss niemand tippen.
- Laufzeit 5 Minuten statt der 15 beim Display, weil der Code direkt ein persönliches Konto öffnet.
- Einlösen läuft in einer Transaktion wie `redeemPairingCode()`, prüft `canSignIn` erneut und nennt für "unbekannt", "abgelaufen" und "benutzt" dieselbe Antwort.
- `generatePairingCode()`, `normalizePairingCode()` und `qrToDataUrl()` werden wiederverwendet, das Limit folgt `pairingLimiter`.
- Hinweis in der PWA: "Dieser Code meldet ein Gerät als du an. Zeige ihn niemandem."

**Offen, beim Bau zu klären:** Woher `server` im QR kommt. `Host` ist aus gutem Grund nicht vertrauenswürdig. Reihenfolge: `BASE_URL`, sonst die Herkunft, die die PWA aus `location.origin` mitschickt. `test:display-pairing-address` vorher lesen.

**PWA:** Abschnitt "Geräte" in `public/settings/pages/personal-account.js` mit Geräteliste, "Zuletzt benutzt", Widerruf und "Gerät koppeln". Texte über `t()`, Daten durch `esc()`, kein `innerHTML`.

**Test `test:device-pairing`:** Doppeleinlösung, Ablauf, neuer Code entwertet alten, Personal und Ehemalige. Dazu **Gegenprobe:** Ein Personen-Code wird von `/displays/pair` abgewiesen. `test:user-traces-guard` kennt die neue Tabelle.

---

## S4: Kommende Erinnerungen

**Problem:** `GET /reminders/pending` filtert auf `remind_at <= jetzt`, und `GET /reminders` braucht eine konkrete Entität.

**Änderung:** Die Abfrage aus `/pending` wandert in eine Funktion, beide Routen teilen sie. Die vielen Riegel (Herkunft, Sichtbarkeit, verwaiste Anker, abgeschaltete Module, Titel, Haushalts-Ansicht) dürfen nicht als zweite Fassung entstehen.

`GET /api/v1/reminders/upcoming?from=<iso>&to=<iso>&types=task,event`

- `from` und `to` sind Pflicht, das Fenster ist auf 14 Tage begrenzt, sortiert nach `remind_at`, höchstens 200 Zeilen.
- `types` schränkt die Herkünfte ein und kann sie nie erweitern, `readableOrigins()` bleibt die Grenze. Ein unbekannter Wert ergibt 400.
- `audience=household` liefert wie `/pending` eine leere Liste.
- `syncAllBirthdayReminders()` läuft vorher wie bei `/pending`.

**Wichtig für das erste Binary:** Die App fragt in v1 nur `types=task,event` ab. Ohne diesen Filter kämen über die Erinnerungen Gesundheits- und Finanztitel in ein Binary, das laut Apple-Anfrage solche Funktionen nicht enthält. Dasselbe gilt für `GET /dashboard`: Die Antwort trägt `budget`, `health` und `fasting`, soweit das Konto diese Module sehen darf, und ein ungescoptes Credential kann das nicht einschränken. Die App liest diese Felder in v1 nicht und zeigt sie nicht an, ihre Modelle kennen sie gar nicht. In S5 bekommen sie deshalb kein Schema.

**Bekannte Grenzen, in der App offen zu benennen:**

- Die Liste ist ein Abzug. Abgeleitete Typen baut der Server laufend neu.
- Wer die PWA mit Web Push nutzt, bekommt eine Erinnerung doppelt. Der Server weiß nichts von lokal geplanten Benachrichtigungen. Für v1 hinnehmbar, in den App-Einstellungen erklären.
- Ein Verwerfen an einem anderen Gerät erreicht das Telefon erst beim nächsten Abruf.

**Dateien:** `server/routes/reminders.js:209`, `server/openapi/paths/reminders.js`. **Test `test:reminders-upcoming`:** Fensterränder, Zeitzone mit `TZ=UTC` zusätzlich, fremde und private Zeilen fehlen, Token ohne Scope, abgeschaltetes Modul, `types` erweitert nichts. `test:reminders-routes` bleibt unverändert grün, das belegt die Extraktion.

---

## S5: Spec-Hardening mit Guard

Die Spec wächst um rund 14 Operationen pro Woche, ein einmaliges Aufräumen hielte also nicht. Deshalb steht am Anfang ein neuer Guard `test:openapi-client-contract` mit einer festen Liste von 39 Operationen. Jede davon braucht `operationId`, typisierte 2xx-Antwort und bei Bodies ein echtes Schema. Die Liste wird abgearbeitet, bis der Guard grün ist.

| Bereich | Anzahl | Operationen |
|---|---|---|
| Instanz | 1 | `GET /version` |
| Anmeldung | 4 | `POST /auth/login`, `POST /auth/2fa/verify`, `GET /auth/me`, `GET /auth/oidc/config` |
| Geräte | 5 | `POST`, `GET /auth/device-tokens`, `DELETE .../current`, `DELETE .../{id}`, `POST /auth/device-pairings/redeem` |
| Übersicht | 1 | `GET /dashboard` |
| Aufgaben | 8 | `GET`, `POST /tasks`; `GET /tasks/meta/options`; `GET`, `PUT`, `DELETE /tasks/{id}`; `PATCH /tasks/{id}/status`; `PATCH /tasks/{id}/check` |
| Einkauf | 10 | `GET`, `POST /shopping`; `GET /shopping/versions`; `GET /shopping/suggestions`; `GET /shopping/categories`; `GET`, `POST /shopping/{listId}/items`; `PATCH`, `DELETE /shopping/items/{itemId}`; `DELETE /shopping/{listId}/items/checked` |
| Kalender | 7 | `GET`, `POST /calendar`; `GET /calendar/upcoming`; `GET /calendar/calendars`; `GET`, `PUT`, `DELETE /calendar/{id}` |
| Erinnerungen | 3 | `GET /reminders/upcoming`, `GET /reminders/pending`, `PATCH /reminders/{id}/dismiss` |

**Reihenfolge:** Erst den Guard rot sehen, dann modulweise. Schemas aus echten Antworten ableiten, nicht aus Vermutungen. `GET /dashboard` ist die größte Einzelaufgabe.

**Entscheidung fällt hier:** Ist das Ergebnis gut genug, erzeugt der Swift OpenAPI Generator die Modelle. Sonst bleiben handgeschriebene Modelle hinter der Fassade. Das lässt sich erst mit einer gehärteten Spec beurteilen.

---

## S6: Review-Instanz, Icon, Fixtures

- **Review-Instanz:** Kleiner VPS mit eigener Subdomain von `yuvomi.cloud`, getrennt von echten Daten, nur für Apple, gefüllt mit `scripts/seed-demo.js`. Das bleibt mit `SCOPE.md:344-356` vereinbar, solange weder Link noch Zugang öffentlich werden. Ein Konto ohne 2FA vereinfacht die Review. Der Betriebsort ist noch deine Entscheidung.
- **Icon:** 1024 px ohne Alpha aus `icon.svg` über `scripts/generate-icons.js`.
- **Demo-Fixtures:** JSON-Abzüge der MVP-Antworten aus der Seed-Instanz, Ablage im App-Repo.

---

## Fertig, wenn

- [ ] Ein normales Mitglied kommt per Passwort und per QR zu einem Credential, ein SSO-only-Konto per QR.
- [ ] Personal, Displays, Gäste und Ehemalige bekommen keines.
- [ ] Alle Wege aus S2 Regel 4 beenden Geräte, Integrations-Tokens bleiben.
- [ ] `GET /reminders/upcoming` liefert für die vier Module nur Sichtbares.
- [ ] `test:openapi-client-contract` ist grün.
- [ ] Ein Release ist draußen, und die Review-Instanz läuft darauf.

## Noch offen

- Betriebsort der Review-Instanz.
- Herkunft von `server` im QR (S3).
- Ob `client_api` die Mindestversion ersetzt (S1). Falls ja, ändert sich ein Satz in der Studie.
