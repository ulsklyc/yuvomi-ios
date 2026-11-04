<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="App-Icon von Yuvomi" width="92" />

  <h1>Yuvomi für iOS</h1>

  <p><strong>Das Yuvomi eurer Familie, nativ auf dem iPhone.<br>Es spricht mit eurem eigenen Server und mit sonst niemandem.</strong></p>

  <p>
    Die Begleit-App zu <a href="https://github.com/ulsklyc/yuvomi">Yuvomi</a>, dem selbst gehosteten
    Familienplaner. Meldet euch an dem Server an, den euer Haushalt betreibt, seht eure Aufgaben und
    bekommt Erinnerungen aufs Telefon, auch wenn die App geschlossen ist.
  </p>

  <p>
    <img src="https://img.shields.io/badge/status-early%20development-6C3AED?style=flat-square" alt="Stand: frühe Entwicklung">
    <img src="https://img.shields.io/badge/iOS-27%2B-6C3AED?style=flat-square" alt="Braucht iOS 27 oder neuer">
    <img src="https://img.shields.io/badge/Swift-6-6C3AED?style=flat-square" alt="Swift 6">
    <a href="https://github.com/ulsklyc/yuvomi-ios/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ulsklyc/yuvomi-ios/ci.yml?branch=main&style=flat-square&color=6C3AED&label=CI" alt="Stand der CI"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-6C3AED?style=flat-square" alt="MIT-Lizenz"></a>
  </p>

  <p>
    <a href="https://github.com/ulsklyc/yuvomi"><strong>→ Yuvomi-Server</strong></a>&nbsp;&nbsp;·&nbsp;
    <a href="https://yuvomi.cloud/"><strong>yuvomi.cloud</strong></a>&nbsp;&nbsp;·&nbsp;
    <a href="#selbst-bauen">Selbst bauen</a>&nbsp;&nbsp;·&nbsp;
    <a href="README.md" hreflang="en">English&nbsp;(maßgeblich)</a>
  </p>

  <p><b>1</b>&nbsp;Server,&nbsp;eurer&nbsp;&nbsp;·&nbsp; <b>0</b>&nbsp;Tracker&nbsp;&nbsp;·&nbsp; <b>0</b>&nbsp;In-App-Käufe&nbsp;&nbsp;·&nbsp; <b>2</b>&nbsp;Sprachen</p>
</div>

Die Web-App von Yuvomi kommt schon heute direkt aus dem Browser auf jeden Startbildschirm. Diese
App ist für das, was eine native App auf dem iPhone besser kann: die Anmeldung per gescanntem Code
und Erinnerungen, die das Telefon selbst plant, sodass sie pünktlich ankommen, ganz ohne
Push-Relay.

---

## Was die App heute kann

- **Am eigenen Server anmelden.** Adresse eingeben und mit Passwort anmelden, dazu mit
  Zwei-Faktor-Code, wenn euer Konto ihn nutzt.
- **Oder ohne Passwort koppeln.** Die Web-App von Yuvomi zeigt einen kurzen Kopplungscode, als
  QR-Code, als Link, der die App öffnet, oder zum Abtippen. Das klappt auch in Haushalten, die sich
  nur per Single Sign-on anmelden. Jedes angemeldete Telefon erscheint in der Web-App und lässt sich
  dort abmelden.
- **Eure Aufgaben**, so wie sie auf dem Server stehen, mit Priorität und Fälligkeit.
- **Erinnerungen auf dem Telefon.** Kommende Erinnerungen an Aufgaben und Termine plant das Gerät
  selbst; sie kommen auch an, wenn die App geschlossen oder das Telefon gesperrt ist. Die App
  frischt sie im Hintergrund auf, ein Schalter stellt sie nur für dieses Telefon ab.

Die PWA bleibt das vollständige Yuvomi. Die App wächst Schritt für Schritt, und was sie noch nicht
kann, ist im Browser einen Tipp entfernt.

## Fragen

**Welchen Server brauche ich?** Yuvomi **v2.84.0** oder neuer, erreichbar vom Telefon aus. Die App
spricht nur mit dem Server, an dem ihr euch anmeldet: kein Konto bei uns, keine Analyse, keine
Fremd-SDKs.

**Welche iPhones?** Jedes iPhone mit iOS 27. Ältere Geräte nutzen weiter die Web-App.

**Wo bekomme ich sie?** Noch nicht im App Store. Die App ist in früher Entwicklung und geht zuerst
in TestFlight. Bis dahin könnt ihr sie [selbst bauen](#selbst-bauen).

**Was kostet sie?** Nichts. Kostenlos, MIT-Lizenz, keine In-App-Käufe.

---

## Selbst bauen

Ihr braucht einen Mac mit **Xcode 27** und [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Das Xcode-Projekt entsteht aus `project.yml` und ist nicht eingecheckt.

```bash
git clone https://github.com/ulsklyc/yuvomi-ios.git
cd yuvomi-ios
xcodegen generate
open Yuvomi.xcodeproj
```

Einen iPhone-Simulator wählen und das Schema `Yuvomi` starten. Für das eigene iPhone das eigene
Entwicklerteam in `project.yml` eintragen (`DEVELOPMENT_TEAM`) und neu erzeugen.

<details>
<summary><b>Tests, der API-Client und die Demodaten</b></summary>

<br>

- **Tests** laufen im Simulator, genau wie in der CI:
  `xcodebuild test -project Yuvomi.xcodeproj -scheme Yuvomi -destination "platform=iOS Simulator,name=<iPhone>"`.
  Die CI läuft auf Englisch; mit `-testLanguage en` lokal genauso.
- **Der API-Client** in `Sources/YuvomiAPI/Generated/` wird aus `Spec/openapi.json` erzeugt, einer
  festgeschriebenen Kopie der OpenAPI-Spec des Servers. Nie von Hand ändern: `scripts/generate-api.sh`
  ausführen, das bei der ersten Generator-Warnung abbricht. `scripts/update-spec.sh` holt die Spec
  eines neueren Server-Releases. Die CI schlägt fehl, wenn der eingecheckte Client nicht zur Spec passt.
- **`Fixtures/demo/`** enthält echte Antworten einer Yuvomi-Demoinstanz. Vorschauen und Tests lesen
  sie mit dem echten Decoder; wie sie gezogen werden, steht in `Fixtures/README.md`.

</details>

<details>
<summary><b>Wie der Code aufgebaut ist</b></summary>

<br>

| Modul | Was es enthält |
|---|---|
| `YuvomiCore` | Domänenmodelle, die Sitzung, den Schlüsselbund und die Protokolle, die alles andere umsetzt. Kennt kein HTTP. |
| `YuvomiAPI` | Den erzeugten Client hinter den Protokollen des Kerns. Erzeugte Typen verlassen dieses Modul nie. |
| `LoginFeature`, `TasksFeature`, `RemindersFeature` | Ein SwiftUI-Modul je Bereich der App. |
| `DesignSystem` | Oberflächenteile, die sich die Screens teilen, bisher das Label, das ein Problem erklärt. |
| `App/` | Verbindet die Module. |

Swift 6 mit strikter Nebenläufigkeitsprüfung, ein `@Observable`-Modell je Screen, Tests mit Swift
Testing. Texte liegen in String Catalogs, Englisch zuerst, Deutsch daneben.

</details>

---

## Lizenz

MIT, wie Yuvomi selbst. Siehe [LICENSE](LICENSE).
