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

## Abweichungen beim Bau (B1)

- **Seams**, vor dem ersten Test abgestimmt:
  1. `PairingLink(url:)` im Kern.
  2. `PairingFlow.redeem(code:)` mit Fakes für `PairingRedeeming` und den Keychain.
- **Kein eigener Fehlertyp:** `PairingFlow` wirft `SignInError`, der dafür den Fall `invalidPairingCode` bekommt. Die übrigen Fälle (`notAllowed`, `rateLimited`, `unreachable`, `unexpectedResponse`, `credentialNotStored`) gibt es dort schon, und `LoginModel.Problem` übersetzt so nur einen Typ. Bis B3 bildet `LoginModel` den neuen Fall auf `.invalidCode` ab, erreichbar ist er dort noch nicht.
- **Link-Regeln:** Schema `yuvomi` und Host `pair`, beides ohne Rücksicht auf Groß- und Kleinschreibung. `server` und `code` müssen genau einmal vorkommen. `server` läuft durch `ServerAddress` und darf danach keinen Pfad haben. Der Code ist nach `PairingCode.normalize` nicht leer.
- **Normalisiert wird im Kern:** `PairingFlow` schickt den Code immer normalisiert an den Port. So gilt das auch für den abgetippten Code, nicht nur für Links.

## Abweichungen beim Bau (B2)

- **Seam**, vor dem ersten Test abgestimmt: `YuvomiPairingRedeemer.redeem(code:)` über den Fixture-Transport mit Recorder.
- **Fixture:** `FixtureTransport.defaults` ordnet `redeemPairingCode` der Datei `auth-devices-create.json` zu, mit Status 201.
- **Einordnung:** Ein 400 zählt nur mit `reason: invalid_pairing_code` als `.invalidPairingCode`, sonst als `.unexpectedResponse`. Auch bei einem 400 mit HTML-Body: Der Grund lässt sich dann nicht lesen. 403 (auch `device_credential`) wird `.notAllowed`, 429 `.rateLimited`. Ohne Antwort ist der Server nicht erreichbar. Die Regeln nach Status teilt sich der Adapter mit `YuvomiSignInGateway` über den neuen Schritt `.pairing`.
- **Kein `actor`:** Anders als der Gateway hält der Adapter keinen Zustand zwischen Anfragen, er ist ein `struct`. Den flüchtigen Transport nimmt er von `YuvomiSignInGateway.ephemeralTransport()`.

## Abweichungen beim Bau (B3)

- **Seams**, vor dem ersten Test abgestimmt:
  1. `LoginModel` mit Fakes für Probe, Gateway und Redeemer.
  2. `IncomingLink(url:current:)` im Kern. Die Sperre bei bestehender Anmeldung ist damit durch einen Test gesichert und hängt nicht nur am Simulator-Lauf.
- **API am Modell:** `openPairingLink(_:)`, `confirmPairing()`, `startPairing()`, `submitPairingCode()` und `canSubmitPairingCode`, dazu ein eigenes Feld `pairingCode`. Der Scanner aus B4 ruft ebenfalls `openPairingLink(_:)` auf.
- **`.ssoOnly` entfällt.** Bis B4 zeigt `LoginView` für `.pairing` und `.confirmPairing` noch den alten Hinweis.
- **Link öffnen:** Der Server aus dem Link steht danach im Adressfeld. So bezieht sich eine Meldung wie „zu alt“ sichtbar auf diesen Server, und „Abbrechen“ in der Bestätigung führt zur Adresse mit dem Server darin.
- **Absage in der Bestätigung:** Bei `invalid_pairing_code` geht es zur Code-Eingabe (Q9). Andere Fehler wie 429 oder Netzfehler lassen die Bestätigung stehen, damit ein zweiter Versuch ohne neuen Link geht.
- **Link während einer Anfrage:** Er wird gemerkt und nach der Antwort angenommen, der letzte gewinnt. Hat die Antwort schon angemeldet, verfällt er (Q3). Vorher startete ein solcher Link eine eigene Prüfung, und `isWorking` fiel zu früh auf `false`.
- **Nach dem Codex-Review zu PR #11:** Ein angenommener Link leert Benutzername, Passwort, 2FA-Code und Kopplungscode, auch wenn er ungültig ist oder die Serverprüfung scheitert. Sonst gingen Zugangsdaten für Server A nach einer erneuten Prüfung an Server B aus dem Link.
- **Offener 2FA-Versuch:** Ein Link verwirft ihn samt Cookie-Sitzung (`pendingFlow = nil`). Von außen ist das nicht zu beobachten, deshalb gibt es dafür keinen eigenen Test. Der Test zu Q8 prüft nur die Schrittfolge.
- **Texte vorgezogen:** `login.problem.invalidPairingCode` und `login.problem.invalidPairingLink` kamen schon mit B3 in den Katalog, weil die View jedes Problem übersetzt. Die App hat für den Hinweis bei bestehender Anmeldung einen eigenen String Catalog `App/Localizable.xcstrings`.

