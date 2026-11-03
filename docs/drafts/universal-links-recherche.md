# Recherche: Universal Links statt (oder neben) Custom URL Scheme

Stand: 2026-11-03. Quellen sind, wo nicht anders vermerkt, Apple-Primärquellen (developer.apple.com-Dokumentation, Tech Notes, WWDC-Transkripte). Abgerufen am Recherchetag. Wo nur Sekundäres oder gar nichts gefunden wurde, steht das ausdrücklich dabei (**Kein Primärbeleg**).

Ausgangslage: Die App koppelt sich an selbst gehostete Server mit beliebigen Domains. Heute: `myapp://pair?server=<origin>&code=<code>` mit Bestätigung „Mit Server X koppeln?“ vor dem Einlösen.

---

## 1. Associated Domains und `apple-app-site-association`

### Grundprinzip

- Associated Domains brauchen zwei Seiten: die Datei `apple-app-site-association` (AASA) auf der Website und das passende Entitlement in der App. Die in der AASA genannten Apps müssen ein passendes `com.apple.developer.associated-domains` haben.
  Quelle: https://developer.apple.com/documentation/xcode/supporting-associated-domains
- Beim Installieren der App versucht das System, die Datei herunterzuladen und die Domains aus dem Entitlement zu prüfen. „Only you can store this file on your server“ – darauf beruht die Sicherheit der Zuordnung.
  Quellen: https://developer.apple.com/documentation/xcode/supporting-associated-domains, https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content
- Ist die App nicht installiert, öffnet das System die URL im Standardbrowser; die Website übernimmt.
  Quelle: https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content, https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links

### Entitlement

- Format je Eintrag: `<service>:<fully qualified domain>`, für Universal Links der Dienst `applinks` (weitere: `webcredentials`, `activitycontinuation`, `appclips`).
  Quelle: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-domains
- Nur Subdomain und Top-Level-Domain eintragen, keine Pfade, Query oder abschließenden Schrägstrich.
  Quelle: https://developer.apple.com/documentation/xcode/supporting-associated-domains
- Keine Portnummern: `applinks:example.com:8080` öffnet die App nicht.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Webbrowser-Apps (mit `com.apple.developer.web-browser`) dürfen `applinks` nicht nutzen.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links

### Datei: Ort, HTTPS, Redirects, Content-Type

- Dateiname `apple-app-site-association` ohne Endung, abgelegt unter `https://<fully qualified domain>/.well-known/apple-app-site-association`.
  Quelle: https://developer.apple.com/documentation/xcode/supporting-associated-domains
- „You must host the file using `https://` with a valid certificate and with no redirects.“
  Quelle: https://developer.apple.com/documentation/xcode/supporting-associated-domains
- 301/302 beim Abruf der AASA wird nicht unterstützt; die Datei muss auf jeder Domain/Subdomain aus `applinks` selbst liegen. Die Datei muss von allen IP-Adressen und mit beliebigem User-Agent abrufbar sein (403/404 = Fehler).
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Das Zertifikat muss von einer im System vertrauten Root-CA stammen, eigene Root-Zertifikate werden nicht unterstützt; HTTP ist nicht zulässig. Signierte AASA-Dateien sind veraltet; andere Pfade als `/.well-known/` sind veraltet.
  Quelle: WWDC19 „What's New in Universal Links“, https://developer.apple.com/videos/play/wwdc2019/717/
- **Content-Type:** In der aktuellen Apple-Dokumentation habe ich **keine** Vorgabe zum Content-Type gefunden (**kein aktueller Primärbeleg**). Der frühere, archivierte „App Search Programming Guide“ nannte laut Suchergebnis `application/json` für unsignierte Dateien; die Archiv-URL leitet heute auf die neue Doku weiter und war nicht mehr im Wortlaut abrufbar.
  Quelle (archiviert, nur über Suchsnippet): https://developer.apple.com/library/archive/documentation/General/Conceptual/AppSearch/UniversalLinks.html
  Ein Forenbeitrag von Quinn „The Eskimo!“ (Apple DTS) erklärt, dass Server den Typ wegen der fehlenden Endung oft falsch setzen: https://developer.apple.com/forums/thread/22551 (laut Suchergebnis; Thread selbst nicht im Detail geprüft).

