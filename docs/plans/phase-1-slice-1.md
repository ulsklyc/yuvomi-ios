# Phase 1, Slice 1: Anmelden und Aufgaben lesen

Stand 02.11.2026, entschieden in einer Grilling-Runde (Q1 bis Q20) auf Basis von [phase-0-server.md](phase-0-server.md). Server-Vertrag ist `v2.84.0` mit `client_api: 1`. Im Repo liegt noch kein Swift-Code.

**Ziel:** Eine App, die sich mit einem Yuvomi-Server verbindet, per Passwort und 2FA ein Device Credential holt, die Aufgaben liest und sich wieder abmeldet. Mit diesem Slice wird `yuvomi-ios` öffentlich.

**Nicht in diesem Slice:** Kopplung per QR, App-Link oder Code (Slice 2), Schreiben von Aufgaben, Einkauf, Kalender, Erinnerungen, mehrere Konten.

## Überblick

| # | Schritt | Hängt ab von |
|---|---|---|
| A1 | Gerüst: Paket, XcodeGen, CI | - |
| A2 | API-Modul: Spec, Generator, Fixture-Transport | A1 |
| A3 | Core: Domain-Modelle, Fassade, Keychain, Versionsprüfung | A2 |
| A4 | Anmeldeablauf und Abmelden | A3 |
| A5 | Oberfläche: Login, Aufgabenliste, Texte | A3, A4 |
| A6 | Simulator-Lauf, CI grün, Repo öffentlich | A5 |

---

## Entscheidungen

### Projektaufbau

- **XcodeGen:** `project.yml` ist eingecheckt, die `.xcodeproj` wird erzeugt und steht in `.gitignore`. XcodeGen ist lokal installiert und wird in der CI per Homebrew geholt.
- **SPM-Paket im Repo-Wurzelverzeichnis:** `Package.swift` liegt oben, damit `Fixtures/` als Ressourcen-Target eingebunden werden kann. SPM erlaubt Ressourcen nur innerhalb des Paketordners. `Package.resolved` ist eingecheckt.
- **Module.** Der Kern kennt weder Generator noch Runtime. `YuvomiAPI` setzt die Protokolle des Kerns mit dem generierten Client um, die App verbindet beides (seit A2, siehe dort):

| Modul | Inhalt | Darf benutzen |
|---|---|---|
| `YuvomiCore` | Domain-Modelle, Protokolle für den Serverzugriff, Session, Keychain, Versionsprüfung | - |
| `YuvomiAPI` | generierter Code, fünf `typeOverrides`, Umsetzung der Kern-Protokolle | `YuvomiCore`, OpenAPI Runtime, URLSession-Transport |
| `DesignSystem` | Farben, Abstände, wiederkehrende Views | - |
| `LoginFeature` | Serveradresse, Passwort, 2FA, SSO-Hinweis | `YuvomiCore`, `DesignSystem` |
| `TasksFeature` | Aufgabenliste, nur lesend | `YuvomiCore`, `DesignSystem` |
| `YuvomiFixtures` | JSON aus `Fixtures/demo`, Fixture-Transport | OpenAPI Runtime, HTTP Types |

  Das App-Target unter `App/` ist nur der Einstieg: Es baut die Abhängigkeiten zusammen und wählt den Screen. Später sollen Widgets und Erweiterungen über `group.cloud.yuvomi` dazukommen. Sie binden dann `YuvomiCore` ein und brauchen die Oberfläche nicht.
- **Fassade:** Die generierten Typen bleiben `internal` in `YuvomiAPI`. Nach außen gehen nur eigene Modelle hinter einem Protokoll. Grund sind die Macken aus S5: Bei `oneOf` mit `null` verschwinden 11 Eigenschaften still, und `CalendarDateOrDateTime` prüft kein Muster. Repariert wird an einer Stelle, und keine View hängt am Generator.
- **Sprache und Zustand:** Swift 6 mit strikter Prüfung der Nebenläufigkeit. Der Zustand liegt in `@Observable`-Klassen pro Screen. Es gibt keine Drittanbieter-Architektur.
- **Ziel:** iOS 27, Bundle-ID `cloud.yuvomi.ios`, Team `8C2HRWK28S`. Für den Simulator ist keine Signierung nötig. Bis 02.11.2026 galt iOS 26, siehe „Abweichungen beim Bau (A1)“.

### Generator