## Abweichungen beim Bau (B4)

- **Seams**, vor dem ersten Test abgestimmt:
  1. `LoginModel.openScannedCode(_:) -> Bool`: Ein gültiger Kopplungslink läuft wie `openPairingLink(_:)`, alles andere gibt `false` und lässt das Modell unverändert.
  2. `PairingCode.grouped(_:)` im Kern: Fünfergruppen mit Leerzeichen, etwa `ACDEF GHJK3`. Abgeschnitten wird nichts, die Länge entscheidet der Server.
- **Fremder QR:** Der Scanner bleibt offen und zeigt „Das ist kein Kopplungscode von Yuvomi.“, VoiceOver sagt es an. Ein Kopplungslink schließt das Blatt, sobald der Server geprüft ist.
- **Gruppierung im Modell:** Ein umformendes `Binding` übernimmt das Textfeld während der Eingabe nicht, im Simulator blieb `acde-fghjk3` stehen. Deshalb schreibt `onChange` die gruppierte Form nach `pairingCode` zurück. Eingelöst wird weiterhin normalisiert (B1).
- **Scanner-Protokoll:** `QRCodeScanner` in `LoginFeature` mit `isAvailable` und `makeView(onCode:)`. `LoginView` nimmt ihn als Parameter, Standard ist `VisionKitScanner`, die Vorschauen bekommen einen Platzhalter mit `isAvailable == true`. So zeigen die Vorschauen den Scan-Button, den der Simulator mangels Kamera nicht zeigt.
- **Kamerafreigabe:** `DataScannerViewController.isAvailable` ist erst nach der Freigabe der Kamera `true`. Der Button erscheint deshalb auch, solange iOS noch nicht gefragt hat. Die Hülle fragt vor `startScanning()` mit `AVCaptureDevice.requestAccess`. Nach einer Ablehnung fehlt der Button. Geprüft wird das erst in B5 auf dem iPhone.
- **Info.plist:** `NSCameraUsageDescription` steht englisch in `project.yml`, die deutsche Fassung in `App/InfoPlist.xcstrings`. Im gebauten Bundle liegt sie unter `de.lproj/InfoPlist.strings`.
- **Bestätigung:** Sie hat ihr eigenes „Abbrechen“ neben „Anmelden“, das „Zurück“ in der Leiste entfällt dort. Orange trägt nur das offene Schloss, der Text bleibt in Primär- und Sekundärfarbe, weil Orange auf Weiß unter 4,5:1 liegt.
- **Reihenfolge in der Bestätigung**, nach dem Sicherheitsreview des Commits: Zuerst steht der Host groß, darunter der App-Name klein, einzeilig und ohne Steuerzeichen. Den App-Namen liefert der Server, den man gerade bestätigt. Mit einem Zeilenumbruch könnte er sonst über dem echten Host eine falsche Adresse zeigen.
- **Nach dem Codex-Review zu PR #13:** Während der Serverprüfung für einen gescannten Link lässt sich das Scanner-Blatt nicht schließen, weder mit „Abbrechen“ noch per Wisch. Sonst liefe die Prüfung weiter und wechselte danach trotzdem den Schritt.
- **Hinweis zur Web-App:** Der Text nennt „Einstellungen > Konto > Angemeldete Geräte“. Diesen Abschnitt bringt erst der PWA-PR vor TestFlight (siehe [phase-0-server.md](phase-0-server.md)). Ändert sich dort der Name, muss der Text mit.
- **Englische Buttons** in Title Case wie das vorhandene „Sign In“: „Scan QR Code“, „Sign In with a Code Instead“.
- **Sichtprüfung im Simulator** gegen einen lokalen Server `v2.84.0` (Demo-Seed `de`, Port 3901), auf Deutsch und Englisch: Link mit http, Bestätigung, abgelehnter Code mit Meldung in der Code-Eingabe, „Abbrechen“ zur Adresse, Passwort-Schritt mit „Stattdessen mit Code anmelden“, eingefügter Code gruppiert. Dazu die Bestätigung bei Dynamic Type `accessibility-extra-large`, nichts abgeschnitten. Die Bestätigung mit https und der Scan-Button sind nur in den Vorschauen zu sehen.