### Format (`applinks`, `details`, `components`, `paths`)

- Top-Level-Objekt `applinks` mit `details` (Array), optional `defaults` und `substitutionVariables`.
  Quelle: https://developer.apple.com/documentation/bundleresources/applinks
- Ein `details`-Eintrag hat `appIDs` (oder `appID`) im Format `<Application Identifier Prefix>.<Bundle Identifier>` und `components`.
  Quelle: https://developer.apple.com/documentation/bundleresources/applinks/details-swift.dictionary
- `components`-Schlüssel: `/` (Pfad), `?` (Query, als String oder als Dictionary je Query-Item), `#` (Fragment), `exclude`, `comment`, `caseSensitive`, `percentEncoded`. Standard für `/`, `?`, `#` ist `*`. Wildcards: `*` (null oder mehr Zeichen, gierig), `?` (genau ein Zeichen), `?*` (mindestens eins). Reihenfolge zählt, der erste Treffer gewinnt. Ein Treffer liegt nur vor, wenn alle angegebenen Komponenten passen.
  Quelle: https://developer.apple.com/documentation/bundleresources/applinks/details-swift.dictionary/components-swift.dictionary
- Query-Items: Wiederholte Namen müssen alle passen; fehlende Items gelten als leerer String. `components` ersetzt seit 2019 den Schlüssel `paths`.
  Quelle: https://developer.apple.com/videos/play/wwdc2019/717/
- Altes Format `appID` + `paths` (mit `NOT`) ist weiterhin erkannt; Formate nicht mischen.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links

### Laden über Apple-CDN, `?mode=developer`, Aktualisierung

- Seit iOS 14 / macOS 11 fragen Geräte die AASA nicht mehr direkt beim Webserver an, sondern bei einem Apple-CDN für Associated Domains. Hat das CDN keine oder eine alte Kopie, holt es die Datei vom Webserver.
  Quellen: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-domains, https://developer.apple.com/videos/play/wwdc2020/10098/
- „Apple’s content delivery network requests the `apple-app-site-association` file for your domain within 24 hours. Devices check for updates approximately once per week after app installation.“
  Quelle: https://developer.apple.com/documentation/xcode/supporting-associated-domains
- Bei Installation lädt das Gerät die Datei sofort vom CDN; für eine neuere Version App neu installieren; „There is no direct CDN invalidation option.“
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Alternate Modes über Query am Entitlement: `?mode=developer` (CDN umgehen, beliebiges gültiges Zertifikat, nur Geräte im Developer Mode mit Opt-in, nur mit Development-Profil signierte Apps), `?mode=managed` (nur Geräte mit MDM-Profil, Zustimmung des MDM-Admins), `?mode=developer+managed`.
  Quelle: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-domains
- App-Store-, TestFlight-Builds können Developer Mode nicht nutzen.
  Quelle: https://developer.apple.com/videos/play/wwdc2020/10098/
- Testen: Link in Notizen lange drücken; in Einstellungen > Entwickler > „Associated Domains Development“ und „Diagnostics“; am Mac `swcutil dl` / `swcutil verify`.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links

### Empfang in SwiftUI

- `onOpenURL(perform:)` erhält Universal Links und Custom-Scheme-URLs; SwiftUI liefert Universal Links direkt als URL statt als `NSUserActivity`.
  Quellen: https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:), https://developer.apple.com/documentation/swiftui/view/oncontinueuseractivity(_:perform:)
- Hinweis aus dem Forum (keine Apple-Mitarbeiter, **kein Primärbeleg**): Beim Scannen mit Kamera bzw. NFC kam der Universal Link nicht in `onOpenURL`, sondern nur über `onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` an (2021).
  Quelle: https://developer.apple.com/forums/thread/674141

---

## 2. Domains außerhalb des Entitlements, Laufzeit, Wildcards, MDM