- **Ablauf per Skript, Code eingecheckt:** `scripts/generate-api.sh` ruft den Swift OpenAPI Generator 1.14.3 aus dem Werkzeug-Paket `Tools/` auf, mit der Runtime 1.13.3 aus dem Spike. Das Skript bricht bei jeder Generator-Warnung ab. Die Warnung zu `oneOf` mit `null` ist genau die, die im Spike Eigenschaften verschwinden ließ. Der erzeugte Code liegt unter `Sources/YuvomiAPI/Generated/`.
- **Konfiguration** in `Sources/YuvomiAPI/openapi-generator-config.yaml`: `namingStrategy: idiomatic`, `accessModifier: internal`, `typeOverrides` für die fünf Eingaben mit `unset`/`clear`/`set`. Die handgeschriebenen Typen liegen in `Sources/YuvomiAPI/Overrides/`.
- **Spec:** Eine gepinnte Kopie liegt in `Spec/openapi.json`, der Server-Tag steht in `info.version`. Neu kommt sie nur über ein Skript mit ausdrücklichem Tag, zum Beispiel `scripts/update-spec.sh v2.84.0`. So ist jede Spec-Änderung ein eigener Commit. Das Skript kürzt die Spec auf die 39 Operationen und alles, was sie über `$ref` erreichen (`scripts/prune-spec.mjs`).
- **CI-Check:** Die CI erzeugt den Code neu und bricht ab, wenn er vom eingecheckten Stand abweicht. Dasselbe gilt bei einer Warnung.

### Anmeldung und Server

- **Versionsprüfung:** `GET /version` geht immer ohne `Authorization`, denn ein ungültiges Credential ergäbe dort 401 (Falle aus S1). Angenommen wird nur ein Server, der `product == "yuvomi"` meldet und `client_api >= 1`. Höhere Werte gelten auch. Fehlt das Feld, ist der Server zu alt. Jeder Fall bekommt vor der Passworteingabe eine eigene, klare Meldung.
- **Folge für den Server:** Steigt `client_api`, muss der Server den alten Vertrag weiter bedienen. Ein echter Bruch käme über ein zusätzliches Feld wie `client_api_min`. Das gehört in die Server-Doku, siehe unten.
- **SSO-only:** Meldet `GET /auth/oidc/config`, dass der Passwort-Login abgeschaltet ist, zeigt die App einen Hinweis: Die Kopplung über die Web-App folgt. Ein Passwortformular, das sicher scheitert, gibt es dann nicht.
- **Ablauf wie in S2:**
  1. `POST /auth/login`, bei 2FA zusätzlich `POST /auth/2fa/verify`.
  2. `POST /auth/devices` mit dem `csrfToken` aus der Login-Antwort.
  3. `POST /auth/logout`.
  4. Die App verwirft alle Cookies und arbeitet danach nur noch mit Bearer.
- **Keychain:** Das Credential wird mit `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` gespeichert, in einer geteilten Access Group. Damit ist es nach dem ersten Entsperren auch im Hintergrund lesbar und wandert nie per iCloud oder Backup auf ein anderes Gerät. Der Eintrag ist an die Server-URL gebunden, damit später mehrere Konten ohne Migration möglich sind.
- **Ein Server, ein Konto:** Gewechselt wird nur über Abmelden.
- **Abmelden:** `DELETE /auth/devices/current`, danach wird der Keychain-Eintrag gelöscht. Jede 401-Antwort, etwa nach einem Widerruf durch Passwortwechsel, löscht den Eintrag ebenfalls und führt zurück zum Login.
- **ATS:** Nur HTTPS, außer im lokalen Netz über `NSAllowsLocalNetworking`. Das deckt `localhost`, IPs im LAN und `.local` ab.

### Aufgabenliste

- `GET /tasks`, nur lesend und live vom Server. Das Domain-Modell trägt nur, was die Liste anzeigt.
- Datumswerte parst die Fassade selbst, nicht der generierte Decoder (S5: `date-time` und `date` getrennt behandeln).

### Tests und Vorschau

