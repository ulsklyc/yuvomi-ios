# Phase 1, Slice 2: Kopplung per QR, App-Link und Code

Stand 03.11.2026, entschieden in einer Grilling-Runde (Q1 bis Q12) auf Basis von „S3: Kopplung“ und „Abweichungen beim Bau (S3)“ in [phase-0-server.md](phase-0-server.md). Server-Vertrag bleibt `v2.84.0` mit `client_api: 1`. Grundlage im Code ist der Stand nach Slice 1 ([phase-1-slice-1.md](phase-1-slice-1.md)).

**Ziel:** Ein Mitglied kommt ohne Passwort zu einem Device Credential. Es scannt den QR aus der Web-App, öffnet den Link `yuvomi://pair` auf demselben Gerät oder tippt den Code ab. Damit kommt auch ein SSO-only-Haushalt in die App.

**Nicht in diesem Slice:** der PWA-Abschnitt „Angemeldete Geräte“ (eigener PR im Server-Repo vor TestFlight), Universal Links, mehrere Konten, Schreiben von Aufgaben.

## Überblick

| # | Schritt | Hängt ab von |
|---|---|---|
| B1 | Kern: Link-Parser, `PairingFlow`, Port `PairingRedeeming` | - |
| B2 | Adapter: Einlösen ohne `Authorization` | B1 |
| B3 | `LoginModel`-Schritte, URL-Schema, `onOpenURL`, Hinweis bei bestehender Anmeldung | B1, B2 |
| B4 | Oberfläche: Code-Eingabe, Bestätigung, Scanner, Texte | B3 |
| B5 | Simulator- und iPhone-Lauf, CI grün | B4 |

---

## Fakten aus Server und Spec

- **Code:** 10 Zeichen aus `ACDEFGHJKMNPQRTUVWXY34679` (`generatePairingCode()` in `server/services/display-accounts.js`). Der Server vergleicht ohne Leerzeichen und Bindestriche in Großbuchstaben (`normalizePairingCode()`). Gültig 5 Minuten und einmal, ein neuer Code entwertet den alten. Abmelden und `invalidateUserSessions()` entwerten offene Codes ebenfalls.
- **Link:** `yuvomi://pair?server=<origin>&code=<code>`. `server` ist percent-kodiert und die blanke Origin der Web-App (`devicePairingLink()` in `server/services/device-pairing.js`). Der QR enthält genau diesen Link.
- **Einlösen:** `POST /api/v1/auth/devices/pair/redeem` (`redeemPairingCode`, schon im generierten Client). Rumpf `code`, `name`, `platform`, `device_id` wie bei `POST /devices`. Antwort 201 mit `SignedInDeviceCreateResponse`, also demselben Schema wie `auth-devices-create.json`.
- **Absagen:** 400 mit `reason: invalid_pairing_code` für unbekannt, abgelaufen, benutzt und für Konten, die kein Gerät mehr haben dürfen. Ein ungültiger Rumpf ergibt 400 ohne diesen Grund und verbraucht den Code nicht. 403 mit `reason: device_credential`, wenn ein gültiges Credential mitgeschickt wird. 429 bei zu vielen Versuchen.
- **Code erzeugen:** `POST /api/v1/auth/devices/pair` geht nur aus einer Browser-Sitzung mit CSRF und gehört nicht zur App-Spec. Solange der PWA-Abschnitt fehlt, kommen Codes für Tests per API (Login mit Cookie, dann `pair` mit `{ "server": "<origin>" }`).
- **Simulator:** Er hat keine Kamera, `DataScannerViewController.isSupported` ist dort `false`. Links öffnet `xcrun simctl openurl booted '<link>'`.
- **Kamera-App von iOS:** Sie erkennt `yuvomi://`-QR-Codes und öffnet die App über den Link. Ein Scan außerhalb der App landet also im selben Weg wie ein Link.

## Entscheidungen

### Wege in die Kopplung (Q1, Q5)

- **Scanner in der App:** `DataScannerViewController` aus VisionKit, nur für QR, hinter einem kleinen Protokoll in `LoginFeature`. Der Button erscheint nur, wenn `isSupported && isAvailable`. Daneben funktioniert die Kamera-App von iOS über den Link-Weg ohne eigenen Code. `NSCameraUsageDescription` kommt auf Deutsch und Englisch dazu.
- **Einstiege:**
  - Auf dem Adress-Screen gibt es „QR-Code scannen“. Der QR bringt den Server mit, die Adresse muss vorher nicht eingetippt sein.
  - Nach der Serverprüfung bietet der Passwort-Schritt „Stattdessen mit Code anmelden“ an.
  - Ein SSO-only-Server (`.pairingOnly` aus `ServerCheck`) zeigt statt des bisherigen Hinweises direkt die Code-Eingabe mit Scan-Button und dem Hinweis, wo man in der Web-App den Code erzeugt.
