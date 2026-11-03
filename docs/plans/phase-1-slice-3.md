# Phase 1, Slice 3: Erinnerungen auf dem iPhone

Stand 03.11.2026, entschieden in einer Grilling-Runde (Q1 bis Q13) auf Basis von „S4: Kommende Erinnerungen“ in [phase-0-server.md](phase-0-server.md) und der Recherche [03-lokale-erinnerungen-recherche.md](../drafts/03-lokale-erinnerungen-recherche.md). Server-Vertrag bleibt `v2.84.0` mit `client_api: 1`. Grundlage im Code ist der Stand nach Slice 2 ([phase-1-slice-2.md](phase-1-slice-2.md)) und B6.

**Ziel:** Ein angemeldetes Mitglied bekommt die Erinnerungen seiner Aufgaben und Termine als Mitteilung auf dem iPhone, auch wenn die App geschlossen ist. Die App plant sie selbst aus `GET /reminders/upcoming`, ohne Push und ohne Relay.

**Nicht in diesem Slice:** Abhaken oder „Erledigt“ an der Mitteilung, Erinnerungen am Server als gelesen markieren (`PATCH /reminders/{id}/dismiss`), Antippen mit Ziel (Aufgabe oder Termin), Time Sensitive, vorläufige Erlaubnis, andere Herkünfte als `task` und `event`, ein Server-PR. Das Abhaken mit gezieltem Abplanen kommt in Slice 4.

## Überblick

| # | Schritt | Hängt ab von |
|---|---|---|
| C1 | Kern: Modelle, Ports, `ReminderSync` | - |
| C2 | Adapter: `YuvomiUpcomingReminders` | C1 |
| C3 | `RemindersFeature`: Planer für iOS, Trigger, Mitteilungstexte | C1 |
| C4 | Einstellungen: `RemindersSettingsModel`, Blatt „Einstellungen“, Karte in der Liste | C1, C3 |
| C5 | App: Abgleich bei Start und Vordergrund, Abräumen, Delegate | C2, C3, C4 |
| C6 | Abgleich im Hintergrund (`BGAppRefreshTask`) | C5 |
| C7 | Simulator- und iPhone-Lauf, CI grün | C6 |

---

## Fakten aus Server, Spec und Recherche

- **Route:** `GET /api/v1/reminders/upcoming?from=<iso>&to=<iso>&types=task,event`. Beide Ränder zählen, das Fenster ist höchstens 14 Tage lang, sortiert nach dem Zeitpunkt, höchstens 200 Zeilen. Es kommt nur, was nach jetzt liegt. Ein unbekannter `types`-Wert und ein zu langes Fenster ergeben 400.
- **Zeitpunkt:** Geplant wird nur mit `fires_at` (UTC mit `Z`). `remind_at` kann aus alten Zeilen einen Offset tragen. Das Fixture `reminders-upcoming.json` hat eine Zeile mit `entity_type: task` und `entity_title`.
- **Sichtbarkeit:** Fremdes, Privates, Erledigtes, Abgelegtes und abgeschaltete Module lässt der Server weg (`test:reminders-upcoming`). `types=task,event` hält Gesundheit und Finanzen aus dem Binary, wie in der Apple-Anfrage beschrieben.
- **Serien-Lücke:** Ein gelöschtes erstes Vorkommen einer Serie erinnert auf `v2.84.0` noch. Behoben mit ulsklyc/yuvomi#2495 auf `main`, noch in keinem Release. Die App braucht dafür nichts, sie bekommt die Korrektur mit dem nächsten Server-Release.
- **Limit von iOS:** vermutlich 64 geplante Mitteilungen je App (Apple-Forum, Jan. 2026). Was mit einer 65. passiert, ist nicht dokumentiert.
- **Trigger:** `UNCalendarNotificationTrigger` mit vollständigen Komponenten in UTC (`calendar` und `timeZone` gesetzt, `repeats: false`) trifft `fires_at` unter jeder Zeitzone des Geräts (Versuch in der Recherche). Ein Intervall-Trigger mit ≤ 0 Sekunden stürzt ab.
- **Ersetzen:** `add` mit derselben Kennung ersetzt die alte Anfrage. Kennung je Erinnerung: `reminder.<id>`.
- **Hintergrund:** `BGAppRefreshTask` startet ohne Garantie, läuft bis etwa 30 Sekunden und ist im Simulator nicht verfügbar. Er braucht `UIBackgroundModes: fetch` und `BGTaskSchedulerPermittedIdentifiers`.
- **Swift 6:** Die UN-Typen sind nicht `Sendable`. Delegate-Methoden müssen `nonisolated` sein, ein `@MainActor`-Delegate mit async `didReceive` baut nicht.

## Entscheidungen

### Zuschnitt (Q1)