- **Swift Testing** (`@Test`, `#expect`), ein Test-Target pro Modul. Ausgeführt wird per `xcodebuild test` im iOS-27-Simulator, lokal wie in der CI.
- **Keychain** steckt hinter einem Protokoll. Unit-Tests nutzen einen Fake im Speicher. Ein einzelner Integrationstest prüft den echten Keychain im Simulator.
- **Fixture-Transport:** Ein eigener `ClientTransport` liefert die JSON-Dateien aus `Fixtures/demo` aus. Vorschauen und Tests laufen dadurch durch den generierten Decoder und die Fassade. Ein Test dekodiert alle 21 Fixtures.
- **TDD** für die Versionsprüfung, den Anmeldeablauf und den Umgang mit 401.
- **Entwicklungsserver:** lokal `v2.84.0` mit Demo-Seed, wie im [Fixtures-README](../../Fixtures/README.md) beschrieben (`127.0.0.1:3917`). Die Review-Instanz bleibt Apple und TestFlight vorbehalten.

### Texte und CI

- Von Anfang an ein String Catalog, zuerst Deutsch und Englisch. Im Code stehen keine harten Strings. Weitere der 27 PWA-Sprachen kommen später.
- **GitHub Actions** auf einem macOS-Runner. Die Xcode-Version ist im Workflow gepinnt. Schritte: XcodeGen, Generator-Check, Build, Tests im Simulator.

### Repo-Sichtbarkeit

- Das Repo wird nach A6 öffentlich, samt `docs/drafts/`, `docs/plans/` und unveränderter Historie. Geprüft: Es gibt keine IP und keine Zugangsdaten, nur das Demo-Passwort aus dem Seed.
- Die Sichtbarkeit schaltet der User selbst um.

---

## A1 bis A6 im Einzelnen

**A1, Gerüst:**
- `Package.swift` mit den sechs Modulen, noch fast leer.
- `project.yml` mit App-Target, iOS 27 und ATS-Eintrag.
- `App/` mit Einstieg und App-Icon aus `design/app-icon/`.
- `.gitignore` und der erste CI-Workflow.
- Fertig, wenn ein leerer Test im Simulator grün ist, lokal und in der CI.

**A2, API-Modul:**
- Spec-Kopie, `generate-api.sh` und `update-spec.sh`.
- Generator-Konfiguration und die fünf Overrides.
- `YuvomiFixtures` mit Fixture-Transport.
- Fertig, wenn alle 21 Fixtures dekodieren und der CI-Check Abweichungen und Warnungen erkennt. Gegenprobe: Eine absichtlich eingebaute Warnung muss den Lauf rot machen.

**A3, Core:**
- Domain-Modelle: Serverinfo, Session, Aufgabe.
- Fassaden-Protokoll mit Implementierung über `YuvomiAPI`.
- Keychain-Protokoll mit echter Implementierung und Fake.
- Versionsprüfung, alles per TDD.

**A4, Anmeldeablauf:**
- Serveradresse prüfen.
- SSO-Erkennung.
- Login, 2FA, Credential holen, Cookies verwerfen.
- 401-Behandlung und Abmelden.
- Getestet über den Fixture-Transport und einen Transport, der Fehler einspielt.

**A5, Oberfläche:**
- `LoginFeature`: Adresse, Passwort, 2FA, Hinweis bei SSO-only, Fehlermeldungen.
- `TasksFeature`: Liste mit Laden, Leerzustand und Fehlerzustand.
- `DesignSystem` in der Größe, die diese Screens brauchen.
- String Catalog in Deutsch und Englisch. Vorschauen laufen über Fixtures.

**A6, Abschluss:**
- Im Simulator gegen den lokalen Server: anmelden, Liste sehen, abmelden, erneut anmelden.
- CI grün.
- Danach schaltet der User das Repo öffentlich.

## Abweichungen beim Bau (A1)

- **iOS 27 statt iOS 26 als Minimum**, entschieden am 02.11.2026. iOS 27 ist seit dem Herbst draußen, und bis zur ersten öffentlichen Version wird der Großteil der Geräte damit laufen. Wer nicht aktualisieren kann, nutzt die PWA, wie schon bei der Grenze iOS 26. Dazu kommt ein praktischer Grund: Installiert ist nur die iOS-27-Laufzeit. Mit iOS 26 als Minimum hätte die App eine Untergrenze, auf der sie nie getestet wird. Neue SwiftUI-APIs stehen ohne `if #available` zur Verfügung. Dafür braucht `Package.swift` `swift-tools-version: 6.4`, `.v27` gibt es erst ab dieser Version.
- **Keychain Access Group und App Group** kommen mit A3 statt A1. Sie brauchen Entitlements und eine Signierung, und erst A3 hat einen Test, der sie prüft.
- **Test-Targets:** Im Gerüst gibt es nur `YuvomiCoreTests` mit einem Rauchtest für die Fixtures. Die übrigen Module bekommen ihr Test-Target mit ihrem ersten Code.
- **Ausgangssprache:** Englisch (`developmentLanguage`, `defaultLocalization`). Deutsch kommt als Übersetzung in den String Catalog.
- **CI:** `.github/workflows/ci.yml` läuft auf dem Preview-Image `xcode-27`. `macos-26` hat nur Xcode 26.x und kann gegen iOS 27 nicht bauen (geprüft im ersten Lauf, 02.11.2026). Der Workflow nimmt das neueste vorhandene Xcode 27, ohne einen Pfad festzuschreiben. Sobald es ein reguläres Image gibt, kommt der Wechsel weg vom Preview. Generator-Check und Spec-Prüfung kommen mit A2 dazu.

