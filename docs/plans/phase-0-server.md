# Phase 0: Server-Vorbereitung für den iOS-Client

Stand 01.11.2026, geprüft gegen `ulsklyc/yuvomi` bei `f7dbd295b` (v2.83.0) und in einer Grilling-Runde gegen SPEC, SCOPE und DECISIONS abgeklopft. Grundlage sind die [Studie](https://claude.ai/artifact/BWAEz4MEjox6g7vZYTzUYW) und die Entscheidungen vom 01.11.2026. Aufwand gesamt rund 4 PW, alle Größen sind Schätzungen.

**Begriffe:** Ein iPhone ist ein **signed-in device** (UI: "Angemeldete Geräte"), sein Geheimnis das **device credential**, nie "device token", weil das bei Apple das APNs-Token meint. Ein Wandtablett bleibt ein **paired display**.

**Ziel:** Ein Release von Yuvomi, gegen das die App ohne Sonderwege gebaut werden kann. Alle Änderungen sind abwärtskompatibel, und nichts davon ist iOS-spezifisch.

## Überblick

| # | Slice | Größe | Hängt ab von | Release-Spur |
|---|---|---|---|---|
| S1 | Instanz-Merkmal in `/version` | < 0,1 PW | - | Server |
| S2 | Signed-in devices | ~1,25 PW | - | Server |
| S3 | Kopplung | ~0,5 PW | S2 | Interface (Mi/So) |
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

**Entschieden:** Die App prüft `client_api` vor dem Login statt der Mindestversion danach. Das gibt eine klare Meldung, bevor jemand ein Passwort eintippt. Ein alter Server ohne das Feld gilt als "zu alt". `MODULES.md` sagt, dass anonym keine Version kommt, das bleibt wahr.

**Falle:** `/version` läuft mit Credential durch `requireAuth`. Ein ungültiges Token ergibt also 401. Die App muss die Probe ohne `Authorization`-Header senden.

**Dateien:** `server/index.js:430-445`, `server/openapi/schemas.js:839`. **Test:** Erweiterung der Suite um `/version`, anonym und angemeldet.

---

## S2: Signed-in devices

**Grundentscheidung:** Das Credential ist eine Zeile in `api_tokens` mit `kind = 'device'`, keine neue Tabelle. Damit gelten die 31 Prüfstellen auf `authMethod` unverändert, dazu CSRF-Ausnahme (`csrf.js:32`), `last_used_at`, Widerruf beim Deaktivieren (#1381) und Löschen per Cascade. Eine vergessene Filterstelle zeigt schlimmstenfalls einem Admin ein Gerät, eine vergessene Prüfung in einer eigenen Tabelle wäre eine Sicherheitslücke. Die Spec-Definition von "API Tokens" wird dafür erweitert, Wortlaut in [01-position-texte.md](../drafts/01-position-texte.md).

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
| `POST /devices` | nur Sitzung, CSRF | Sitzung gegen Credential tauschen |
| `GET /devices` | Sitzung oder Credential | eigene Geräte listen |
| `DELETE /devices/current` | Credential | Abmelden in der App |
| `DELETE /devices/:id` | Sitzung oder Credential | eigenes Gerät widerrufen |
| `POST /users/:id/devices/sign-out` | Admin, nur Sitzung, CSRF | alle Geräte eines Mitglieds abmelden |

Body von `POST`: `{ "name": "iPhone von ...", "platform": "ios", "device_id": "<uuid>" }`. Dieselbe `device_id` ersetzt das aktive Credential, statt ein zweites anzulegen. Der Klartext erscheint genau einmal in der Antwort, wie bei `POST /api-tokens`.

**Ablauf beim Login:** `POST /auth/login`, bei 2FA `POST /auth/2fa/verify`, dann `POST /devices` mit dem `csrfToken` aus der Login-Antwort, dann `POST /auth/logout`. Die App verwirft ihre Cookies und arbeitet nur noch mit Bearer. Damit laufen Rate-Limit, 2FA und `canSignIn` über die vorhandenen Wege.

**Regeln, die vor dem ersten Code feststehen:**

1. **Wer darf:** `canSignIn()` und `householdMemberSql()`. `canSignIn` deckt Personal, Displays und Ehemalige ab, lässt Ausgaben-Gäste aber durch. Das Mitglieds-Prädikat schließt sie aus, die `users`-Zeile allein reicht nicht.
2. **Keine Kette, keine Verwaltung:** Ein Credential stellt kein weiteres Credential aus und keinen Kopplungscode, `POST /devices` verlangt `req.authMethod === 'session'`. `requireAdmin` weist Credentials mit `reason: 'device_credential'` ab, ohne Ausnahme. Damit ist auch `POST /api-tokens` zu. Ein Admin ist in der App ein normales Mitglied, ein verlorenes Telefon erreicht keine Haushaltsverwaltung. Die Sperre gehört in `isAdminRequest()` (`server/middleware/require-admin.js`), weil die Funktion auch außerhalb der Middleware gefragt wird. Daneben stehen zwölf Inline-Prüfungen auf die Admin-Rolle, jede braucht einzeln dieselbe Entscheidung. Spätere Admin-Funktionen öffnen das je Funktion mit erneuter Anmeldung.
3. **Gleitend 90 Tage:** `apiTokenUsableSql()` bekommt die Bedingung für `kind = 'device'` auf Basis von `COALESCE(last_used_at, created_at)`. Die Funktion ist die eine Schreibweise für Anmelden und Aufräumen (D#1672), die Zahl kommt aus `SESSION_MAX_AGE_MS` und nicht als zweite Konstante. `expires_at` bleibt bei Geräten leer.
4. **Widerruf:** `invalidateUserSessions()` hat fünf Aufrufer: Passwort-Reset (`auth.js:2000`), "Auf anderen Geräten abmelden" (`:2345`), 2FA einschalten (`:3042`), Admin-Passwort (`:3746`) und eigener Passwortwechsel (`:4034`). Dort kommt der Widerruf aller Geräte hinein, der Kommentar "API-Tokens bleiben unberührt" muss angepasst werden. Integrations-Tokens bleiben stehen. Das Löschen eines Kontos läuft nicht über diese Funktion, es wird im Test eigens geprüft. Die Sitzung bleibt bei allen fünf ausgenommen, ein Gerät nie, auch nicht das aufrufende.
5. **Admin-Sicht:** `GET /api-tokens`, `DELETE /api-tokens/:id` und `/remove` wirken nur auf `kind = 'integration'`. Wann jemand welches Gerät benutzt, geht den Admin nichts an (DECISIONS Eintrag 1). Für den Notfall, etwa das verlorene Handy eines Kindes im SSO-Haushalt ohne Passwort, gibt es `POST /users/:id/devices/sign-out`: Eine Aktion ohne Liste, ohne Gerätenamen und ohne Nutzungszeiten.
6. **Fremde Rechte:** Credentials sind ungescopt, sonst scheitert `/auth/me` am Gate in `auth.js:572`. Sie handeln mit den Rollenrechten ihres Subjekts, nie mit mehr.

**Dateien:** `server/auth.js` (Tokens ab `:3230`, `:893`, `:921`), `server/db.js`, `server/db-schema-test.js`, `server/openapi/paths/auth.js`.

**Test `test:signed-in-devices` (rot sehen):** Mitglied darf, Personal, Display, Gast und Ehemalige nicht. Keine Ausstellung per Bearer. Kein neues API-Token per Credential. 90 Tage: Grenze knapp darunter und darüber bei eingefrorener Uhr, und Nutzung verlängert. Jeder der fünf Aufrufer aus Regel 4 beendet Geräte und lässt Integrations-Tokens stehen, das Löschen eines Kontos ebenfalls. Dieselbe `device_id` ersetzt. Fremdes Gerät ergibt 404. `/auth/me` funktioniert. Credential eines Admins bekommt von `requireAdmin` 403, Admin-Sign-out beendet alle Geräte des Mitglieds und antwortet ohne Gerätedaten.

---

## S3: Kopplung

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
| `POST /devices/pair` | nur Sitzung, CSRF | Code und QR erzeugen, älteren Code entwerten |
| `POST /devices/pair/redeem` | öffentlich, Rate-Limit | Code gegen Credential tauschen |

- Der Bildschirm bietet **drei Wege zum selben Code:** QR für ein zweites Gerät, "In der App öffnen" über `yuvomi://pair?server=<origin>&code=<code>` für dasselbe Gerät und den lesbaren Code zum Abtippen. Sonst käme jemand mit nur einem iPhone im SSO-Haushalt nie hinein.
- `server` ist `window.location.origin` aus der PWA, wie beim Display-Pairing (#2294). Die Route bekommt die Herkunft im Body, prüft sie als http(s)-URL und baut daraus nur den QR für dieselbe angemeldete Person.
- Laufzeit 5 Minuten statt der 15 beim Display, weil der Code direkt ein persönliches Konto öffnet.
- Einlösen läuft in einer Transaktion wie `redeemPairingCode()`, prüft `canSignIn` erneut und nennt für "unbekannt", "abgelaufen" und "benutzt" dieselbe Antwort.
- `generatePairingCode()`, `normalizePairingCode()` und `qrToDataUrl()` werden wiederverwendet, das Limit folgt `pairingLimiter`.
- Hinweis in der PWA: "Dieser Code meldet ein Gerät als du an. Zeige ihn niemandem."

**Deaktivieren:** `SPEC.md` verlangt, dass offene Display-Codes im selben Zuge verfallen. `server/services/user-removal.js` entwertet deshalb auch offene `device_pairing_codes`.

**PWA:** Abschnitt "Angemeldete Geräte" in `public/settings/pages/personal-account.js` mit Geräteliste, "Zuletzt benutzt", Widerruf und "Gerät koppeln". Texte über `t()`, Daten durch `esc()`, kein `innerHTML`.

**Test `test:device-pairing`:** Doppeleinlösung, Ablauf, neuer Code entwertet alten, Personal und Ehemalige. Dazu **Gegenprobe:** Ein Personen-Code wird von `/displays/pair` abgewiesen. `test:user-traces-guard` kennt die neue Tabelle.

---

## S4: Kommende Erinnerungen

**Problem:** `GET /reminders/pending` filtert auf `remind_at <= jetzt`, und `GET /reminders` braucht eine konkrete Entität.

**Änderung:** Die Abfrage aus `/pending` wandert in eine Funktion, beide Routen teilen sie. Die vielen Riegel (Herkunft, Sichtbarkeit, verwaiste Anker, abgeschaltete Module, Titel, Haushalts-Ansicht) dürfen nicht als zweite Fassung entstehen.

`GET /api/v1/reminders/upcoming?from=<iso>&to=<iso>&types=task,event`

**Zeitzonen-Falle:** `reminders.remind_at` ist naiv-UTC ohne Suffix, alte Zeilen tragen teils einen Offset. Swift läse das als Ortszeit, und auf Reisen käme die Erinnerung um Stunden falsch. Jede Zeile bekommt deshalb zusätzlich `fires_at` als normalisierten Zeitpunkt mit `Z`, abgeleitet über `remindAtUtcSql()`. Die App nutzt nur dieses Feld.

- `from` und `to` sind Pflicht, das Fenster ist auf 14 Tage begrenzt, sortiert nach `remind_at`, höchstens 200 Zeilen.
- `types` schränkt die Herkünfte ein und kann sie nie erweitern, `readableOrigins()` bleibt die Grenze. Ein unbekannter Wert ergibt 400.
- `audience=household` liefert wie `/pending` eine leere Liste.
- `syncAllBirthdayReminders()` läuft vorher wie bei `/pending`.

**Wichtig für das erste Binary:** Die App fragt in v1 nur `types=task,event` ab. Ohne diesen Filter kämen über die Erinnerungen Gesundheits- und Finanztitel in ein Binary, das laut Apple-Anfrage solche Funktionen nicht enthält. Dasselbe gilt für `GET /dashboard`: Die Antwort trägt `budget`, `health` und `fasting`, soweit das Konto diese Module sehen darf, und ein ungescoptes Credential kann das nicht einschränken. Die App liest diese Felder in v1 nicht und zeigt sie nicht an, ihre Modelle kennen sie gar nicht. In S5 bekommen sie deshalb kein Schema.

**Bekannte Grenzen, in der App offen zu benennen:**

- Die Liste ist ein Abzug. Abgeleitete Typen baut der Server laufend neu.
- Wer die PWA mit Web Push nutzt, bekommt eine Erinnerung doppelt. Der Server weiß nichts von lokal geplanten Benachrichtigungen. Für v1 hinnehmbar, in den App-Einstellungen erklären.
- Ein Verwerfen an einem anderen Gerät erreicht das Telefon erst beim nächsten Abruf.
- Die App plant beim Abhaken selbst ab. `/upcoming` lässt erledigte und abgelegte Aufgaben zwar aus, das wirkt aber erst beim nächsten Abruf.
- Die App rechnet das Fenster mit 14 × 86400 Sekunden. `Calendar.date(byAdding: .day, value: 14)` ergibt über die Zeitumstellung im Herbst eine Stunde mehr, und der Server antwortet 400.
- Ein gelöschtes erstes Vorkommen einer Serie feuert noch, weil die Erinnerung am Master hängt und `calendar_event_exceptions` nicht geprüft wird. `/pending` und die Zustellung haben dieselbe Lücke.
- Abgesagte Termine gibt es als Zustand nicht, `STATUS:CANCELLED` wird nicht ausgewertet. Ein abgesagter, nicht gelöschter Termin erinnert also weiter.

**Dateien:** `server/routes/reminders.js:209`, `server/openapi/paths/reminders.js`. **Test `test:reminders-upcoming`:** Fensterränder, Zeitzone mit `TZ=UTC` zusätzlich, `fires_at` für naive Zeilen und Zeilen mit Offset, fremde und private Zeilen fehlen, Token ohne Scope, abgeschaltetes Modul, `types` erweitert nichts. `test:reminders-routes` bleibt unverändert grün, das belegt die Extraktion.

---

## S5: Spec-Hardening mit Guard

Die Spec wächst um rund 14 Operationen pro Woche, ein einmaliges Aufräumen hielte also nicht. Deshalb steht am Anfang ein neuer Guard `test:openapi-client-contract` mit einer festen Liste von 39 Operationen. Jede davon braucht `operationId`, typisierte 2xx-Antwort und bei Bodies ein echtes Schema. Die Liste wird abgearbeitet, bis der Guard grün ist.

| Bereich | Anzahl | Operationen |
|---|---|---|
| Instanz | 1 | `GET /version` |
| Anmeldung | 4 | `POST /auth/login`, `POST /auth/2fa/verify`, `GET /auth/me`, `GET /auth/oidc/config` |
| Geräte | 5 | `POST`, `GET /auth/devices`, `DELETE .../current`, `DELETE .../{id}`, `POST /auth/devices/pair/redeem` |
| Übersicht | 1 | `GET /dashboard` |
| Aufgaben | 8 | `GET`, `POST /tasks`; `GET /tasks/meta/options`; `GET`, `PUT`, `DELETE /tasks/{id}`; `PATCH /tasks/{id}/status`; `PATCH /tasks/{id}/check` |
| Einkauf | 10 | `GET`, `POST /shopping`; `GET /shopping/versions`; `GET /shopping/suggestions`; `GET /shopping/categories`; `GET`, `POST /shopping/{listId}/items`; `PATCH`, `DELETE /shopping/items/{itemId}`; `DELETE /shopping/{listId}/items/checked` |
| Kalender | 7 | `GET`, `POST /calendar`; `GET /calendar/upcoming`; `GET /calendar/calendars`; `GET`, `PUT`, `DELETE /calendar/{id}` |
| Erinnerungen | 3 | `GET /reminders/upcoming`, `GET /reminders/pending`, `PATCH /reminders/{id}/dismiss` |

**Reihenfolge:** Erst den Guard rot sehen, dann modulweise. Schemas aus echten Antworten ableiten, nicht aus Vermutungen. `GET /dashboard` ist die größte Einzelaufgabe.

**Entscheidung fällt hier:** Ist das Ergebnis gut genug, erzeugt der Swift OpenAPI Generator die Modelle. Sonst bleiben handgeschriebene Modelle hinter der Fassade. Das lässt sich erst mit einer gehärteten Spec beurteilen.

---

## S6: Review-Instanz, Icon, Fixtures

- **Review-Instanz:** Kleiner VPS in der EU mit eigener Subdomain von `yuvomi.cloud` und HTTPS, offizielles Image, nur Seed-Daten aus `scripts/seed-demo.js`, Update per Skript. Das bleibt mit `SCOPE.md:344-356` vereinbar, solange weder Link noch Zugang öffentlich werden. Ein Konto ohne 2FA vereinfacht die Review. `yuvomi.cloud` selbst läuft auf GitHub Pages, die Subdomain zeigt also separat auf den VPS.
- **Icon:** 1024 px ohne Alpha aus `icon.svg` über `scripts/generate-icons.js`.
- **Demo-Fixtures:** JSON-Abzüge der MVP-Antworten aus der Seed-Instanz, Ablage im App-Repo.

**Stand 2026-11-02:**

- Die Subdomain heißt `review.yuvomi.cloud`, der VPS läuft bei IONOS. Die Instanz läuft seit dem 02.11.2026 auf `2.84.0` mit HTTPS und Seed-Daten, alle Konten haben zufällige Passwörter. Einzelheiten und offene Punkte stehen in [s6-vps-checkliste.md](s6-vps-checkliste.md).
- **Icon, fertig:** `design/app-icon/AppIcon-1024.png`. Abweichung: `scripts/generate-icons.js` kennt keine 1024 px. Das Icon entsteht deshalb mit `design/app-icon/make-icon.mjs` aus denselben SVG-Bausteinen, randlos statt mit Rundung, weil iOS die Maske selbst legt.
- **Fixtures, fertig:** `Fixtures/demo/`, 21 Antworten plus `_meta.json` aus einer lokalen Seed-Instanz auf `v2.84.0`, Persona `alex`, Lesewege über ein Geräte-Credential. Alle 21 passen zum Antwort-Schema der Spec. Abweichung: Sie kommen aus einer lokalen Instanz statt von der Review-Instanz, damit die App-Entwicklung nicht auf den VPS wartet. Neu ziehen geht laut `Fixtures/README.md`.

---

## Abweichungen beim Bau (S1, S2)

- **S1:** `client_api` startet bei `0`, nicht bei `1`. Die `1` kommt erst, wenn die Routen aus S2 bis S4 draußen sind, sonst behauptet ein Server einen Vertrag, den er nicht hält. Die App verlangt mindestens `1`.
- **S2, Admin-Sperre:** Sie sitzt nicht in `isAdminRequest()`, sondern in `requireAuth`, das `authRole = 'member'` setzt. `isAdminRequest()` entscheidet an rund hundert Stellen auch Leseregeln, und so sind die Inline-Prüfungen auf `authRole` gleich mit abgedeckt.
- **S2, Rechte-Auflösung:** `authRole` allein reichte nicht, weil Capabilities die Rolle aus der Datenbank lesen. `userForRequest()` und `actingAsMember` in `server/permissions.js` stufen auch dort herab. Bekannte Lücke: `server/services/fasting.js` liest die Rolle ohne Anfragebezug, das ist vor Phase 3 zu prüfen.
- **S2, Integrations-Tokens:** Geräte-Routen weisen sie über `refuseIntegrationToken` ab (Grund `session_required`), sonst läse ein Admin über `subject_user_id` fremde Geräte.
- **S2, neu:** Allowlist `DEVICE_AUTH_ROUTES` am Eingang von `/auth`. Ohne sie käme ein Credential an `/2fa/disable`, `/me/profile` und `/me/password`.
- **S2, Admin-Abmeldung:** `POST /users/:id/devices/sign-out` beendet auch die Browser-Sitzungen, weil das Telefon die PWA tragen kann, und antwortet ohne Zahl.
- **S2, Zähler:** `ended` in `/logout-others` zählt Geräte mit.

## Abweichungen beim Bau (S3)

- **Aufteilung:** Der Server-Teil geht als eigener PR auf die Server-Spur. Der PWA-Abschnitt "Angemeldete Geräte" und die 27 Locales folgen als eigener PR kurz vor dem TestFlight-Start, Entscheidung vom 01.11.2026. Vorher führte der Knopf zu einer App, die es noch nicht gibt, und ein Schalter wäre toter Code. Bis dahin lässt sich die Kopplung über die API prüfen. Der Punkt "SSO-only per App-Link" unter "Fertig, wenn" hängt deshalb am PWA-PR.
- **Entwertung, neu:** Abmelden und `invalidateUserSessions()` entwerten auch offene Kopplungscodes. Sonst läge danach noch bis zu fünf Minuten ein gültiger Schlüssel in der Welt.
- **Herkunft:** höchstens 170 Zeichen in kodierter Form, weil `qrcode.js` nur bis Version 10 reicht. Verlangt wird die blanke Origin, ein Pfad ergibt 400.
- **Absage:** `reason: invalid_pairing_code` für unbekannt, abgelaufen, benutzt und für Konten, die kein Gerät mehr haben dürfen. Die App kann das so von einem ungültigen Rumpf unterscheiden, und ein ungültiger Rumpf verbraucht den Code nicht.
- **App:** `POST /devices/pair/redeem` ohne `Authorization`-Header senden, ein gültiges Credential ergibt dort 403.
- **App, Sicherheit:** `yuvomi://` ist nicht exklusiv, eine fremde App kann das Schema registrieren und den Code abfangen. Jede Website kann außerdem einen Link mit fremdem `server` bauen. Die App zeigt deshalb vor dem Einlösen die Server-Adresse und lässt sie bestätigen. Vor dem TestFlight-Start ist zu prüfen, ob der Weg für dasselbe Gerät besser ein Universal Link wird. Selbst gehostete Domains können das nur eingeschränkt, das ist also offen.
- **Bekannt, nicht aus S3:** `POST /displays/pair` wandelt einen Nicht-String als `code` ungeprüft um und kann daran mit 500 scheitern. Das ist ein kleiner eigener Fix.

## Abweichungen beim Bau (S5)

- **Zweite Suite, neu:** `test:openapi-client-responses` fährt alle 39 Operationen gegen einen echten Server und prüft Typ, Format, Muster, `oneOf`-Zweig und Felder ohne Schema. Fehlerantworten und Bodies prüft sie nicht.
- **`date-time` heißt, was `.iso8601` in Swift liest:** Sekunden und Zone, keine Bruchteile. `housekeeping.presentSince` und `lastVisit` tragen Millisekunden und haben deshalb kein `format`. Die App parst sie selbst.
- **`/reminders/pending` hat kein `fires_at`:** `remind_at` kommt dort in mehreren Formen, die App nutzt `/upcoming`.
- **`to` in `GET /calendar`** ist ohne Parameter immer der 31., auch im November. Die App schickt `from` und `to` selbst.
- **Generatorlauf vom 2026-11-02:** Swift OpenAPI Generator 1.14.3, Runtime 1.13.3, Swift 6.4.2, macOS 27, `filter` auf die 39 Operationen, `namingStrategy: idiomatic`, auf Stand `0f541f5a3`. Lief im Scratch-Ordner, nichts davon liegt im Repo. Ergebnis, gemessen an 149 echten Antworten aus `test:openapi-client-responses` plus 1.123 daraus abgeleiteten gültigen Fällen (einzelne Felder `null` oder weggelassen), jeweils mit dem echten `ISO8601DateTranscoder`:
  - **Trägt:** Der Code entsteht und kompiliert, alle Fälle dekodieren. Gegenproben schlagen an: Von 2.396 ungültigen Fällen fallen die falschen Typen fast alle durch (rot 1.511 von 1.548), Millisekunden in 54 von 56 Feldern. Boolean-`enum` wird `Bool`, `enum` mit `null` ein Optional, `DELETE` mit optionalem Body sendet ohne Body und ohne `Content-Type`.
  - **Grün war zunächst irreführend:** `oneOf` und `anyOf` mit einem Zweig `{type: 'null'}` lassen die ganze Eigenschaft **ohne Fehler** verschwinden, nur eine Warnung bleibt. Betroffen sind 11 Eigenschaften: `end_datetime` in `CalendarEvent` und den beiden Calendar-Inputs, `assigned_to` und `tags` in den Task-Inputs, `assigned_to` in den Calendar-Inputs, `DashboardNutrition.target`, `DashboardResponse.pantryExpiring`. Sichtbar wurde das erst durch einen Rundlauf, der jeden Wert der Originalantwort im Modell sucht.
  - **`null` lässt sich nicht senden:** Optionale Felder werden bei `nil` weggelassen, auch dort, wo `null` laut Spec leert (`end_datetime`, `description`, `location`, `color` in `CalendarEventUpdateInput`). Die Task-Eingaben erlauben `null` ebenfalls, etwa bei `due_date`; ob das dort leert, ist nicht geprüft. Die App könnte so kein Termin-Ende entfernen.
  - **`CalendarDateOrDateTime`** kommt als Enum mit drei Fällen, der Decoder prüft aber kein `pattern`: Jeder String landet in `case1`, auch `kein datum`. Die App muss den Wert selbst unterscheiden.
  - **Typ-Listen mit `integer` und `array`** verlieren die Listenform (`Int?`), das ist kein Ausweg für `assigned_to`.
  - **`required` plus `null`** wird zu einem Optional: Ein weggelassenes Pflichtfeld fällt beim Dekodieren nicht auf (209 Fälle). Das ist nachsichtig, schadet aber nicht, dafür gibt es die Serverseite in `test:openapi-client-responses`.
  - **Millisekunden:** Der Runtime-Transcoder lehnt sie ab, `housekeeping.*` ohne `format` bleibt also richtig. `JSONDecoder` mit `.iso8601` nimmt sie unter macOS 27 an und schneidet ab. Das gilt nur für diese Plattform; iOS 26 ist nicht gemessen.
- **Entscheidung:** Generator mit zwei gezielten Ergänzungen, vom User am 2026-11-02 bestätigt. Gemessen mit: 0 Warnungen, keine fehlende Eigenschaft, kein verlorener Wert, alle 1.272 gültigen Fälle grün, und `PUT /calendar/{id}` sendet `{"assigned_to":[2,3],"description":null,"end_datetime":null}`. Im Test war nur `CalendarEventUpdateInput` ausgeschrieben, die anderen vier waren Platzhalter.
  1. Spec, mit #2467 gemergt (`0c42bdac2`): `CalendarEvent.end_datetime` ist `type: ['string', 'null']` mit einem `pattern` für alle drei Formen, `format: date` entfällt dort also. `target` und `pantryExpiring` zeigen per `$ref` auf Schemas mit `type: ['object', 'null']`. `test:openapi-client-contract` lehnt an Parametern, Bodies und Antworten jedes Status ab: `{type: 'null'}` als Zweig oder eigener Typ, `not` und Typ-Listen mit mehr als einem Typ neben `null`. Ausgenommen sind die vier Bodies in `CLIENT_HAND_WRITTEN_BODIES`.
  2. App, beim Bau: `typeOverrides` für die fünf Eingaben mit `null`-Semantik oder Listenform (`TaskCreateInput`, `TaskUpdateInput`, `CalendarEventCreateInput`, `CalendarEventUpdateInput`, `ShoppingItemUpdateInput`), handgeschrieben mit `unset`, `clear`, `set`. Der Build der App bricht bei jeder Generator-Warnung ab.

**Serverfehler, gefunden beim Bau, nicht behoben.** Alle stammen aus der Zeit vor Phase 0. Unabhängig gemessen:

- `GET /calendar` und `/calendar/upcoming` liefern für Serien in `reminder_anchor_start` das letzte Vorkommen im Fenster statt des Serienbeginns. Das hat beim Speichern im PWA-Dialog auch gespeicherte Erinnerungen verschoben. Behoben mit #2468 (`6964f76ce`, 2026-11-02): Jedes Vorkommen trägt den Serienbeginn, der Dialog lässt unberührte Erinnerungen externer Serien stehen. Schon verschobene Zeilen bleiben, sie lassen sich nicht sicher erkennen; eine lesende Diagnose ist möglich, aber nicht beauftragt.
- `PUT /reminders` löscht und legt neu an, mit `dismissed = 0` und `pushed_at IS NULL` (`server/routes/reminders.js`). Nach dem Lesen meldet sich dadurch eine vergangene Erinnerung einer Serie nach jedem Speichern der ganzen Serie erneut. Nicht gemessen.
- `PATCH /shopping/items/{id}` antwortet mit `category: null` und `name: 5` 500.
- `POST /tasks` antwortet mit `category: null` und `title: 5` 500, `PUT /tasks/{id}` mit `title: null` ebenso.
- `PUT /tasks/{id}` speichert `title: ''`, gegen `minLength: 1` in der Spec.
- `DELETE /shopping/{listId}/items/checked` antwortet bei unbekannter Liste 200 statt 404. Der Test hält das fest und muss beim Fix mit.

Nur von je einem Agenten gemeldet, noch nicht unabhängig bestätigt: weitere 500er durch fehlende Typprüfung bei `PATCH /shopping/items/{id}` und `POST`/`PUT /calendar`, fehlende Längenprüfung im PATCH, `is_checked: 'false'` hakt ab, leere Datumswerte bei `POST /tasks` landen als `''` in der Antwort und verletzen `format: date`, `toLocalDateKey()` statt `todayKey()` in `server/routes/tasks.js:980` und `server/mcp/tools.js:67`.

## Restplan, Entscheidungen vom 2026-11-02

- **Validierungs-PR vor dem Release:** Er behebt die bestätigten Serverfehler oben. Die nur einmal gemeldeten Fehler werden zuerst gemessen und dann behoben oder verworfen. Die Typprüfungen kommen gezielt in `tasks.js`, `shopping.js` und `calendar.js`, mit den vorhandenen Helfern aus `server/middleware/validate.js`, jeder Fall mit Regressionstest. Die Helfer selbst bleiben unverändert, weil rund 20 Routen und die PWA an ihnen hängen.
  - Gemergt mit ulsklyc/yuvomi#2471 (`ad1d29f79`, 2026-11-02). Abweichung: Die Typprüfung läuft über einen neuen Helfer `textShape()` in `validate.js`, damit dieselbe Prüfung nicht dreimal im Code steht; die vorhandenen Helfer bleiben unverändert. Mitgenommen wurden `POST /shopping/{listId}/items` mit denselben Formen und der Tagesschlüssel in `GET /tasks` und MCP `list_tasks`. Die Messung bestätigte auch die nur einmal gemeldeten Fehler. Neu gefunden: Ein leerer oder `null`-Titel im `PUT /calendar` wurde gespeichert oder still ignoriert, und Zahlen landeten in Textfeldern als `"5.0"`.
- **`PUT /reminders`** im selben PR: zuerst mit einem Test messen, ob der Gelesen-Status zurückgesetzt wird, dann beheben. Sonst bringt `/upcoming` alte Erinnerungen zurück, sobald jemand in der PWA eine Serie speichert.
- **Release:** Das nächste Release bringt diese Fixes und `client_api: 1` (gemergt mit ulsklyc/yuvomi#2472, `fbe6359b2`)). Veröffentlicht als `v2.84.0` am 2026-11-02, Docker- und Umbrel-Publish grün. Der PWA-Teil von S3 ändert keine Route und gehört nicht zum Vertrag. Das Release selbst braucht weiter eine ausdrückliche Freigabe.
- **Serien-Lücke:** Gelöschte erste Vorkommen erinnern weiter, das gilt für `/upcoming`, `/pending` und die Zustellung. Das ist kein Blocker für Phase 0, es läuft als ulsklyc/yuvomi#2470.
- **S6:** Kommt direkt nach dem Release, weil die Fixtures schon für die App-Entwicklung gebraucht werden. Der VPS läuft bei IONOS.
- **Apple-Anfrage:** ist abgeschickt, die Antwort steht aus.

## Fertig, wenn

- [ ] Ein normales Mitglied kommt per Passwort und per Kopplung zu einem Credential.
- [ ] Personal, Displays, Gäste und Ehemalige bekommen keines, und kein Credential erreicht eine Admin-Route.
- [ ] Alle Wege aus S2 Regel 4 beenden Geräte, Integrations-Tokens bleiben.
- [ ] `GET /reminders/upcoming` liefert für die vier Module nur Sichtbares.
- [ ] `test:openapi-client-contract` ist grün.
- [x] Ein Release ist draußen, und die Review-Instanz läuft darauf (`v2.84.0`, `review.yuvomi.cloud`, 2026-11-02).

## Vor TestFlight

Diese Punkte hängen nicht am Server-Vertrag und halten Phase 0 deshalb nicht auf.

- [x] Der PWA-PR mit dem Abschnitt „Angemeldete Geräte“ und den 27 Locales ist gemergt (ulsklyc/yuvomi#2496, `12e442668`). Codex fand fünf Lücken im Takt der Kopplung, alle im selben PR behoben: Liste vor „abgelaufen“, Code bleibt nach einem neuen Gerät stehen, ein gescheiterter neuer Code beendet den alten nicht, Sammel-Abmeldung, Passwortwechsel und 2FA leeren die Karte.
- [x] Ein SSO-only-Konto mit nur einem Gerät kommt per App-Link zu einem Credential. Belegt im Simulator gegen einen Server ohne Passwort-Login, die SSO-Anmeldung selbst ist offen (siehe B6).
- [x] Entschieden ist, ob dasselbe Gerät per Universal Link oder per `yuvomi://` gekoppelt wird: `yuvomi://` bleibt, siehe [ADR 0001](../adr/0001-kopplung-per-yuvomi-schema.md).
- [ ] Die Antwort auf die Apple-Anfrage steht in den Review-Notes.

## B6 (Vor TestFlight)

Lauf am 03.11.2026 gegen den Demo-Seed aus dem Server-Branch `pwa-signed-in-devices`. Konto emma, Plattform `ios`, Stand in `api_tokens` nach jedem Fall. Simulator und iPhone liefen gegen getrennte Kopien der Datenbank, die Ids gelten je Lauf.

| Fall | Weg | `api_tokens` |
|---|---|---|
| Simulator, Link | Code in der PWA, Link per `simctl openurl`, Bestätigung, Aufgabenliste. Die PWA meldet „„iPhone“ (iOS) hat sich gerade angemeldet“. | id 1, `kind = device` |
| Simulator, Widerruf | „Abmelden“ in der PWA, dann Pull-to-refresh in der App: zurück zum Login | id 1, `revoked_at` gesetzt |
| Simulator, SSO-only | emma ohne Passwort (`$oidc$`), Server mit `password_login_enabled: false`, Passwort-Login ergibt 401. App-Link aus der PWA führt zum Credential. | id 2 (Simulator), `kind = device` |
| iPhone, „In der App öffnen“ | PWA in Safari auf dem iPhone, Knopf, Bestätigung in der App | id 2, danach in der App abgemeldet |
| iPhone, QR | QR aus der PWA am Mac mit dem Scanner der App | id 3, danach in der App abgemeldet |
| iPhone, Code | Code aus der PWA am Mac in der App abgetippt | id 4, aktiv |

Abweichungen:

- **SSO-only:** Im Server-Repo gibt es keinen lauffähigen OIDC-Anbieter, die Tests ersetzen nur das Modul. Die Browser-Sitzung stammt deshalb aus der Zeit vor der Umstellung auf SSO-only. Belegt ist der Weg ab der Sitzung: Code, App-Link, Credential. Die Anmeldung über einen echten IdP bleibt für die Review-Instanz.
- **Simulator, Code abtippen:** Die Eingabe per Einfügen kam im Simulator nicht an. Den abgetippten Code belegt der iPhone-Lauf.
- **PWA:** Bei voller Breite stand der QR neben den Schritten statt darunter, behoben im selben PR. „Auf anderen Geräten abmelden“ nennt jetzt auch die angemeldeten Geräte, die der Server schon mit abmeldete.
- **Universal Link:** bleibt `yuvomi://`, siehe [ADR 0001](../adr/0001-kopplung-per-yuvomi-schema.md). Für die App folgt daraus keine Arbeit.
- **Kamera über Bildschirmzeit gesperrt (`.restricted`):** Die App rät dann „in den Einstellungen erlauben“, obwohl der Schalter gesperrt ist. Nicht in B6 behoben, ein eigener kleiner Punkt für die App.

## Nachzuziehen in der Yuvomi-Doku

Der Wortlaut für `SPEC.md` steht in [01-position-texte.md](../drafts/01-position-texte.md) und geht mit S2 und S3 ins Repo: Definition von "API Tokens", Abschnitt zu signed-in devices, Spalten und Tabelle, Absatz zur Kontoentfernung.
