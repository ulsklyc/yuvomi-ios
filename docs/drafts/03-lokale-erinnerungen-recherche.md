# Recherche: Lokale Erinnerungen ohne Push

Stand: 2026-11-03. Ausgangslage: Die App holt `GET /api/v1/reminders/upcoming?from&to&types=task,event` (Fenster höchstens 14 Tage, höchstens 200 Zeilen, je Zeile `fires_at` als UTC-Zeitpunkt mit `Z`, dazu id, Titel und Herkunft) und plant daraus lokale Mitteilungen. In v1 gibt es weder Push noch Relay.

**Quellenlage.** Die Context7-MCP-Tools waren in dieser Sitzung nicht verfügbar: ToolSearch fand weder `resolve-library-id` noch `query-docs`. Primärquelle ist deshalb die Apple-Dokumentation, abgerufen als DocC-JSON unter `developer.apple.com/tutorials/data/documentation/…` (Inhalt wie die Webseite unter `developer.apple.com/documentation/…`). Dazu kommen:
- die Header des iOS-27.2-SDK aus Xcode 27.2 (`UserNotifications.framework/Headers`),
- WWDC-Transkripte,
- Antworten von Apple-Mitarbeitern in den Developer Forums,
- eigene Kompilier- und Laufversuche mit Swift 6.4.2 (Xcode 27.2) im Scratchpad. Sie sind als **Versuch** gekennzeichnet.

Aussagen ohne Primärbeleg tragen die Markierung **Offen**.

Kurzformen für die Quellen-URLs: `UN/…` steht für `https://developer.apple.com/documentation/usernotifications/…`, `BG/…` für `https://developer.apple.com/documentation/backgroundtasks/…`.

---

## 1. Limit geplanter lokaler Mitteilungen

- **Die SDK-Header nennen keine Zahl.** Zu `addNotificationRequest:` heißt es: „The number of pending notification requests that may be scheduled by an application at any one time is limited by the system.“
  Quelle: iOS-27.2-SDK, `UNUserNotificationCenter.h`. Die Webdoku zu `add(_:withCompletionHandler:)` nennt ebenfalls keine Zahl (`UN/unusernotificationcenter/add(_:withcompletionhandler:)`).
- **64 ist von Apple bestätigt, allerdings im Forum.** Ein Apple Engineer schrieb im Januar 2026 auf die Frage nach `UNNotificationRequest`: „Yes, there is a limit of 64 for how many simultaneous notification requests can be active/pending at one time per app. This is a system limit and there is no way around it.“
  Quelle: https://developer.apple.com/forums/thread/811171 (akzeptierte Antwort).
  Für das aktuelle iOS ist das der jüngste Beleg. Eine iOS-Version nennt der Thread nicht. Für iOS 27 gibt es keine eigene Aussage, ein Wegfall ist aber nirgends dokumentiert.
- **Das Limit zählt Anfragen, nicht Zustellungen.** Ein wiederholender Trigger zählt als eine Anfrage, sagt Apple DTS im Oktober 2024.
  Quelle: https://developer.apple.com/forums/thread/765490
- **Was über 64 hinaus passiert, ist für die UN-API nicht dokumentiert.** Die Doku zum veralteten `UILocalNotification` sagt: „the system keeps the soonest-firing 64 notifications (with automatically rescheduled notifications counting as a single notification) and discards the rest.“
  Quelle: https://developer.apple.com/documentation/uikit/uilocalnotification
  **Offen** ist, ob `UNUserNotificationCenter` genauso verfährt (die frühesten behalten) oder neue Anfragen verwirft, und ob `add` dabei einen Fehler meldet. In keinem der Threads gibt es dazu eine Apple-Antwort.
- **Folge:** Die App darf nie mehr als 64 eigene Anfragen gleichzeitig offen haben und plant selbst die nächsten N (Vorschlag: höchstens 60, damit etwas Puffer bleibt). Der Server kann bis zu 200 Zeilen liefern. Dann greift das Limit, und die späteren Zeilen kommen erst bei einem späteren Abgleich an die Reihe.

## 2. Trigger für einen festen UTC-Zeitpunkt

### Was dokumentiert ist

- **`UNTimeIntervalNotificationTrigger`** liefert „after the amount of time you specify elapses“ und ist für Timer gedacht.
  Quelle: `UN/untimeintervalnotificationtrigger`