### Domains, die nicht im Entitlement stehen

- Die Zuordnung setzt eine Domain im Entitlement **und** eine AASA auf genau dieser Domain voraus. Jede Subdomain braucht einen eigenen Eintrag und eine eigene AASA.
  Quelle: https://developer.apple.com/documentation/xcode/supporting-associated-domains
- Eine ausdrückliche Apple-Aussage „Domains außerhalb des Entitlements können keine Universal Links sein“ habe ich nicht gefunden; sie folgt aus der beschriebenen Zwei-Seiten-Prüfung (Schlussfolgerung, **kein wörtlicher Primärbeleg**).

### Ist das Entitlement zur Laufzeit änderbar?

- Entitlements sind „key-value pairs embedded in the code signature of its binary executable“; Xcode setzt sie beim Signieren aus Entitlements-Datei, Account-Daten und Provisioning Profile zusammen.
  Quelle: https://developer.apple.com/documentation/bundleresources/entitlements
- Daraus folgt: Änderung nur durch neuen signierten Build (Schlussfolgerung). Eine Apple-API, die Associated Domains zur Laufzeit ergänzt, habe ich **nicht gefunden**. Die einzige dokumentierte Ergänzung von außen ist der MDM-Weg (unten).
- WWDC20 bestätigt indirekt: Für Identity-Provider mit unterschiedlichen Hostnamen pro Kunde ist MDM der Weg, „rather than trying to add every customer into the app's embedded set of URLs before submitting the app to the App Store“.
  Quelle: https://developer.apple.com/videos/play/wwdc2020/10139/
- Forenthread mit derselben Frage (Domain nach Installation wechseln) ohne Apple-Antwort: **kein Primärbeleg**. https://developer.apple.com/forums/thread/763768 (laut Suchergebnis)

### Wildcards

- „For services other than `appclips`, you can prefix a domain with `*.` to match all of its subdomains.“
  Quelle: https://developer.apple.com/documentation/xcode/supporting-associated-domains
- Für `applinks:*.example.com` muss die AASA unter `https://example.com/.well-known/apple-app-site-association` liegen (Root-Domain). Für spezifische Subdomains wie `applinks:www.example.com` braucht es eine eigene AASA auf `www.example.com`.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Ob `*.example.com` auch `example.com` selbst abdeckt: **kein eindeutiger Primärbeleg** gefunden (TN3155 nennt `applinks:example.com` und `applinks:*.example.com` nebeneinander).
- Wildcards decken nur Subdomains **einer** Domain ab, nicht fremde Domains (folgt aus „all of its subdomains“).

### MDM-verwaltete Associated Domains (`com.apple.developer.associated-domains.mdm-managed`)

- Glossar: „MDM Managed Associated Domains allows MDM to supplement the Associated Domains that are included with your app with values such as server names that are unique for an environment.“
  Quelle: https://developer.apple.com/help/glossary/mdm-managed-associated-domains/
- WWDC20: Das Entitlement „allows MDM to supplement the associated domains that are included with the app“; seit 2020 öffentlich, ohne Freigabe durch DTS. Auf iOS kommen die Domains über die Managed-App-Konfiguration, auf macOS über ein eigenes Payload.
  Quelle: https://developer.apple.com/videos/play/wwdc2020/10139/
- MDM-Befehl `InstallApplication`, Attribute: `AssociatedDomains` („associated domains to add to this app“, iOS 13+) und `AssociatedDomainsEnableDirectDownloads` (Prüfung direkt bei der Domain statt über Apple-Server, nur für Domains ohne Internetzugang).
  Quelle: https://developer.apple.com/documentation/devicemanagement/installapplicationcommand/command-data.dictionary/attributes-data.dictionary
- macOS-Profil-Payload `com.apple.associated-domains` (laut Doku nur macOS).
  Quelle: https://developer.apple.com/documentation/devicemanagement/associateddomains
- Zielgruppe: verwaltete Geräte (Unternehmen/Organisationen mit MDM). Für Privatgeräte ohne MDM gibt es diesen Weg laut den Quellen nicht. Eine eigene Doku-Seite zum Entitlement-Schlüssel habe ich nicht gefunden (die erwartete URL lieferte 404).