## Abweichungen beim Bau (B5)

- **Kamera in der ersten Frage abgelehnt:** Bisher fragte die VisionKit-Hülle selbst und startete danach `startScanning()` mit `try?`. Nach „Nicht erlauben“ blieb das Blatt schwarz, oben stand VisionKits „Verlangsamen.“ und unten weiter „Richte die Kamera auf den QR-Code …“. Jetzt hat `QRCodeScanner` dafür `requestAccess() async -> Bool`. `ScannerSheet` fragt per `.task` und zeigt bei `false` eine `ContentUnavailableView` „Kein Zugriff auf die Kamera“ mit „Einstellungen öffnen“ und dem Hinweis auf den Code. Ohne Logik im Modell, deshalb ohne Unit-Test (A5): geprüft per neuer Vorschau „Scanner, Kamera abgelehnt“ und am iPhone. Abgestimmt nach der Audit-Runde.
- **Code per Skript:** `POST /auth/logout` entwertet offene Kopplungscodes (`server/auth.js`, gegen den offenen Code am geteilten Rechner). Das Hilfsskript für den Lauf darf die Browser-Sitzung nach dem Erzeugen deshalb nicht abmelden. Der erste Versuch scheiterte genau daran, die Meldung der App war richtig.

## Lauf (B5, 03.11.2026)

Server `v2.84.0` aus dem Haupt-Checkout, Demo-Seed `de`, Port 3901. Codes per `POST /api/v1/auth/devices/pair` aus einer Browser-Sitzung. Nach jedem Fall `api_tokens` und `sessions` abgefragt.

**Simulator** (iPhone 17, Deutsch, hell), Server auf `127.0.0.1`:

| Fall | Ergebnis | `api_tokens` |
|---|---|---|
| 1. Link per `simctl openurl` (emma) | Bestätigung mit `http://localhost:3901` und Warnung, Anmelden, Aufgabenliste | neu: emma, `kind = device`, `platform = ios` |
| 2. Abmelden, Code abtippen (leo) | über „Stattdessen mit Code anmelden“, getippt als `VGP9G 9WMWE`, Liste | emma widerrufen (Abmelden), neu: leo, `device`/`ios` |
| 3. Benutzter Code | Code-Schritt mit „Code ungültig oder abgelaufen. Erzeuge in der Web-App einen neuen.“ | kein neues Token |
| 4. Link bei bestehender Anmeldung (leo-Code, angemeldet als emma) | Hinweis „Bereits angemeldet“, Liste bleibt | unverändert, leos Code bleibt offen |
| 5. Link im 2FA-Schritt (emma mit 2FA, Link für leo) | Bestätigung statt 2FA-Schritt, dann Liste | neu: leo, `device`/`ios` |