- **`UNCalendarNotificationTrigger`** liefert „at a specific date and time“. Man gibt nur die Komponenten an, die für den Abgleich zählen.
  Quellen: `UN/uncalendarnotificationtrigger`; Header `UNNotificationTrigger.h`: „The next date is calculated using matching date components.“
- **Zeitzonen sind für die UN-Trigger nicht dokumentiert.** Weder Typ- noch Initializer-Seite äußert sich dazu.
  Quellen: `UN/uncalendarnotificationtrigger/init(datematching:repeats:)`, `UN/uncalendarnotificationtrigger/datecomponents`
- **Der Vorgänger kannte zwei Modi.** Bei `UILocalNotification.timeZone == nil` gilt das Datum als „absolute GMT time“, passend für Countdowns. Mit gesetzter Zeitzone gilt es als Wanduhrzeit, die sich bei Zeitzonenwechseln anpasst, passend für einen Wecker.
  Quelle: https://developer.apple.com/documentation/uikit/uilocalnotification/timezone
- **Ein Apple Engineer im Forum (Januar 2026):** Ohne `timeZone` in den `DateComponents` „it will fire when the specified DateComponents match the actual time“. Mit `timeZone` „it would be expected that the trigger will be fixed to the time zone“.
  Quelle: https://developer.apple.com/forums/thread/811265
  Ein Entwickler widerspricht im selben Thread: Bei nur Stunde und Minute sei der Trigger nach einem Wechsel von PST zu MST eine Stunde verschoben gekommen. Apple hat darauf nicht geantwortet. Für Wanduhr-Wiederholungen ist das Verhalten damit **offen**. Für Yuvomi spielt es keine Rolle, siehe unten.

### Versuch

`UNCalendarNotificationTrigger` mit vollständigen Komponenten (`calendar` = gregorianisch, `timeZone` = UTC, Jahr bis Sekunde) für `2026-11-10T07:30:00Z`. Das Programm lief unter `TZ=Europe/Berlin`, `America/New_York` und `Asia/Tokyo`. `nextTriggerDate()` ergab jedes Mal exakt den Zielzeitpunkt `07:30:00 +0000`. Dieselben Komponenten ohne `timeZone`, aus `Calendar.current` erzeugt, ergaben zwar ebenfalls den Zeitpunkt, hängen aber an der Stunde der Gerätezone beim Planen (8, 2 bzw. 16). Sie würden nach einem Zonenwechsel falsch gedeutet. Ein vergangener Zeitpunkt ergibt `nextTriggerDate() == nil`.
Grenze des Versuchs: Er prüft nur die Berechnung auf macOS, keine Zustellung nach einem Zonenwechsel auf dem Gerät.

`UNTimeIntervalNotificationTrigger(timeInterval: 0 oder negativ)` bricht mit `NSInternalInconsistencyException` „time interval must be greater than 0“ ab (macOS-Lauf). Wer aus `fires_at - jetzt` ein Intervall rechnet, muss vergangene und gerade fällige Zeilen vorher aussortieren, sonst stürzt die App ab.

### Bewertung für Yuvomi

- `fires_at` ist ein absoluter Zeitpunkt. Er soll auf Reisen zum selben Moment kommen, nicht zur selben Wanduhrzeit. Beide Trigger sind dafür geeignet.
- **Empfehlung: `UNCalendarNotificationTrigger` mit vollständigen Komponenten in UTC** (`calendar` und `timeZone` explizit gesetzt, `repeats: false`). Gründe:
  1. Der Zeitpunkt steht im Trigger selbst und hängt nicht vom Moment des Planens ab.
  2. `nextTriggerDate()` lässt sich im Test gegen `fires_at` prüfen.
  3. Nach der Aussage des Apple Engineers bleibt ein Trigger mit Zeitzone an diese gebunden.
- **Offen:** Wie sich `UNTimeIntervalNotificationTrigger` verhält, wenn jemand die Systemuhr von Hand verstellt (läuft er nach Uhrzeit oder nach vergangener Zeit?). Dazu gibt es keinen Beleg.
- **Uhrumstellung (Sommerzeit):** Bei einem UTC-Zeitpunkt mit UTC-Zeitzone fällt die Umstellung nicht ins Gewicht, denn UTC kennt keine Sommerzeit. Ein Beleg für die tatsächliche Zustellung auf dem Gerät fehlt, das ist **offen**. Vorschlag: einmal auf dem Gerät mit verstellter Zeitzone prüfen. Ein Abgleich beim nächsten App-Start (Abschnitt 4) fängt Abweichungen ohnehin auf.