---

## 3. Weiterleitung über eine feste Domain

Gedanke: Links der Form `https://link.example.com/pair?server=...&code=...`, nur `link.example.com` steht im Entitlement.

### Wann iOS einen Universal Link auslöst

- Tippen auf einen Universal Link öffnet die App direkt, ohne Browser oder Website. Auch Links in Safari und `WKWebView` sowie `open(_:options:completionHandler:)` / SwiftUI `openURL` aus anderen Apps lösen ihn aus. Öffnet die eigene App einen Link der eigenen Domain mit diesen Methoden, landet er nicht in der App.
  Quelle: https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content
- „Entering the URL directly into the web browser’s address bar will never open the app“; die Website zeigt dann ein Banner zum Öffnen der App.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Kamera: QR-Code mit Universal Link kann direkt in die App führen; ist die App nicht installiert, lädt Safari die URL. Apple empfiehlt auf dieser Seite einen Smart App Banner.
  Quelle: Tech Talk „QR Code Recognition on iOS 11“, https://developer.apple.com/videos/play/tech-talks/206/
- Nutzer können pro Domain umstellen (Long-Press: in App oder Browser öffnen); die Wahl wird als Standard gespeichert.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Fremde Browser: Unterstützung liegt beim Browserhersteller; Safari implementiert alles aus TN3155.
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links

### Redirects

- Für die AASA-Datei: keine Redirects (siehe 1).
- Für Links: „Redirection is allowed, although not preferred, when opening universal links from another app. If the link tapped on by the user is not a universal link but redirects to one, the user will be routed through the web browser to the app.“
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Redirects innerhalb derselben Domain: dazu keine eigene Aussage gefunden; es greift die Same-Domain-Regel (Abschnitt 5). **Kein eigener Primärbeleg** für den Redirect-Fall.

### App nicht installiert

- Dann öffnet sich die URL im Browser, also die Seite auf `link.example.com`.
  Quelle: https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content

### Datenschutz

- Query vs. Fragment: Das Fragment wird vor dem Abruf abgetrennt und nur vom User-Agent ausgewertet, also nicht an den Server geschickt. Quelle (IETF, nicht Apple): RFC 3986, Abschnitt 3.5, https://www.rfc-editor.org/rfc/rfc3986#section-3.5
- Der AASA-Abgleich kann das Fragment prüfen (Schlüssel `#`). Das System kennt also das Fragment beim Abgleich.
  Quelle: https://developer.apple.com/documentation/bundleresources/applinks/details-swift.dictionary/components-swift.dictionary
- Die App bekommt „the HTTP or HTTPS URL that the user accesses“ (`webpageURL`). Dass das Fragment dabei ausdrücklich erhalten bleibt, steht dort nicht wörtlich (**kein ausdrücklicher Primärbeleg**; naheliegend, weil die volle URL übergeben wird).
  Quelle: https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app
- Öffnet die App direkt (installiert, Link getippt), geht der Link laut Apple „without routing through the person’s default web browser or your website“ – der Betreiber der festen Domain sieht diese Aufrufe dann nicht.
  Quelle: https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content
- Öffnet sich die Seite (App fehlt, Adresszeile, Same-Domain, abweichende Nutzerwahl, fremder Browser), ruft der Browser `link.example.com` ab; was in der Query steht, erreicht dann den Server dieser Domain und kann dort geloggt werden (folgt aus HTTP; Fragment nicht, siehe RFC 3986).
- Apple-CDN: Apple beschreibt, dass das CDN die **AASA-Datei** abruft und cacht.
  Quellen: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links, https://developer.apple.com/videos/play/wwdc2020/10098/
  Eine ausdrückliche Apple-Aussage, dass die einzelnen Link-URLs **nicht** an Apple gehen, habe ich **nicht gefunden**.

### Abhängigkeit von der festen Domain