- **Sitzungen:** In `sessions` liegt nach keinem Fall eine angemeldete Sitzung der App, nur die des Skripts. Aus Fall 5 bleibt die Sitzung des Passwort-Schritts mit `pendingTwoFactor` liegen, ohne `userId`. Sie gibt keinen Zugang und verfällt nach fünf Minuten (B3: `pendingFlow = nil`).
- **Pull-to-refresh nach Widerruf** (offen aus A6): leos Token in der Datenbank widerrufen, dann gewischt. Die App fällt zum Login zurück. Mit `swipe` über 1,5 Sekunden kam der Wisch an, ein schneller `touch_path` nicht.
- **Eingabe im Simulator:** Die `text`-Aktion kam wie in B4 nicht an. Getippt wurde über die Bildschirmtastatur, nach `set_keyboard show`. Schnelle Tipps direkt nach einem Wechsel der Tastaturebene gingen verloren, mit Pausen kam alles an. Das ist der Simulator, nicht die Gruppierung.

**iPhone** (iPhone18,4, Dunkelmodus, signiert mit Team `8C2HRWK28S`), Server auf der LAN-Adresse des Macs:

| Weg | Ergebnis | `api_tokens` |
|---|---|---|
| Scan in der App (linda) | Button schon vor der ersten Kamerafrage, Frage mit deutschem Text, Freigabe, fremder QR zeigt den Hinweis und VoiceOver sagt ihn an, Kopplungs-QR führt zur Bestätigung, Liste | neu: linda, `device`/`ios`, eigene `device_id` |
| Kamera-App (alex), App vorher beendet | Banner „In Yuvomi öffnen“, Kaltstart direkt in die Bestätigung, Liste | neu: alex, `device`/`ios` |
| Link aus Safari (linda) | „Diese Seite in ‚Yuvomi‘ öffnen?“, Bestätigung, Liste | neu: linda, `device`/`ios` |
| Kamera in den Einstellungen aus | „QR-Code scannen“ fehlt im Adress- und im Code-Schritt | – |
| Erste Frage abgelehnt (App neu installiert) | vorher schwarzes Blatt, nach der Korrektur „Kein Zugriff auf die Kamera“ mit „Einstellungen öffnen“, das zur Yuvomi-Seite führt; danach scannt die Kamera wieder | – |

- **Audit** (impeccable, nativ): Texte über Textstile, Farben semantisch, Orange nur am Schloss, Bestätigung als Element zusammengefasst. Gefunden und behoben nur die abgelehnte erste Frage. Die Bestätigung hell und mit großer Schrift kommt aus dem Simulator (hier und B4), dunkel vom iPhone.

## Fertig, wenn

- [x] Ein Mitglied koppelt im Simulator per Link und per abgetipptem Code und sieht seine Aufgaben (Lauf B5, Fälle 1 und 2).
- [x] Auf einem iPhone gelingt die Kopplung per Scan in der App und per Kamera-App (Lauf B5, dazu der Link aus Safari).
- [x] Vor dem Einlösen eines Links oder QR zeigt die App den Server und wartet auf die Bestätigung (Simulator und iPhone, alle drei Wege).
- [x] Ein ungültiger, abgelaufener oder benutzter Code führt zur Code-Eingabe mit klarer Meldung. Live gesehen: benutzt. Der Server antwortet für alle drei gleich (`invalid_pairing_code`), das prüfen die Tests aus B2 und B3.
- [x] Ein Link bei bestehender Anmeldung ändert nichts an der Sitzung (Lauf B5, Fall 4, und `IncomingLink`-Tests aus B3).
- [x] Die Anfrage zum Einlösen trägt nie einen `Authorization`-Header (`PairingRedeemerTests.redeemsTheCodeWithoutAuthorization`, B2).
- [x] Ein SSO-only-Server führt direkt zur Code-Eingabe statt zum Hinweis (`LoginModelTests.serverWithoutPasswordLoginAsksForAPairingCode`). Live nicht gesehen: Der Demo-Seed hat kein OIDC. In B6 lief ein Server ohne Passwort-Login, belegt ist dort der App-Link (phase-0-server.md, B6); der direkte Sprung zur Code-Eingabe blieb ungesehen.
- [x] Alle neuen Texte liegen auf Deutsch und Englisch im String Catalog, CI ist grün.