- **Erinnerungen statt Schreiben von Aufgaben, Einkauf oder Kalender.** Der Server-Teil ist fertig (S4). Es ist der Punkt, an dem die App mehr kann als die PWA, deren Web Push auf iOS unzuverlässig ist. Das Risiko (Limit, Zeitzonen, Abgleich ohne Push) soll vor TestFlight geklärt sein. Und der Slice bleibt lesend, die Eingaben mit `unset`, `clear` und `set` sind noch nicht im Spiel.

### Erlaubnis und Einstellungen (Q5, Q6, Q10)

- **Erlaubnis im Kontext:** Nach der Anmeldung steht über der Aufgabenliste einmal eine Karte „Erinnerungen auf diesem iPhone?“. Erst ihr Knopf löst die Frage von iOS aus. „Nicht jetzt“ blendet sie dauerhaft aus, der Weg bleibt in den Einstellungen.
- **Blatt „Einstellungen“** statt des Menüs „Konto“ oben rechts:
  - Abschnitt „Erinnerungen“: Schalter „Erinnerungen auf diesem iPhone“, Stand der Erlaubnis und bei Ablehnung der Weg in die Einstellungen von iOS. Dazu ein Hinweis: Wer die Web-App mit Mitteilungen nutzt, bekommt Erinnerungen doppelt. Die App plant die nächsten 14 Tage, höchstens 60 Erinnerungen, und holt Neues beim Öffnen und ab und zu im Hintergrund.
  - Abschnitt „Konto“: Server und „Abmelden“. „Abmelden“ zieht aus dem Menü hierher.
- **Schalter aus** räumt alle geplanten Mitteilungen ab, Schalter an gleicht sofort ab. Der Schalter gilt für dieses Gerät, nicht für das Konto.
- **Keine vorläufige Erlaubnis:** Sie stellt die ersten Erinnerungen still zu, das passt nicht zu Erinnerungen.

### Mitteilung (Q7, Q11, Q12)

- **Inhalt:** Überschrift „Aufgabe“ oder „Termin“, darunter `entity_title`. Ob der Sperrbildschirm den Titel zeigt, regelt iOS über „Vorschauen zeigen“.
- **Antippen** öffnet die App auf der Aufgabenliste, sonst nichts.
- **Im Vordergrund** erscheint die Mitteilung als Banner mit Ton (Delegate `willPresent`).
- **Kein Time Sensitive:** Es braucht ein Entitlement ohne Referenzseite, und Apple rät zu sparsamem Einsatz. Später als eigener Punkt.

### Abgleich (Q9, Q10)

- **`ReminderSync` im Kern** ist der eine Ort für die Planungsregeln. Er holt die kommenden Erinnerungen für das Fenster `jetzt` bis `jetzt + 14 × 86400 s` (nicht `Calendar.date(byAdding: .day)`, sonst ist das Fenster über die Umstellung im Herbst eine Stunde zu lang und der Server antwortet 400). Er lässt aus, was nicht mindestens fünf Sekunden nach jetzt liegt, nimmt die frühesten 60 und gleicht über die Kennungen ab: neu planen, Weggefallenes entfernen, Geändertes (Zeitpunkt oder Titel) ersetzen. Mitteilungen, die nicht mit `reminder.` beginnen, fasst er nicht an.
- **60 statt 64:** etwas Luft unter dem vermuteten Limit. Was darüber hinausgeht, kommt beim nächsten Abgleich nach.
- **Zeitpunkte:** beim Start, bei jedem Wechsel in den Vordergrund, nach dem Einschalten des Schalters und im Hintergrund über `BGAppRefreshTask` (C6). Läuft ein Abgleich schon, wird kein zweiter gestartet.
- **Fehler:** Ein 401 läuft über `SessionState.handle(.unauthorized, from:)`, das Abmelden räumt dann ab. Netzfehler und andere Antworten lassen die geplanten Mitteilungen stehen, der nächste Abgleich versucht es neu.
- **Abräumen** bei Abmelden, Widerruf (401) und ausgeschaltetem Schalter: alle Mitteilungen mit `reminder.`, geplante und schon zugestellte.
- **Nichts zurückschreiben (Q8):** Die App markiert keine Erinnerung als gelesen. Die PWA zeigt eine fällige Erinnerung deshalb weiter, bis man sie dort verwirft. Das gehört in Slice 4.

### Module (Q9)

```
RemindersFeature ──> YuvomiCore <── YuvomiAPI
   (Planer für iOS,     (ReminderSync,     (YuvomiUpcomingReminders)
    Texte, Karte,        Ports, Modelle)
    Einstellungen)
                  App verbindet alles
```