- Die AASA muss auf der Domain dauerhaft ohne Redirect, öffentlich und für alle IP-Adressen erreichbar sein; das CDN holt sie bei Installation und prüft etwa wöchentlich. Änderungen brauchen bis zu 24 Stunden im CDN, es gibt keine Invalidierung.
  Quellen: https://developer.apple.com/documentation/xcode/supporting-associated-domains, https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Fehlt die Zuordnung (Domain weg, AASA falsch), öffnet sich der Link im Browser (TN3155 behandelt genau diesen Fehlerfall).
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Der Link enthält weiter `server`- und `code`-Parameter; Apple rät auch bei Universal Links: Parameter validieren, fehlerhafte URLs verwerfen, keine riskanten Aktionen direkt auslösen.
  Quelle: https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app

---

## 4. Custom URL Schemes

- „While custom URL schemes are an acceptable form of deep linking, universal links are strongly recommended.“
  Quelle: https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app
- Reverse-DNS-Bezeichner „doesn’t prevent other apps from registering the same scheme and handling the associated links. Use universal links instead […]“. „If multiple apps register the same scheme, the app the system targets is undefined.“
  Quelle: https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app
- „URL schemes offer a potential attack vector into your app“: Parameter validieren, fehlerhafte URLs verwerfen, keine Aktionen, die Nutzerdaten gefährden.
  Quelle: https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app
- WWDC19: „Custom URL schemes are inherently insecure and can be abused by malicious developers. New uses of custom URL schemes are highly discouraged.“
  Quelle: https://developer.apple.com/videos/play/wwdc2019/717/
- WWDC20: „Custom URL schemes are not recommended.“ / migrieren „as soon as possible“.
  Quelle: https://developer.apple.com/videos/play/wwdc2020/10098/
- Dieselbe Warnung zur Angriffsfläche gilt laut Apple auch für Universal Links.
  Quelle: https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app

### Kamera-App: QR mit Custom Scheme vs. https

- https/Universal Link: Kamera zeigt eine Mitteilung; Tippen führt in die App (falls installiert und zugeordnet), sonst Safari. Bei mehreren Apps für dieselbe Domain fragt das System einmal und merkt sich die Wahl.
  Quelle: https://developer.apple.com/videos/play/tech-talks/206/
- Custom Scheme in der Kamera-App: **Kein Primärbeleg gefunden**, wie die Kamera damit umgeht (ob sie fragt, eine Mitteilung zeigt oder blockiert). Forenbeiträge von Nicht-Apple-Mitarbeitern berichten, dass Custom Schemes per QR funktionierten (nicht per NFC).
  Quelle (sekundär): https://developer.apple.com/forums/thread/674141
- Die App selbst kann QR-Text auch im eigenen Scanner auswerten; das hat ein Apple-Mitarbeiter im Zusammenhang mit undokumentierten System-Schemes empfohlen (laut Suchergebnis, Thread nicht im Detail geprüft).
  Quelle: https://developer.apple.com/forums/thread/97060

---

## 5. Gleiche Domain in Safari

- „When a user browses your website in Safari and taps a universal link in the same domain, the system opens that link in Safari […]. If the user taps a universal link in a different domain, the system opens the link in your app.“
  Quelle: https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content
- TN3155: Wer aus der eigenen Website in die App will, nutzt eine andere Subdomain (z. B. Seite auf `example.com`, Link auf `foo.example.com` mit eigener AASA und eigenem Entitlement-Eintrag).
  Quelle: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links

Folgen für die feste Domain (Schlussfolgerung aus beiden Quellen): Ein Link auf `link.example.com`, angetippt auf einer Seite einer **anderen** Domain (etwa der Weboberfläche einer Instanz), öffnet die App. Ein Link auf `link.example.com`, angetippt auf einer Seite **von** `link.example.com` (etwa der Fallback-Seite selbst), bleibt in Safari.

---

## Optionen (Fakten, ohne Empfehlung)

### A: Nur `scheme://`