## Abweichungen beim Bau (A2)

- **Abhängigkeitsrichtung umgedreht:** Bisher hieß es „UI → Core → API“. Damit hätte `YuvomiCore` den generierten Client aufrufen müssen, obwohl dessen Typen `internal` in `YuvomiAPI` bleiben. Jetzt definiert `YuvomiCore` Modelle und Protokolle, `YuvomiAPI` setzt sie um, und die App verbindet beides (Ports and Adapters). Der Kern hängt so an keinem Generator, und Widgets können ihn später ohne Netzwerkschicht einbinden.
- **Gekürzte Spec statt `filter`:** `update-spec.sh` kürzt die Spec schon beim Holen auf die 39 Operationen. Die Liste kommt aus `test/openapi-client-operations.js` desselben Tags, also aus derselben Quelle, die der Server-Guard prüft. `Spec/openapi.json` ist damit 290 KB statt 1,1 MB groß, und ein Diff zeigt nur, was die App betrifft. Einen `filter` in der Konfiguration braucht es nicht mehr. Geholt wird per `codeload.github.com`, ein lokaler Checkout des Server-Repos ist dafür nicht nötig.
- **Overrides mit Modulnamen:** In `typeOverrides` steht `YuvomiAPI.TaskCreateInput` statt `TaskCreateInput`. Sonst schreibt der Generator `typealias TaskCreateInput = TaskCreateInput` in `Components.Schemas`, und das verweist auf sich selbst.
- **Overrides im Detail:** Felder, die `null` annehmen, sind ein `Patch<Wert>` mit `unset`, `clear` und `set`. Die übrigen sind Optionals und werden bei `nil` weggelassen. `assigned_to` und `tags` gehen immer als Liste. `start_datetime` und `end_datetime` sind `String`, die App formatiert sie selbst. Damit entfällt das Enum `CalendarDateOrDateTime`, das kein Muster prüft (S5).
- **`product` ist ein Enum** mit dem einzigen Fall `yuvomi`. Ein fremder Wert scheitert also schon beim Dekodieren. Die Versionsprüfung in A3 muss diesen Fehler als „kein Yuvomi-Server“ melden, nicht als Netzwerkfehler.
- **Gemessen:** 0 Generator-Warnungen. Alle 21 Fixtures dekodieren über den generierten Client. `PUT /calendar/{id}` sendet `{"end_datetime":null,"assigned_to":[2,3]}`. Die Gegenprobe hält: Ein eingebauter `oneOf`-Zweig mit `null` erzeugt die Warnung `Schema "null" is not supported`, und das Skript bricht mit Exit 1 ab.

## Abweichungen beim Bau (A3)

- **Seams**, vor dem ersten Test abgestimmt:
  1. `ServerCheck.run(address:)` im Kern, mit einem Fake für den Port `ServerProbe`.
  2. Die Adapter `YuvomiServerProbe` und `YuvomiTasks` über den Fixture-Transport.
  3. `KeychainCredentialStore` gegen den echten Keychain.
- **Adressregel:** Ohne Schema gilt https. Ein eingetipptes http bleibt. Ein Pfad bleibt, der Schrägstrich am Ende fällt weg. Schema und Host werden klein geschrieben, damit derselbe Server immer denselben Keychain-Eintrag trifft.
- **`/version` liest der Adapter selbst**, über denselben Transport und mit lauter optionalen Feldern. Im generierten Typ sind `product` und `client_api` Pflicht. Ein alter oder fremder Server wäre dort nur ein Dekodierfehler, und `ServerCheck` könnte „zu alt“ und „kein Yuvomi“ nicht unterscheiden. Die Regel lautet:

  | `/version` liefert | Ergebnis |
  |---|---|
  | `product == "yuvomi"` und `client_api >= 1` | bereit |
  | `product == "yuvomi"` und `client_api` 0 oder fehlend | zu alt |
  | kein `product`, aber `app_name` (Yuvomi vor v2.83.0) | zu alt |
  | anderes `product`, gar nichts davon, HTML oder ein anderer Status | kein Yuvomi |