- **Link-Art (Q4):** In diesem Slice gilt `yuvomi://` mit Bestätigung des Servers. Ob derselbe Weg später ein Universal Link wird, bleibt unter „Vor TestFlight“ in [phase-0-server.md](phase-0-server.md) offen. Selbst gehostete Domains bräuchten dafür je eine `apple-app-site-association`.

### Modell (Q2)

- **`LoginModel` wird erweitert**, kein eigenes Screen-Modell. Neue Schritte:
  - `.pairing(server:appName:)`: Code eingeben oder scannen, für einen geprüften Server.
  - `.confirmPairing(server:appName:code:)`: Server bestätigen, nur bei Link und QR.
- **Kern:** `PairingFlow` mit dem Port `PairingRedeeming`. Er löst ein und speichert das Credential im Keychain wie `SignInFlow`, danach übernimmt `onSignedIn`. Fehler kommen als eigener Typ (`invalidCode`, `notAllowed`, `rateLimited`, `unreachable`, `unexpectedResponse`, `credentialNotStored`). `LoginModel.Problem` bekommt dafür `invalidPairingCode`.
- **Link-Parser im Kern:** `PairingLink(url:)` nimmt nur `yuvomi://pair` mit genau einem `server` und einem `code` an. `server` läuft durch dieselbe Adressregel wie die Eingabe (`ServerAddress`). Ein Pfad, ein fehlender oder leerer Code und ein anderes Schema als http(s) machen den Link ungültig. Den Code prüft die App nur auf „nicht leer nach Normalisierung“. Länge und Alphabet entscheidet der Server, damit eine Änderung dort die App nicht bricht.
- **Normalisierung:** Die App schickt den Code ohne Leerzeichen und Bindestriche in Großbuchstaben, wie der Server vergleicht. Die Anzeige im Eingabefeld darf gruppieren.

### Bestätigung des Servers (Q6)

- **Bei Link und QR:** Zuerst läuft `ServerCheck` für den Server aus dem Link. Erst ein bereiter Yuvomi-Server führt zu `.confirmPairing`. Zu alt, kein Yuvomi oder nicht erreichbar ergeben dieselben Meldungen wie bei der Adresseingabe.
- **Der Schritt zeigt** den App-Namen des Servers, den Host groß und das Schema sichtbar. http ist ausdrücklich als unverschlüsselt markiert. Dazu „Anmelden“ und „Abbrechen“. Abbrechen führt zur Adresse, das Feld ist mit dem Server aus dem Link vorbefüllt.
- **Beim abgetippten Code** gibt es keine Bestätigung, die Adresse hat die Person selbst eingegeben.

### Links zur falschen Zeit (Q3, Q8)

- **Schon angemeldet:** Die App zeigt einen Hinweis, dass bereits ein Konto angemeldet ist und man zum Koppeln erst abmelden muss. Sonst passiert nichts. Der Code verfällt nach 5 Minuten. Entschieden wird das in `AppModel`, bevor ein `LoginModel` den Link sieht.
- **Mitten in einer Anmeldung:** Der Link gewinnt. Der laufende Ablauf wird mit seinem Gateway und dessen Cookie-Sitzung verworfen, es folgt Serverprüfung und Bestätigung für den Link. Läuft gerade eine Anfrage (`isWorking`), wird der Link gemerkt und danach angenommen. Es gewinnt der zuletzt eingetroffene.
- **Ungültiger Link:** Er bekommt eine eigene Meldung („Dieser Link ist kein gültiger Kopplungslink“) auf dem Adress-Schritt.

### Absagen (Q9)

- Bei `invalid_pairing_code` steht die App in `.pairing` für denselben Server, egal ob der Code aus Link, QR oder Eingabe kam. Das Feld ist leer, darunter steht: „Code ungültig oder abgelaufen. Erzeuge in der Web-App einen neuen.“ Von dort geht ein neuer Scan oder das Abtippen.
- 429 und Netzfehler lassen den Code im Feld stehen, damit ein zweiter Versuch ohne neuen Code geht.
- Ein 400 ohne `reason` gilt als unerwartete Antwort und nicht als falscher Code.

### Einlösen ohne Credential

- Der Adapter `YuvomiPairingRedeemer` baut seinen Client ohne Middleware für `Authorization`. Ein Test prüft am Transport, dass die Anfrage keinen solchen Header trägt (Server antwortet sonst 403).
- Gerätedaten wie in A4: Name „iPhone“, `device_id` aus `identifierForVendor`, `platform: "ios"`. Dieselbe `device_id` ersetzt ein früheres Credential dieses Geräts.
- Cookies fallen beim Einlösen nicht an. Der Adapter nutzt trotzdem eine eigene `URLSession(configuration: .ephemeral)`, damit `HTTPCookieStorage.shared` leer bleibt.

### Tests (Q10)

