# Kopplung auf demselben Gerät per `yuvomi://`, nicht per Universal Link

Entschieden am 03.11.2026 (B6, vor TestFlight). Status: accepted.

Die Web-App koppelt ein Telefon, auf dem sie selbst läuft, über „In der App öffnen“ mit `yuvomi://pair?server=<origin>&code=<code>`. Derselbe Link steht im QR-Code. Ein Universal Link kommt nicht dazu, weil er nur für Domains geht, die beim Build im Entitlement stehen. Yuvomi-Instanzen laufen aber unter beliebigen eigenen Domains, und eine Weiterleitung über eine feste Domain des Projekts würde jede Instanz an diese Domain binden. Das schließt [SCOPE.md](https://github.com/ulsklyc/yuvomi/blob/main/docs/SCOPE.md) für den nativen Client aus („needs no Yuvomi cloud and no account with anyone but the household's own server“).

## Erwogene Optionen

- **Universal Link je Instanz.** Geht nicht. Associated Domains stehen in der Code-Signatur, jede neue Domain bräuchte einen neuen Build. Wildcards decken nur Subdomains einer Domain ab. Domains zur Laufzeit ergänzen kann nur MDM auf verwalteten Geräten.
- **Universal Link über eine feste Domain** (`https://link.yuvomi.cloud/pair#…`, `yuvomi://` als Rückfall). Der Link wäre exklusiv für die App. Dafür müssten Domain und `apple-app-site-association` dauerhaft erreichbar bleiben. Ohne App, in der Adresszeile und bei abweichender Nutzerwahl landet der Abruf beim Betreiber der Domain. Abgelehnt wegen SCOPE.md.
- **Universal Link nur für die Review-Instanz.** Das wären zwei Wege für denselben Schritt, und echte Haushalte hätten nichts davon. Abgelehnt.

## Folgen

- **Restrisiko:** Jede App kann `yuvomi://` registrieren. Welche App den Link bekommt, ist dann undefiniert. Eine fremde App könnte Code und Server abfangen und selbst einlösen. Die Bestätigung des Servers vor dem Einlösen schützt nur vor einem untergeschobenen `server`, nicht vor dem Abfangen.
- **Gegenmittel:**
  - Der Code gilt fünf Minuten und nur einmal.
  - Solange er offen ist, zeigt die Web-App unter „Angemeldete Geräte“ das Gerät, das sich gerade angemeldet hat, mit Name und Plattform. Ein fremder Name fällt auf und lässt sich dort sofort abmelden.
  - Der Scanner in der App und der abgetippte Code laufen nicht über das Schema. Ein QR, den die Kamera-App von iOS liest, geht dagegen über `yuvomi://` und ist genauso abfangbar wie „In der App öffnen“.
- **Keine Arbeit in der App:** kein Entitlement, keine `apple-app-site-association` im Server.

## Wieder aufmachen, wenn

- Apple Associated Domains zur Laufzeit oder je Nutzer zulässt, ohne MDM.
- eine App bekannt wird, die `yuvomi://` registriert, oder ein abgefangener Code berichtet wird.
- das Projekt doch einen gehosteten Dienst unter eigener Domain anbietet.

Belege mit Quellen: [universal-links-recherche.md](../drafts/universal-links-recherche.md).