## 3. Ersetzen, Entfernen, idempotenter Abgleich

- **Gleiche Kennung ersetzt.** „If you use the same identifier when scheduling a new notification, the system removes the previously scheduled notification with that identifier and replaces it with the new one.“
  Quellen: `UN/unnotificationrequest/identifier`; ebenso der Header `UNUserNotificationCenter.h`. Laut Header ersetzt eine neue Anfrage mit der Kennung einer schon zugestellten Mitteilung diese beim Auslösen.
- **Entfernen:** `removePendingNotificationRequests(withIdentifiers:)` entfernt passende, noch nicht ausgelöste Anfragen. „This method executes asynchronously, removing the pending notification requests on a secondary thread.“ Die Methode hat weder Rückgabewert noch async-Variante.
  Quelle: `UN/unusernotificationcenter/removependingnotificationrequests(withidentifiers:)`
- **`removeAllPendingNotificationRequests()`** läuft ebenfalls asynchron.
  Quelle: `UN/unusernotificationcenter/removeallpendingnotificationrequests()`
- **Lesen:** `pendingNotificationRequests() async -> [UNNotificationRequest]`
  Quelle: `UN/unusernotificationcenter/getpendingnotificationrequests(completionhandler:)`
- **Reihenfolge:** „You may use the shared user notification center object simultaneously from any of your app's threads. The object processes requests serially in the order that the system initiates them.“ Ein `remove…` vor einem `add` wird demnach in dieser Reihenfolge abgearbeitet.
  Quelle: `UN/unusernotificationcenter`
- **Trigger-Typen:** Laut Doku plant man mit Kalender-, Intervall- oder Ortstrigger (`UN/scheduling-a-notification-locally-from-your-app`). Eine geplante Anfrage bleibt aktiv, bis ihr Trigger greift oder man sie entfernt (ebd., „Cancel a scheduled notification request“).

### Folgerung für einen idempotenten Abgleich

Das ist eine eigene Ableitung aus den Belegen oben.

1. **Stabile Kennung je Erinnerung.** Vorschlag: Präfix plus Server-id, etwa `reminder.<id>`. Mit dem Präfix fasst der Abgleich nur eigene Erinnerungsanfragen an. Ändert sich `fires_at`, ersetzt das erneute `add` mit derselben Kennung die alte Anfrage.
2. **Sollmenge bilden.** Zeilen mit `fires_at` in der Vergangenheit oder zu nah an „jetzt“ fallen heraus. Den Rest nach `fires_at` sortieren und die ersten N nehmen (N ≤ 64 minus andere Anfragen der App).
3. **Istmenge lesen.** `pendingNotificationRequests()`, gefiltert auf das Präfix.
4. **Diff anwenden.** Kennungen in Ist, aber nicht in Soll, entfernen. Alle Soll-Einträge per `add` planen. Ob man unveränderte Einträge überspringt (Vergleich von Titel und `nextTriggerDate`) oder einfach neu hinzufügt, ist eine Abwägung. Beides ist idempotent, weil `add` ersetzt.
5. **Nicht `removeAll` vor jedem Abgleich.** Das ginge laut Reihenfolge-Zusage zwar, entfernt aber auch künftige Nicht-Erinnerungs-Anfragen und öffnet ein Zeitfenster ohne Planung, falls der Abgleich abbricht. Der Diff vermeidet das. **Offen** bleibt, ob ein `add` direkt vor dem Auslösen eine Mitteilung verliert oder doppelt zustellt.

## 4. Wann der Abgleich ohne Push laufen kann

### Vordergrund

- `ScenePhase` liest man über `@Environment(\.scenePhase)`. Auf App-Ebene meldet es `.active`, sobald eine Szene aktiv ist. Bei `.background` soll man damit rechnen, dass die App bald beendet wird.
  Quelle: https://developer.apple.com/documentation/swiftui/scenephase
- `onChange(of:initial:_:)`: „The system may call the action closure on the main actor, so avoid long-running tasks in the closure.“
  Quelle: https://developer.apple.com/documentation/swiftui/view/onchange(of:initial:_:)
- Folge: Abgleich beim Start (`initial: true`) und bei jedem Wechsel nach `.active`. Das ist der einzige verlässliche Zeitpunkt.

### Hintergrund: `BGAppRefreshTask`