- **TDD** für `PairingLink`, `PairingFlow` und die neuen Schritte in `LoginModel`, jeweils mit Fakes für die Ports.
- **Adapter** über den Fixture-Transport: Erfolg mit der vorhandenen `auth-devices-create.json`. Absagen (`invalid_pairing_code`, 400 ohne Grund, 403, 429) spielt ein Transport mit Fehlern ein, wie in A4. Am Server-Repo ändert sich nichts.
- **Scanner:** Die Erkennung bleibt hinter dem Protokoll. Getestet wird, was `LoginModel` mit einem gescannten String macht. Die VisionKit-Hülle selbst prüft nur der Lauf auf dem Gerät.
- Vorschauen für `.pairing` und `.confirmPairing` über Fixtures.

---

## B1 bis B5 im Einzelnen

**B1, Kern:**
- `PairingLink(url:)` mit Normalisierung von Server und Code.
- Port `PairingRedeeming`, `PairingFlow` mit Keychain-Speichern, Fehlertyp.
- Alles per TDD mit Fakes.
- Fertig, wenn die Tests für gültige, ungültige und Grenzfälle des Links sowie für jeden Fehler des Flows grün sind.

**B2, Adapter:**
- `YuvomiPairingRedeemer` über den generierten `redeemPairingCode`, ohne `Authorization`, mit eigener ephemerer Sitzung.
- Fehler nach Status und `reason` einordnen.
- Fertig, wenn Erfolg und alle Absagen über Fixture- und Fehler-Transport getestet sind und der Header-Test grün ist.

**B3, Ablauf:**
- `LoginModel`: Schritte `.pairing` und `.confirmPairing`, `openPairingLink(_:)`, `submitPairingCode()`, `confirmPairing()`, Problem `invalidPairingCode` und `invalidPairingLink`, Verhalten bei laufender Anfrage.
- `.pairingOnly` führt zu `.pairing` statt `.ssoOnly`. `.ssoOnly` entfällt, wenn nichts anderes mehr darauf zeigt.
- `project.yml`: `CFBundleURLTypes` mit Schema `yuvomi`.
- `YuvomiApp`: `.onOpenURL` auf der `WindowGroup`, `AppModel` leitet weiter oder zeigt den Hinweis bei bestehender Anmeldung.
- Per TDD für das Modell, die App-Verdrahtung prüft der Simulator-Lauf.

**B4, Oberfläche:**
- Code-Eingabe mit Gruppierung, Bestätigungsschritt, „QR-Code scannen“ auf Adresse und Code-Schritt, „Stattdessen mit Code anmelden“ im Passwort-Schritt.
- `DataScannerViewController` in einer `UIViewControllerRepresentable`-Hülle, Button nur bei Unterstützung.
- `NSCameraUsageDescription` auf Deutsch und Englisch (String Catalog für `Info.plist`), alle neuen Texte in den String Catalog von `LoginFeature`.
- Vorschauen für die neuen Schritte.

**B5, Abschluss:**
- Simulator gegen den lokalen Server `v2.84.0` mit Demo-Seed. Code per API erzeugen, dann:
  1. Link per `simctl openurl`: Bestätigung, Anmelden, Liste.
  2. Abmelden, Code abtippen: Liste.
  3. Abgelaufener oder benutzter Code: Code-Schritt mit Meldung.
  4. Link bei bestehender Anmeldung: Hinweis, Sitzung bleibt.
  5. Link mitten im 2FA-Schritt: Bestätigung für den Link.
- Server-Zustand jeweils in `api_tokens` prüfen (`kind = device`, `platform = ios`, keine Cookie-Sitzung).
- Auf dem iPhone des Users, signiert mit Team `8C2HRWK28S`, gegen den Server im LAN (`NSAllowsLocalNetworking` deckt die IP ab, der Server muss dafür nicht nur auf `127.0.0.1` lauschen): Scan in der App, Scan mit der Kamera-App, Link.
- Nebenbei nachholen, falls es sich ergibt: Pull-to-refresh nach Widerruf (offen aus A6).
- CI grün.

## Fertig, wenn

- [ ] Ein Mitglied koppelt im Simulator per Link und per abgetipptem Code und sieht seine Aufgaben.
- [ ] Auf einem iPhone gelingt die Kopplung per Scan in der App und per Kamera-App.
- [ ] Vor dem Einlösen eines Links oder QR zeigt die App den Server und wartet auf die Bestätigung.
- [ ] Ein ungültiger, abgelaufener oder benutzter Code führt zur Code-Eingabe mit klarer Meldung.
- [ ] Ein Link bei bestehender Anmeldung ändert nichts an der Sitzung.
- [ ] Die Anfrage zum Einlösen trägt nie einen `Authorization`-Header.
- [ ] Ein SSO-only-Server führt direkt zur Code-Eingabe statt zum Hinweis.
- [ ] Alle neuen Texte liegen auf Deutsch und Englisch im String Catalog, CI ist grün.