- **Kern:** `UpcomingReminder` (id, Herkunft `task`/`event`, Titel, Zeitpunkt), Port `UpcomingReminders` (`upcoming(from:to:)`), Port `NotificationScheduling` (geplante Kennungen lesen, planen, entfernen, mit eigenen `Sendable`-Werten), `ReminderSync`. Die UN-Typen verlassen `RemindersFeature` nicht.
- **`YuvomiAPI`:** `YuvomiUpcomingReminders` mit `types=task,event` fest, generierte Typen bleiben `internal`.
- **`RemindersFeature`** (neu): `SystemNotificationScheduler` über `UNUserNotificationCenter`, die Mitteilungstexte (Titel „Aufgabe“ und „Termin“ müssen beim Planen übersetzt sein), `RemindersSettingsModel`, Karte und Abschnitt der Einstellungen, eigener String Catalog.
- **Einstellungen:** Das Blatt setzt die App aus dem Abschnitt von `RemindersFeature` und dem Abschnitt „Konto“ zusammen. `TasksFeature` bekommt dafür nur einen Knopf für die Einstellungen statt des Menüs.
- **App Group:** Der Schalter liegt zunächst in `UserDefaults.standard`, wie die Serveradresse. Er zieht mit den Widgets in die Defaults von `group.cloud.yuvomi`.

### Tests (Q13)

Seams, vor dem ersten Test bestätigt:

1. `ReminderSync.run(now:)` im Kern mit Fakes für `UpcomingReminders` und `NotificationScheduling`: Fenster genau 14 × 86400 s, Kappung auf 60, Diff (neu, weg, geändert, unverändert), fremde Kennungen bleiben, Vergangenes fällt heraus, Abräumen, Fehler lassen den Bestand stehen, 401 wird gemeldet.
2. `YuvomiUpcomingReminders` über den Fixture-Transport mit Recorder: Abfrage mit `types=task,event`, `from` und `to` als ISO-Zeitpunkte, Dekodieren von `fires_at`, 400, 401 und Netzfehler.
3. Trigger im Adapter: `nextTriggerDate()` des gebauten Triggers ist `fires_at`, auch unter einer fremden Zeitzone. Ohne Center, läuft als normaler Test im Simulator.
4. `RemindersSettingsModel` mit einem Fake für die Erlaubnis: Karte sichtbar und ausgeblendet, Schalter an und aus, abgelehnte Erlaubnis.

Ohne Unit-Test bleiben Views, Delegate, Verdrahtung und der Hintergrund-Abgleich. Die prüft der Lauf in C7. Vorschauen für Karte und Einstellungen in allen Zuständen der Erlaubnis.

---

## C1 bis C7 im Einzelnen

**C1, Kern:**
- `UpcomingReminder`, die Ports `UpcomingReminders` und `NotificationScheduling`, `PlannedNotification` als eigener Werttyp (Kennung, Zeitpunkt, Herkunft, Titel).
- `ReminderSync.run(now:)` und `ReminderSync.clear()`.
- Fertig, wenn die Tests zu Seam 1 grün sind.

**C2, Adapter:**
- `YuvomiUpcomingReminders` über den generierten Client, Fehler wie bei `YuvomiTasks` eingeordnet (401 als `.unauthorized`).
- Fertig, wenn die Tests zu Seam 2 grün sind und die Anfrage am Recorder `types=task,event` trägt.

**C3, Planer für iOS:**
- Neues Target `RemindersFeature` in `Package.swift` mit Test-Target und String Catalog.
- `SystemNotificationScheduler`: Trigger in UTC, Inhalt mit übersetzter Überschrift und Titel, nur Kennungen mit `reminder.`.
- Fertig, wenn der Trigger-Test (Seam 3) grün ist.

**C4, Einstellungen:**
- `RemindersSettingsModel` (`@Observable`, Port für die Erlaubnis), Karte für die Liste, Abschnitt „Erinnerungen“.
- Blatt „Einstellungen“ mit Abschnitt „Konto“. Das Menü „Konto“ in `TaskListView` entfällt.
- Alle Texte DE und EN, Vorschauen.
- Fertig, wenn die Tests zu Seam 4 grün sind und die Vorschauen alle Zustände zeigen.

**C5, App:**
- `AppModel` baut `ReminderSync` je Sitzung und gleicht bei Start, bei `scenePhase == .active` und nach dem Einschalten ab. Abmelden und Widerruf räumen ab.
- `@UIApplicationDelegateAdaptor` mit `UNUserNotificationCenterDelegate`, `willPresent` mit Banner und Ton, Methoden `nonisolated`.
- Fertig, wenn der Simulator eine geplante Erinnerung im Vordergrund und im Hintergrund zeigt.