- Gedacht für „updating your app with small bits of information“. Braucht den Hintergrundmodus `fetch` in `UIBackgroundModes`.
  Quelle: `BG/bgapprefreshtask`
- **Einrichtung:**
  - Capability „Background Modes → Background fetch“.
  - Info.plist-Schlüssel `BGTaskSchedulerPermittedIdentifiers` mit den Kennungen in Reverse-DNS-Form.
  - Alle Tasks vor Ende des App-Starts registrieren. Ein erneutes `submit` ersetzt die vorige Anfrage.
  - Mit `BGTaskSchedulerPermittedIdentifiers` sind `application(_:performFetchWithCompletionHandler:)` und `setMinimumBackgroundFetchInterval(_:)` abgeschaltet.

  Quellen: https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app; https://developer.apple.com/documentation/bundleresources/information-property-list/bgtaskschedulerpermittedidentifiers
- **SwiftUI:** `.backgroundTask(.appRefresh("<id>")) { … }` (ab iOS 16). Die App gilt als fertig, sobald die async-Closure zurückkehrt. Läuft die Zeit ab, bricht das System den Task ab, beobachtbar mit `withTaskCancellationHandler`.
  Quellen: https://developer.apple.com/documentation/swiftui/scene/backgroundtask(_:action:); https://developer.apple.com/documentation/swiftui/backgroundtask/apprefresh(_:)