- Funktioniert für jede Server-Domain ohne Zutun der Betreiber; keine AASA, kein CDN, keine feste Domain.
- Apple: „acceptable“, aber Universal Links „strongly recommended“; Custom Schemes „not recommended“ / „inherently insecure“. Jede App kann dasselbe Scheme registrieren; welche App es dann bekommt, ist undefiniert.
  Quellen: https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app, https://developer.apple.com/videos/play/wwdc2019/717/
- Kein Web-Fallback, wenn die App fehlt (folgt aus dem Fehlen einer https-URL).
- Kamera-Verhalten bei Custom Schemes: **kein Primärbeleg**.

### B: Universal Link über feste Domain, Scheme als Fallback

- Eine Domain im Entitlement, eine AASA dort; deckt alle Instanzen ab, weil die Server-Adresse als Parameter mitreist.
- App fehlt → Seite der festen Domain öffnet sich (Ort für Hinweis/App-Store-Link/Smart App Banner).
  Quellen: https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content, https://developer.apple.com/videos/play/tech-talks/206/
- Kein App-Start bei Eingabe in die Adresszeile und bei Tap auf derselben Domain in Safari.
  Quellen: https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links, https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content
- Abhängigkeit: Domain und AASA müssen dauerhaft erreichbar sein; CDN-Verzögerung bis 24 h, Geräte prüfen etwa wöchentlich, keine Invalidierung.
  Quellen: https://developer.apple.com/documentation/xcode/supporting-associated-domains, https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Datenschutz: Bei Browser-Abruf erreicht die Query den Server der festen Domain; das Fragment nicht (RFC 3986 §3.5). Bei direktem App-Start läuft der Link laut Apple nicht über die Website. Ob Apple Link-URLs sieht: **kein Primärbeleg** (Apple beschreibt nur den AASA-Abruf).
- Das Scheme bleibt mit seinen dokumentierten Schwächen bestehen, solange es registriert ist.

### C: Universal Link pro Instanz

- Jede Instanz-Domain müsste im signierten Entitlement stehen und die AASA mit der App-ID hosten; Entitlements sind Teil der Code-Signatur, also neuer Build pro neuer Domain.
  Quellen: https://developer.apple.com/documentation/xcode/supporting-associated-domains, https://developer.apple.com/documentation/bundleresources/entitlements
- Wildcards decken nur Subdomains einer Domain ab (`*.example.com`), nicht beliebige fremde Domains; AASA dann auf der Root-Domain.
  Quellen: https://developer.apple.com/documentation/xcode/supporting-associated-domains, https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links
- Developer Mode (`?mode=developer`) gilt nicht für App-Store-/TestFlight-Builds.
  Quelle: https://developer.apple.com/videos/play/wwdc2020/10098/
- Ergänzung zur Laufzeit nur über MDM (`mdm-managed`-Entitlement plus `AssociatedDomains`-Attribut beim MDM-Befehl `InstallApplication`), also nur auf verwalteten Geräten.
  Quellen: https://developer.apple.com/help/glossary/mdm-managed-associated-domains/, https://developer.apple.com/videos/play/wwdc2020/10139/, https://developer.apple.com/documentation/devicemanagement/installapplicationcommand/command-data.dictionary/attributes-data.dictionary
- Für eine einzelne feste Domain (z. B. eine Review-Instanz) wäre ein Entitlement-Eintrag möglich; das deckt nur diese eine Domain ab.

## Lücken (nichts Primäres gefunden)

- Aktuelle Content-Type-Vorgabe für die AASA (nur archivierte Doku/Forum).
- Ob `*.example.com` die Root-Domain selbst einschließt.
- Verhalten der Kamera-App bei QR-Codes mit Custom Scheme.
- Redirects innerhalb derselben Domain beim Öffnen eines Links.
- Ob das Fragment in `webpageURL` / `onOpenURL` garantiert erhalten bleibt.
- Ob Apple einzelne Link-URLs (nicht nur die AASA) erfährt.
- Eigene Referenzseite für `com.apple.developer.associated-domains.mdm-managed` (URL gab 404).
- Eine Apple-API zum Hinzufügen von Associated Domains zur Laufzeit (keine gefunden; nur MDM dokumentiert).