**C6, Hintergrund:**
- `project.yml`: `UIBackgroundModes: [fetch]`, `BGTaskSchedulerPermittedIdentifiers` mit `cloud.yuvomi.ios.reminders`.
- `.backgroundTask(.appRefresh(…))` an der Szene, nach jedem Abgleich neu angemeldet.
- Fertig, wenn der Build durchläuft. Geprüft wird der Refresh in C7 auf dem iPhone.

**C7, Abschluss:**
- Simulator gegen den lokalen Server `v2.84.0` mit Demo-Seed. Erinnerungen in der PWA anlegen, dann:
  1. Karte, Erlaubnis, Abgleich: Die Mitteilung kommt zur Zeit, im Vordergrund als Banner.
  2. Erinnerung in der PWA verschieben und löschen, App in den Vordergrund: ersetzt bzw. weg.
  3. Aufgabe in der PWA erledigen: Nach dem nächsten Abgleich ist die Mitteilung weg.
  4. Schalter aus: nichts mehr geplant. Abmelden: nichts mehr geplant.
  5. Mehr als 60 Erinnerungen im Fenster: genau die frühesten 60 sind geplant.
  6. Zeitzone des Simulators wechseln: Die Mitteilung kommt zum selben Zeitpunkt.
- Auf KlyPhone (der User): Mitteilung bei geschlossener App und gesperrtem Gerät, Wechsel der Zeitzone, Refresh per `_simulateLaunchForTaskWithIdentifier` im Debugger.
- CI grün.

## Abweichungen beim Bau (C1)

- **Kein Vergleich des Inhalts:** `ReminderSync` plant bei jedem Abgleich alles Kommende neu und entfernt nur, was der Server nicht mehr nennt. Dieselbe Kennung ersetzt die alte Mitteilung. So muss `NotificationScheduling.pending()` nur Kennungen liefern, keinen Inhalt. Der Preis: bis zu 60 Aufrufe von `add` je Abgleich.
- **Gleich fällig bleibt stehen:** Was der Server noch nennt, aber weniger als fünf Sekunden nach `now` liegt, wird nicht neu geplant und auch nicht entfernt. Sonst ginge eine schon geplante Mitteilung kurz vor ihrer Zeit verloren (Code-Review).
- **Zugestellte Mitteilungen:** Der Port hat dafür `delivered()`. `clear()` entfernt geplante und zugestellte, ein normaler Abgleich nur geplante. Sonst verschwände jede zugestellte Mitteilung beim nächsten Abgleich aus der Mitteilungszentrale.
- **Für C3 und C5 aus dem Code-Review:**
  - C3: Der Adapter lässt aus, was beim Planen schon vorbei ist, weil ein langsamer Abruf den Vorlauf von fünf Sekunden aufbrauchen kann.
  - C5: Ein Besitzer des Abgleichs je Sitzung. Er startet keinen zweiten Lauf, solange einer läuft. Abmelden bricht einen laufenden Lauf ab, bevor `clear()` läuft. Ein abgebrochener Lauf plant nichts mehr.
- **Bewusst nicht:** Platz für fremde Mitteilungen unter dem Limit (die App plant keine) und `entity_id` an der Mitteilung (erst für das Abplanen in Slice 4).

## Abweichungen beim Bau (C2)

- **Herkunft beim Lesen:** Der Adapter lässt jede Zeile außer `task` und `event` fallen, auch wenn ein Server `types` übergeht. Ein fehlender `entity_title` wird ein leerer Titel, die Mitteilung zeigt dann nur die Überschrift.
- **Aus dem Code-Review, später:** Die gekürzte Spec könnte `types` gleich auf `task` und `event` einengen und die Felder anderer Herkünfte weglassen (`scripts/prune-spec.mjs`, neuer Generatorlauf). Dann ließe sich eine andere Herkunft gar nicht erst anfragen. Nicht in diesem Slice. Für C5: Ein abgebrochener Lauf kommt als „nicht erreichbar“ zurück und darf nichts anzeigen.

## Fertig, wenn

- [ ] Eine in der Web-App gesetzte Erinnerung an eine Aufgabe und an einen Termin erscheint zur Zeit als Mitteilung, bei geschlossener App und im Vordergrund.
- [ ] Verschoben, gelöscht oder erledigt in der Web-App wirkt beim nächsten Abgleich.
- [ ] Höchstens 60 Mitteilungen sind geplant, die frühesten im Fenster von 14 Tagen.
- [ ] Ein Wechsel der Zeitzone verschiebt keine Mitteilung.
- [ ] Abmelden, Widerruf und ausgeschalteter Schalter lassen keine Mitteilung von Yuvomi zurück.
- [ ] Die Anfrage trägt immer `types=task,event`.
- [ ] Die Erlaubnis fragt die App erst über die Karte oder den Schalter, und die Einstellungen nennen Web Push und die Grenzen.
- [ ] Alle neuen Texte liegen auf Deutsch und Englisch im String Catalog, CI ist grün.