- **Grenzen:**
  - `earliestBeginDate` garantiert nur „won't begin sooner“, keinen Startzeitpunkt (`BG/bgtaskrequest/earliestbegindate`).
  - Höchstens **1** Refresh-Task und 10 Processing-Tasks gleichzeitig, sonst `tooManyPendingTaskRequests` (`BG/bgtaskscheduler/submit(_:)`).
  - `unavailable` tritt auf, wenn die Person die Hintergrundaktualisierung abgeschaltet hat, und im **Simulator**, der keine Hintergrundverarbeitung kann (`BG/bgtaskscheduler/error/code/unavailable`).
  - Laufzeit „up to 30 seconds“ (https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app).
  - Ohne Expiration-Handler gilt der Task als erfolglos beendet (`BG/bgtask/expirationhandler`).
  - Wer die Arbeit nicht rechtzeitig als fertig meldet, „may be quit by the system and throttled for future background task requests“ (WWDC22 „Efficiency awaits“, https://developer.apple.com/videos/play/wwdc2022/10142/).
- **Zuverlässigkeit:** „background execution isn't guaranteed. Instead, it's opportunistic, often discretionary, and tightly managed.“ Häufig genutzte Apps kommen öfter dran. Low Power Mode, Hintergrundaktualisierung und Low Data Mode beeinflussen die Planung, ebenso Netz, CPU-Last, Temperatur und Akkustand.
  Quelle: WWDC25 „Finish tasks in the background“, https://developer.apple.com/videos/play/wwdc2025/227/
- **Debuggen:** Zwischen Planen und Start können „many hours“ liegen. Auf dem **Gerät** (nicht im Simulator) startet man einen Task im Debugger mit `_simulateLaunchForTaskWithIdentifier:`. Das ist eine private Funktion und darf nicht in den App-Store-Build.
  Quelle: https://developer.apple.com/documentation/backgroundtasks/starting-and-terminating-tasks-during-development
- **Offen:** Ob eine Person, die die App im App-Umschalter wegwischt, damit auch `BGAppRefreshTask` verhindert. In den abgerufenen Primärquellen steht das nicht.

### Bewertung

Ohne Push gibt es keinen garantierten Hintergrundweg. Vordergrund-Abgleich plus `BGAppRefreshTask` als „Bonus“. Das 14-Tage-Fenster und das 64er-Limit bestimmen, wie weit die Planung bei einer länger ungeöffneten App reicht: höchstens 14 Tage und höchstens die nächsten ~60 Erinnerungen, je nachdem, was zuerst erreicht ist. Danach kommt nichts mehr, bis die App wieder läuft.

## 5. Berechtigung, provisorisch, Time Sensitive, Fokus

- **`requestAuthorization(options:) async throws -> Bool`:** Nur beim ersten Aufruf fragt das System nach, spätere Aufrufe zeigen keinen Dialog. Apple empfiehlt, im Kontext zu fragen, zum Beispiel nachdem jemand seine erste Erinnerung angelegt hat.
  Quellen: `UN/unusernotificationcenter/requestauthorization(options:completionhandler:)`, `UN/asking-permission-to-use-notifications`
- **Provisorisch (`.provisional`, ab iOS 12):** Kein Dialog. Die Mitteilungen erscheinen still nur im Mitteilungszentrum mit „Behalten/Ausschalten“. Status `UNAuthorizationStatus.provisional`. Die Anfrage darf schon beim ersten Start kommen. Vor jedem Planen den Status prüfen (`notificationSettings()`, `.authorized` oder `.provisional`).
  Quelle: `UN/asking-permission-to-use-notifications`
  Für Erinnerungen ist das heikel: Die erste Erinnerung käme ohne Banner und Ton. Das ist eine Produktentscheidung, siehe Folgen.
- **Time Sensitive:**
  - `UNNotificationInterruptionLevel.timeSensitive` (ab iOS 15) erscheint sofort, schaltet den Bildschirm ein und kann „break through system controls such as Notification Summary and Focus“. Die Person kann das abschalten.
    Quelle: `UN/unnotificationinterruptionlevel/timesensitive`
  - Bei lokalen Mitteilungen setzt man `content.interruptionLevel = .timeSensitive`. Konfiguriert wird es über eine Capability in Xcode. Critical Alerts brauchen dagegen weiter ein genehmigtes Entitlement. Durchbrechen des Fokus nur „if it has been allowed“. Sparsam einsetzen.
    Quelle: WWDC21 „Send communication and Time Sensitive notifications“, https://developer.apple.com/videos/play/wwdc2021/10091/
  - Die Autorisierungsoption `.timeSensitive` ist im SDK als `API_DEPRECATED("Use time-sensitive entitlement", ios(15.0, 15.0))` markiert. Man fragt also nicht danach, sondern braucht das Entitlement.
    Quelle: iOS-27.2-SDK, `UNUserNotificationCenter.h`
  - Den Entitlement-Schlüssel `com.apple.developer.usernotifications.time-sensitive` nennen nur Forenbeiträge und Drittquellen. Eine Referenzseite dafür fehlt in der Entitlement-Liste der Apple-Doku (**kein Primärbeleg**, Stand heute). Ein Forenbeitrag berichtet, dass es nach einem App-Update erst nach Neuinstallation griff (https://developer.apple.com/forums/thread/691183, nicht von Apple bestätigt).
  - Ob die Person Time Sensitive erlaubt hat, steht in `UNNotificationSettings.timeSensitiveSetting` (`UN/unnotificationsettings/timesensitivesetting`).
- **Fokus:** Normale Mitteilungen (`.active`) unterliegen Fokus und Zusammenfassung, Time Sensitive kann sie durchbrechen (Quellen wie oben). Mehr zur Fokus-Logik steht nicht in den Quellen.

## 6. Aktionen an Mitteilungen (z. B. „Erledigt“)

- **Kategorien:** `UNNotificationCategory` mit `UNNotificationAction`s, registriert beim Start über `setNotificationCategories(_:)`. Der Aufruf ersetzt alle früheren Kategorien. Jede Mitteilung trägt `categoryIdentifier`. Aktionskennungen müssen app-weit eindeutig sein. Bei wenig Platz zeigt das System höchstens zwei Aktionen.
  Quellen: `UN/declaring-your-actionable-notification-types`, `UN/unusernotificationcenter/setnotificationcategories(_:)`, `UN/unnotificationcategory`
- **Ohne App im Vordergrund:** „Actionable notifications let the user respond to a delivered notification without launching the corresponding app.“ Beim Tippen auf die Aktion „the system launches your app in the background“ und ruft `userNotificationCenter(_:didReceive:)` auf.
  Quellen: `UN/declaring-your-actionable-notification-types`, `UN/handling-notifications-and-notification-related-actions`
  Eine Netzanfrage aus diesem Delegate ist damit möglich: Es läuft der App-Prozess, im Hintergrund.
- **`.foreground`** holt die App nach vorn und verlangt bei Bedarf das Entsperren. Nicht nötig für „Erledigt“.
  Quelle: `UN/unnotificationactionoptions/foreground`
- **`.authenticationRequired`** führt die Aktion nur auf entsperrtem Gerät aus.
  Quelle: `UN/unnotificationactionoptions/authenticationrequired`
- **Gesperrtes Gerät:** „Users can respond to actions while the device is locked“, dann sind Dateien mit Schutzklasse `complete` nicht lesbar.
  Quelle: `UN/declaring-your-actionable-notification-types`
  Das Device Credential liegt mit `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` im Keychain (`Sources/YuvomiCore/CredentialStore.swift`). Laut Apple ist es nach dem ersten Entsperren bis zum Neustart lesbar und „recommended for items that need to be accessed by background applications“ (https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly). Nur direkt nach einem Neustart ohne Entsperren fehlt es.
- **Offen:**
  - Wie viel Laufzeit die App für `didReceive` im Hintergrund bekommt. Keine Zahl in den Quellen.
  - Ob die Anfrage bei schlechtem Netz zu Ende läuft.

  Ein Vorschlag, keine Belegaussage: Fehlgeschlagene Aktionen lokal vormerken und beim nächsten Abgleich senden. Apple empfiehlt Ähnliches für gesperrte Geräte: „save changes temporarily and integrate them into your app's data structures later“.
- **Delegate früh setzen:** Er muss vor Ende von `didFinishLaunching` gesetzt sein, sonst gehen Aktionen verloren (`UN/unusernotificationcenterdelegate`, Header `UNUserNotificationCenter.h`). In SwiftUI geht das über `@UIApplicationDelegateAdaptor` (https://developer.apple.com/documentation/swiftui/uiapplicationdelegateadaptor).
- **Serverseite:** Laut `docs/plans/phase-0-server.md` gibt es `PATCH /reminders/{id}/dismiss`. Das quittiert die Erinnerung, erledigt aber nicht die Aufgabe. Was „Erledigt“ fachlich auslöst (Erinnerung quittieren oder Aufgabe abschließen), ist **offen** und eine Produktfrage.

## 7. Swift 6: `UNUserNotificationCenter` und Delegate

- **Die UN-Header haben keine Concurrency-Annotationen**, also kein `NS_SWIFT_SENDABLE` und kein `NS_SWIFT_UI_ACTOR`. Die API-Notes enthalten nur Namensregeln, und es gibt kein Swift-Overlay (kein `.swiftinterface`).
  Quelle: iOS-27.2-SDK, `UserNotifications.framework`
  Die async-Varianten haben `@Sendable`-Completion-Handler (`add`, `pendingNotificationRequests`, `notificationSettings`, Delegate-Methoden; siehe die jeweiligen Doku-Seiten).
- **Versuch** (`swiftc -typecheck -swift-version 6`, Ziel iOS-27-Simulator, Swift 6.4.2):
  - `UNUserNotificationCenter`, `UNNotificationRequest`, `UNNotificationContent` und `UNNotificationResponse` sind **nicht Sendable** (Fehler bei einer `Sendable`-Anforderung). Der Compiler schlägt `@preconcurrency import UserNotifications` vor.
  - In einem `actor` lassen sich `UNUserNotificationCenter.current()`, `pendingNotificationRequests()` und `add(_:)` ohne Fehler aufrufen.
  - Eine `@MainActor`-Klasse mit gewöhnlicher Konformanz und async-`didReceive` ergibt einen **Fehler**: „non-Sendable parameter type 'UNNotificationResponse' cannot be sent from caller of protocol requirement … into main actor-isolated implementation“. Dasselbe gilt für `UNUserNotificationCenter`.
  - Ohne Fehler kompilieren:
    - (a) ein `nonisolated` async-`didReceive`, das Sendable-Werte herauszieht (z. B. `actionIdentifier`, Kennung) und dann zum `MainActor` wechselt;
    - (b) eine **isolierte Konformanz** `@MainActor final class D: NSObject, @MainActor UNUserNotificationCenterDelegate`;
    - (c) eine nicht isolierte `final class` ohne Zustand.
- **Isolierte Konformanzen** (`@MainActor P`) gibt es seit Swift 6.2 (SE-0470, https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md). Laut SE-0423 (Swift 6.0) prüft Swift für synchrone isolierte Funktionen, die aus nicht strikt geprüftem Code (etwa Objective-C) aufgerufen werden, die Isolation zur Laufzeit (https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md). Eine falsche Annahme über den aufrufenden Thread führt dann zum Absturz statt zu einem stillen Data Race.
- **Bekannte Stolpersteine** (Forum, nicht von Apple gelöst):
  - Swift-6-Absturz in der Queue `com.apple.usernotifications.UNUserNotificationServiceConnection.call-out` bei `@MainActor`-Delegate-Methoden mit Completion-Handler, unter Xcode 16.4 im Simulator, gemeldet als FB19519575. Ein Apple Engineer bat um Gerät-Repro, eine Ursache ist nicht dokumentiert.
    Quelle: https://developer.apple.com/forums/thread/796407
  - Die Delegate-Aufrufe kommen also **nicht zwingend auf dem Main Thread** an. Das sagen Beobachtungen im Forum, die Apple-Doku sagt dazu nichts (**offen**).
- **Empfehlung** (abgeleitet aus Versuch und Belegen):
  - Den Delegate als kleine `final class`, deren Methoden `nonisolated` und async sind.
  - Im Delegate nur Sendable-Werte herausziehen (Kennung, `actionIdentifier`, eigene Felder aus `userInfo` als `String`) und an einen Sendable-Port oder `@MainActor`-Model weiterreichen.
  - `UNNotificationResponse` nicht über Isolationsgrenzen reichen.
  - Den Planer als `actor` oder Sendable-Struct hinter einem Port. `UNUserNotificationCenter` bleibt im Adapter und tritt nicht in Sendable-Typen auf.

## 8. Testbarkeit: was hinter einen Port gehört

Das ist eine eigene Ableitung, passend zum Ports-and-Adapters-Schnitt aus `docs/plans/phase-1-slice-1.md` (Protokolle in `YuvomiCore`, Adapter außen).

- **Zeit:** ein `now`-Wert oder eine `Clock`, die man hineinreicht. Dann lassen sich Fensterränder, vergangene Zeilen und der Abstand zu „jetzt“ ohne echte Uhr testen.
- **Quelle der Erinnerungen:** z. B. `UpcomingReminderReading: Sendable` mit `func upcoming(from:to:) async throws -> [UpcomingReminder]`, Adapter in `YuvomiAPI`. Analog zu `TaskReading`.
- **Planer-Port zum System,** z. B. `LocalNotificationScheduling: Sendable` mit eigenen Sendable-Werttypen statt UN-Typen:
  - `pending() async -> [ScheduledReminder]` (Kennung, Zeitpunkt, Titel),
  - `schedule(_: [ScheduledReminder]) async throws`,
  - `remove(ids: [String]) async`,
  - `authorization() async -> NotificationAuthorization`.

  Der Adapter übersetzt in `UNNotificationRequest` und Kalendertrigger. So bleibt die gesamte Planungslogik (Filtern, Sortieren, Kappen auf N, Diff) eine reine Funktion `(soll, ist, jetzt) -> (entfernen, planen)`. Sie läuft in `swift test` ohne Simulator.
- **Den Adapter selbst** testet man dünn: ein gehosteter Test im Simulator, der plant, `pendingNotificationRequests()` liest und `nextTriggerDate()` gegen `fires_at` prüft. Lokale Mitteilungen gibt es im Simulator. `BGTaskScheduler` liefert dort dagegen `unavailable` (Abschnitt 4).
- **Aktionen:** Die Zuordnung `actionIdentifier → Befehl` (z. B. `.dismiss(id)`) als reine Funktion. Die Netzanfrage läuft über einen Port (`ReminderDismissing`), den der Delegate-Adapter aufruft.
- **Hintergrund-Einstieg:** Der Handler für `.backgroundTask(.appRefresh)` ruft nur denselben Abgleich-Use-Case auf wie der Vordergrund. Testbar ist damit der Use-Case, der Einstieg bleibt Verdrahtung.

## 9. Ausblick: Widgets und App Intents über `group.cloud.yuvomi`

Apps und Erweiterungen desselben Teams teilen über das App-Groups-Entitlement einen Container. Unter iOS findet man ihn nur über `containerURL(forSecurityApplicationGroupIdentifier:)`, das bei ungültiger Gruppe `nil` liefert. Dazu kommen `UserDefaults(suiteName:)` und eine gemeinsame Keychain Access Group (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups; https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)). Die Keychain Access Group gibt es schon (`project.yml`), die App Group laut Plan erst mit den Widgets. Ein Widget kann die zuletzt geholten Erinnerungen also aus dem gemeinsamen Container lesen. Die App stößt nach jedem Abgleich `WidgetCenter.shared.reloadTimelines(ofKind:)` an (https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date). Widgets haben ein Reload-Budget von typischerweise 40 bis 70 Aktualisierungen am Tag, Reloads mit App im Vordergrund zählen nicht (ebd.). `AppIntent` ist `Sendable` und kann in App, Erweiterung oder Paket liegen (https://developer.apple.com/documentation/appintents/appintent). Ein Intent wie „Erledigt“ im Widget könnte daher denselben Port aus `YuvomiCore` nutzen wie die Mitteilungsaktion.

---

## Folgen für den Slice-Plan

1. **Planungskern zuerst, ohne UN.** Reine Funktion in `YuvomiCore`: Zeilen filtern (`fires_at` > jetzt + kleiner Abstand), sortieren, auf N ≤ 60 kappen, Diff gegen die geplanten Einträge. Tests mit fester Zeit. Das ist der erste, simulatorfreie Teil.
2. **Ports festlegen:** `UpcomingReminderReading` (API-Adapter), `LocalNotificationScheduling` (UN-Adapter, nur eigene Sendable-Werttypen), Zeitquelle. UN-Typen verlassen den Adapter nicht.
3. **Trigger: `UNCalendarNotificationTrigger` mit vollständigen UTC-Komponenten** (`calendar` und `timeZone` gesetzt, `repeats: false`). Kennung `reminder.<id>`. Ein gehosteter Test prüft `nextTriggerDate() == fires_at`. Keine Intervalltrigger aus `fires_at - jetzt`, wegen des Absturzes bei ≤ 0.
4. **Abgleich-Zeitpunkte:** beim Start und bei jedem Wechsel nach `.active` (verlässlich), dazu `.backgroundTask(.appRefresh(…))` als Bonus. Dafür in `project.yml` `UIBackgroundModes: [fetch]` und `BGTaskSchedulerPermittedIdentifiers` ergänzen. Das Ende der Planung (14 Tage oder 60 Einträge) in den Einstellungen erklären.
5. **Berechtigung im Kontext** erfragen, etwa beim ersten Einschalten der Erinnerungen. Den Status vor jedem Abgleich prüfen. Entscheiden, ob provisorische Berechtigung gewollt ist: Sie bringt still zugestellte erste Erinnerungen und eignet sich eher nicht.
6. **Time Sensitive vorerst nicht:** Es braucht ein Entitlement oder eine Capability, deren Referenzseite fehlt. Den Nutzen für Aufgaben- und Termin-Erinnerungen gegen „sparsam einsetzen“ abwägen. Als eigener späterer Punkt führen.
7. **Delegate-Gerüst früh:** `@UIApplicationDelegateAdaptor`, Delegate in `didFinishLaunching` setzen, Methoden `nonisolated` async, nur Sendable-Werte weitergeben. `willPresent` so festlegen, dass Erinnerungen auch im Vordergrund als Banner erscheinen.
8. **Aktion „Erledigt“ als eigener Slice** nach der reinen Planung. Erst klären, ob sie `PATCH /reminders/{id}/dismiss` oder die Aufgabe abschließt. Fehlversuche lokal vormerken und beim nächsten Abgleich nachholen. Keine `.foreground`-Option.
9. **Gerätetests einplanen:** Zonenwechsel mit geplanter Erinnerung, Verhalten über 64 Anfragen, `BGAppRefreshTask` per `_simulateLaunchForTaskWithIdentifier` nur im Debugger auf dem iPhone. Im Simulator ist BackgroundTasks `unavailable`.
10. **Doppelte Zustellung mit PWA-Web-Push** (siehe `phase-0-server.md`) in den Einstellungen erklären. Der Abgleich weiß nichts von zugestellten Web-Pushes.

## Offene Punkte (gesammelt)

- Verhalten von `UNUserNotificationCenter` über 64 Anfragen: welche bleiben, ob `add` einen Fehler meldet.
- Ob das 64er-Limit unter iOS 27 noch gilt. Letzter Apple-Beleg: Forum, Januar 2026, ohne Versionsangabe.
- Zustellung eines UTC-Kalendertriggers nach Zonenwechsel und Uhrumstellung auf dem Gerät. Bisher ist nur die Berechnung belegt.
- Verhalten eines Intervalltriggers bei von Hand verstellter Systemuhr.
- `add` mit vergangenem Kalenderzeitpunkt (`nextTriggerDate() == nil`): verworfen oder sofort zugestellt?
- Hintergrund-Laufzeit für `didReceive` nach einer Aktion.
- Ob das Wegwischen im App-Umschalter `BGAppRefreshTask` verhindert.
- Primärbeleg für den Entitlement-Schlüssel von Time Sensitive.
- Auf welchem Thread bzw. in welcher Isolation UN die Delegate-Methoden aufruft.