- **Fehler werden danach eingeordnet, ob eine Antwort kam.** Ohne Antwort gilt der Server als nicht erreichbar, mit Antwort als unerwartet. Eine Unterscheidung nach `DecodingError` reicht nicht: Ein Router, der mit `text/html` antwortet, löst im generierten Client einen anderen Fehler aus und hätte sonst „nicht erreichbar“ ergeben.
- **Keychain-Tests brauchen die App als Host:** Paket-Tests bekommen im Simulator `errSecMissingEntitlement` (-34018). Sie liegen deshalb in `Tests/HostedTests`, im Xcode-Target `YuvomiHostedTests` aus `project.yml`. Die Access Group ist dort `nil`.
- **Access Group und App Group** kommen mit A4. Erst dort benutzt die App den Keychain wirklich, und erst dann gibt es Entitlements. Ebenso der Keychain-Fake im Speicher: Ihn braucht erst der Anmeldeablauf.
- **`CalendarDay`** steht für `due_date` statt `Date`. Ein `Date` ist ein Zeitpunkt, und je nach Zeitzone des Geräts landete derselbe Tag sonst auf dem Vortag.

## Geklärte Fakten (02.11.2026)

- **Herkunft der Spec:** Die Spec liegt im Server-Repo nicht als Datei. `buildOpenApiSpec()` in `server/openapi.js` erzeugt sie zur Laufzeit, ausgeliefert wird sie nur an Admins unter `/api/v1/openapi.json`. Ohne Server geht es aber auch: Die Funktion läuft ohne `node_modules`, sobald `server/`, `public/` und `package.json` aus dem Tag vorliegen. Geprüft mit `v2.84.0`: 501 Pfade, `info.version` ist `2.84.0`. `update-spec.sh <tag>` holt diese drei Teile deshalb per `git archive` aus dem Tag, ruft die Funktion mit Node auf und schreibt das Ergebnis nach `Spec/`. Admin-Zugang und laufender Server sind dafür nicht nötig. Die Pfade beginnen mit `/api/v1/`, die Basis-URL der App ist also die reine Serveradresse.
- **Generator-Aufruf:** Der Generator läuft per CLI aus einem eigenen Werkzeug-Paket `Tools/` mit `exact: "1.14.3"` und eingechecktem `Package.resolved`, aufgerufen mit `swift run --package-path Tools swift-openapi-generator generate --config … --output-directory … Spec/…`. `typeOverrides` hat das Format `typeOverrides: schemas: { <Schemaname>: <Swift-Typ> }`. Der Schlüssel ist der letzte Teil von `#/components/schemas/…`, der Wert ein Typ, der im selben Modul liegt. `accessModifier: internal` ist der Standard und wird trotzdem ausdrücklich gesetzt.
- **SSO-only:** `GET /auth/oidc/config` liefert `enabled`, `password_login_enabled` und `guest_password_login_enabled`. Bei `password_login_enabled == false` zeigt die App den Hinweis statt des Formulars. `guest_password_login_enabled` spielt keine Rolle, weil Gäste nach S2 kein Credential bekommen.

## Fertig, wenn

- [ ] Ein Mitglied meldet sich im Simulator per Passwort an, auf Wunsch mit 2FA, und sieht seine Aufgaben.
- [ ] Ein zu alter Server, ein Server ohne `product` und ein SSO-only-Server bekommen vor der Passworteingabe je eine klare Meldung.
- [ ] Abmelden und ein widerrufenes Credential führen zurück zum Login, und der Keychain-Eintrag ist danach weg.
- [ ] Alle 21 Fixtures dekodieren, und der Generator-Check in der CI ist grün.
- [ ] Alle Texte liegen auf Deutsch und Englisch im String Catalog.
- [ ] Das Repo ist öffentlich.

## Nachzuziehen in der Yuvomi-Doku

- `client_api`: Ein höherer Wert muss den bisherigen Vertrag weiter bedienen. Ein echter Bruch braucht ein eigenes Feld wie `client_api_min`. Das gehört in die Doku zu `/version` im Server-Repo und wird dort über den üblichen Weg eingetragen.
