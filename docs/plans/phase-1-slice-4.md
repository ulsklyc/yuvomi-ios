# Phase 1, Slice 4: Erinnerungen zurückschreiben

Stand 04.11.2026, entschieden in einer Grilling-Runde (Q1 bis Q13). Grundlage sind der Stand nach Slice 3 ([phase-1-slice-3.md](phase-1-slice-3.md)) und die Recherche [04-erinnerungen-zurueckschreiben-recherche.md](../drafts/04-erinnerungen-zurueckschreiben-recherche.md). Der Server-Vertrag bleibt `v2.84.0` mit `client_api: 1`.

**Ziel:** Was jemand an einer Mitteilung tut, kommt beim Server an. Antippen oder Wegwischen verwirft die Erinnerung, damit die Web-App sie nicht weiter zeigt. Der Knopf „Erledigt“ an einer Aufgaben-Mitteilung hakt die Aufgabe ab und entfernt ihre übrigen Mitteilungen vom Gerät. Ohne Netz merkt sich die App die Rückmeldung und sendet sie nach.

**Nicht in diesem Slice:**
- Antippen mit Ziel. Antippen öffnet weiter die Aufgabenliste, das Ziel kommt mit der ersten Detail- oder Kalenderansicht.
- Abhaken in der Liste der App.
- Erinnerungen anlegen oder ändern, auch nicht für das nächste Vorkommen einer Serie.
- Time Sensitive, vorläufige Erlaubnis, andere Herkünfte als `task` und `event`.
- Ein Server-PR.

## Überblick

| # | Schritt | Hängt ab von |
|---|---|---|
| D1 | Kern: `entityID`, Rückmeldung, Ports, Warteschlange, Auftrag im `ReminderCoordinator` | - |
| D2 | Adapter: `YuvomiReminderWriting`, `entity_id` in `YuvomiUpcomingReminders` | D1 |
| D3 | `RemindersFeature`: Kategorien, Inhalt mit Kategorie und `userInfo`, Rückmeldung lesen, Abplanen je Aufgabe, Hinweis „Nicht abgehakt“ | D1 |
| D4 | App: Kategorien beim Start, `didReceive`, Hintergrundzeit, Verdrahtung | D2, D3 |
| D5 | Simulator- und iPhone-Lauf, CI grün | D4 |

---

## Fakten aus Server, Spec und Recherche

Ausführlich und mit Zeilen belegt in der Recherche. Kurz:

- **Verwerfen** (`PATCH /reminders/{id}/dismiss`) geht nur für eigene Erinnerungen. Fremde und unbekannte ergeben 404.
  - Die Route gehört zum Modul `calendar` und braucht dort `write`, auch bei einer Aufgaben-Erinnerung. Sonst antwortet der Server mit 403 `module_read_only` oder `module_access_denied`.
  - Ein zweites Verwerfen gibt wieder 200 **[abgeleitet]**.
  - Auch eine Erinnerung, deren Zeitpunkt noch kommt, lässt sich verwerfen. Danach fehlt sie in `/upcoming` und `/pending` und kommt nicht per Web-Push.
- **Abhaken** (`PATCH /tasks/{id}/status`, `status: done`) darf, wer die Aufgabe sieht und im Modul `tasks` schreiben darf. Das gilt auch für gesperrte Aufgaben und für Kinder mit den Startrechten.
  - Ein zweites Abhaken gibt 200 und vergibt keine zweiten Punkte und kein zweites Folgevorkommen.
  - Gelöscht oder nicht sichtbar ergibt 404.
- **`/tasks/{id}/check`** hakt eine Zeile der Checkliste ab, nicht die Aufgabe.
- **Erledigt verwirft nicht.** `/upcoming` blendet die Erinnerungen erledigter Aufgaben aus, Glocke und Web-Push prüfen den Status nicht **[abgeleitet]**. Die Spec verlangt ausdrücklich, dass ein Client seine eigene Mitteilung beim Abhaken abräumt.
- **Termine** haben keinen Status „erledigt“.
- **Serien:** Das nächste Vorkommen einer Aufgabe entsteht ohne Erinnerung.
- **Device Credential:** keine Scopes. Es gelten die Rechte der Person als Mitglied, auch für Admins.
- **Client:** `dismissReminder` und `updateTaskStatus` sind schon generiert. Neue `typeOverrides`, ein neuer Lauf von `prune-spec.mjs` und die Typen mit `unset`, `clear` und `set` sind nicht nötig.
- **iOS:**
  - Kategorien werden beim Start angemeldet. Eine Aktion startet die App im Hintergrund und landet in `didReceive`.
  - `.authenticationRequired` verlangt bei gesperrtem Gerät erst das Entsperren.
  - Wegwischen meldet iOS nur mit `.customDismissAction`.
  - Eine feste Laufzeit für Aktionen nennt Apple nicht. Mehr Zeit holt `beginBackgroundTask`.
  - In iOS 27 ist an Aktionen nichts neu, nur `appEntityIdentifiers` kam dazu.

## Entscheidungen

### Zuschnitt (Q1, Q2, Q8, Q9)

- **Verwerfen und Abhaken, kein Antippen mit Ziel (Q1).** Beides teilt Schreibweg, Fehlerbehandlung und Abplanen. Für das Ziel fehlt noch ein Screen.
- **Zwei Kategorien (Q2):** `reminder.task` mit dem Knopf „Erledigt“, `reminder.event` ohne Knopf. Eine Termin-Erinnerung wird nur verworfen. Ein „Erledigt“ am Termin verspräche etwas, das der Server nicht kennt.
- **Serien (Q8):** Die App tut nichts und verhält sich wie die Web-App.
- **Kein Server-PR (Q9):** Vertrag und `client_api` bleiben gleich. Zwei Lücken stehen unten unter „Für die Server-Spur“.

### Verwerfen und Abhaken (Q3, Q4, Q7, Q12)

- **Verwerfen (Q3):**
  - Antippen und Wegwischen verwerfen am Server, beides heißt „gesehen“. Wegwischen kommt über `.customDismissAction` an.
  - Eine Mitteilung, die ungelesen in der Mitteilungszentrale liegt, verwirft nichts.
  - Antippen öffnet die App wie bisher auf der Liste.
- **Abhaken (Q4):**
  - „Erledigt“ läuft im Hintergrund, ohne die App zu öffnen.
  - Es trägt `.authenticationRequired`: Wer das gesperrte Telefon in der Hand hält, kann nichts abhaken (Punkte, Folgevorkommen).
  - Verwerfen braucht kein Entsperren.
- **Reihenfolge beim Abhaken:**
  1. `status: done`, ohne `done_by_user_id`. Damit gelten die Zuständigen.
  2. Danach dismiss der einen Erinnerung.
  3. Lehnt der Server das Abhaken mit 403 ab, wird nicht verworfen, damit die Web-App die offene Aufgabe weiter anmahnt.
- **Aufräumen (Q7):** Auf dem Gerät fallen alle geplanten und zugestellten Mitteilungen derselben Aufgabe weg, erkannt an `entity_id` im `userInfo`. Am Server wird nur die eine Erinnerung verworfen. Wird die Aufgabe wieder geöffnet, kommen ihre übrigen Erinnerungen mit dem nächsten Abgleich zurück.
- **Knopf (Q12):** „Mark as Done“ / „Erledigt“ mit dem Symbol `checkmark`.

### Fehler (Q5, Q6, Q11)

- **Optimistisch, mit Gedächtnis (Q5):**
  - Die Mitteilung verschwindet sofort.
  - Die Rückmeldung kommt in eine Warteschlange auf dem Gerät. Die App sendet sie sofort und hält sich dafür mit `beginBackgroundTask` wach.
  - Bei einem Netzfehler oder wenn iOS die Zeit nimmt, bleibt sie liegen. Jeder Abgleich (Start, Vordergrund, Hintergrund) sendet zuerst die Warteschlange und holt erst dann die kommenden Erinnerungen. So plant er eine gerade abgehakte Aufgabe nicht wieder ein.
- **Antworten des Servers:**

  | Antwort | Folge |
  |---|---|
  | 200 | Eintrag weg |
  | keine Antwort, 5xx, unerwartet | Eintrag bleibt, nächster Abgleich |
  | 401 | Warteschlange leer, Abräumen wie in Slice 3 |
  | 403, 404 | Eintrag weg, siehe Q6 |
- **Abgelehnt (Q6):**
  - Ein 403 beim Abhaken heißt, die Aufgabe ist weiter offen. Die App plant sofort eine Mitteilung „Nicht abgehakt“ mit dem Titel der Aufgabe und einem Satz zum Grund (nur Lesen erlaubt).
  - Ein 404 bleibt still, die Aufgabe ist weg oder nicht mehr sichtbar.
  - Ein 403 beim reinen Verwerfen (Kalender nur lesend) bleibt ebenfalls still, die Web-App zeigt die Erinnerung dann eben weiter.
- **Verfall (Q11):** Eine Rückmeldung, die älter als 24 Stunden ist, fällt beim nächsten Senden still weg. Sonst könnte ein spätes Abhaken eine Aufgabe schließen, die jemand inzwischen wieder geöffnet hat.

### Module (Q10)

```
RemindersFeature ──> YuvomiCore <── YuvomiAPI
 (Kategorien,          (Rückmeldung,       (YuvomiReminderWriting,
  Rückmeldung lesen,    Ports, Warteschlange, entity_id)
  Abplanen je Aufgabe)  ReminderCoordinator)
                  App verbindet alles
```

- **Kern:**
  - `UpcomingReminder` und `PlannedNotification` bekommen `entityID`.
  - Neu ist `ReminderReply`: Erinnerung, Herkunft, `entityID`, Titel, Art (`dismiss`, `checkOff`) und Zeitpunkt.
  - Port `ReminderWriting` mit `dismiss(reminder:)` und `checkOff(task:)`.
  - Port `ReplyQueue` (lesen, ergänzen, entfernen, leeren), umgesetzt als `UserDefaultsReplyQueue`. UserDefaults sind nach dem ersten Entsperren auch bei gesperrtem Gerät lesbar.
  - `APIError` bekommt `.forbidden` und `.notFound`. Bisher fielen beide unter `.unexpectedResponse`.
- **`ReminderCoordinator` (Q10):** Er bleibt der eine Besitzer und bekommt einen dritten Auftrag `reply(Session, ReminderReply)`, in derselben strikten Reihenfolge wie Abgleich und Abräumen.
  - Ein Abgleich sendet zuerst die Warteschlange, dann folgt `ReminderSync`.
  - Abräumen nach Abmelden oder Widerruf leert auch die Warteschlange. Eine Rückmeldung für ein abgemeldetes Konto geht nie mehr raus.
  - Der ausgeschaltete Schalter räumt nur die Mitteilungen ab. Die Warteschlange bleibt, denn die Person hat schon gehandelt. Die App sendet sie beim nächsten Wechsel in den Vordergrund, auch ohne Abgleich.
- **`YuvomiAPI`:** `YuvomiReminderWriting` über die beiden generierten Operationen. Fehler werden wie bei `YuvomiTasks` eingeordnet, dazu 403 und 404.
- **`RemindersFeature`:**
  - Die Kategorien.
  - `categoryIdentifier` und `userInfo` (`reminder_id`, `entity_type`, `entity_id`, Titel) an jeder Anfrage.
  - `ReminderReply.init?(action:userInfo:now:)`, ohne UN-Typen testbar.
  - Abplanen je Aufgabe über das `userInfo` der geplanten und zugestellten Mitteilungen.
  - Die Mitteilung „Nicht abgehakt“.
  - Der Delegate (`ForegroundReminderPresenter`, umbenannt in `ReminderNotificationDelegate`) bekommt `didReceive`. Methoden `nonisolated`, `response` wird vor dem Wechsel des Actors in eine `ReminderReply` kopiert.
- **App:**
  - Kategorien in `didFinishLaunching`.
  - Rückmeldungen an `AppModel.reply(_:)` mit `beginBackgroundTask`.
  - Ist die Liste offen, lädt sie nach dem Abhaken neu.

### Tests (Q13)

Seams, vor dem ersten Test bestätigt:

1. `ReminderSync` trägt `entityID` bis in die `PlannedNotification`.
2. `ReminderCoordinator` mit Fakes für `ReminderWriting`, `ReplyQueue` und den Planer:
   - Rückmeldung vor dem Abruf.
   - Reihenfolge mit dem Abräumen (Abmelden während des Sendens).
   - 401 leert und räumt ab.
   - 403 und 404 lassen den Eintrag fallen, 403 beim Abhaken meldet.
   - Netzfehler behält den Eintrag.
   - Verfall nach 24 h.
   - Beim Abhaken erst `status`, dann dismiss, und nach 403 kein dismiss.
3. `YuvomiReminderWriting` über den Fixture-Transport mit Recorder: Methode, Pfad und Body (`{"status":"done"}`), Bearer, 200, 401 (auch ohne lesbaren Body), 403, 404 und keine Antwort.
4. `RemindersFeature`:
   - Kategorie und `userInfo` an der gebauten Anfrage.
   - Die Kategorien mit Knopf und Optionen.
   - `ReminderReply.init?(action:userInfo:now:)` für Antippen, Wegwischen und „Erledigt“, dazu fremde Kennungen und kaputtes `userInfo`.
5. `UserDefaultsReplyQueue` hin und zurück, mit eigener Suite.

Ohne Unit-Test bleiben der Delegate, `beginBackgroundTask`, die Verdrahtung und die Kategorien im System. Die prüft D5.

---

## D1 bis D5 im Einzelnen

**D1, Kern:**
- `entityID` an `UpcomingReminder` und `PlannedNotification`.
- `ReminderReply`, die Ports `ReminderWriting` und `ReplyQueue`, `UserDefaultsReplyQueue`, die neuen Fälle in `APIError`.
- Der Auftrag `reply` im `ReminderCoordinator` und das Senden der Warteschlange vor jedem Abgleich.
- Fertig, wenn die Tests zu den Seams 1, 2 und 5 grün sind.

**D2, Adapter:**
- `YuvomiReminderWriting` und `entity_id` beim Lesen in `YuvomiUpcomingReminders`.
- Fertig, wenn die Tests zu Seam 3 grün sind.

**D3, `RemindersFeature`:**
- Kategorien, Inhalt, `ReminderReply` aus der Aktion, `remove(entity:)` am Planer, Mitteilung „Nicht abgehakt“, `didReceive` im Delegate.
- Texte EN und DE im String Catalog.
- Fertig, wenn die Tests zu Seam 4 grün sind, auch mit `-testLanguage en`.

**D4, App:**
- Kategorien beim Start, Delegate an `AppModel`, Hintergrundzeit, Liste neu laden.
- Fertig, wenn im Simulator Antippen einer Mitteilung die Erinnerung am Server verwirft.

**D5, Abschluss:** Simulator gegen den lokalen Server `v2.84.0` mit Demo-Seed, emma per App-Link. Den Stand am Server per API prüfen (`/reminders/pending`, `/tasks/{id}`).
1. Mitteilung antippen: Die Erinnerung ist verworfen, die App zeigt die Liste.
2. Mitteilung wegwischen: verworfen.
3. „Erledigt“ an einer Aufgabe mit zwei Erinnerungen: Die Aufgabe ist `done`, die eine Erinnerung verworfen, die andere nicht mehr geplant.
4. Termin-Mitteilung: kein Knopf, Antippen verwirft.
5. Ohne Netz (Server gestoppt) abhaken, Server wieder starten, App in den Vordergrund: Die Rückmeldung ist nachgesendet, die Mitteilung wurde nicht wieder geplant.
6. Abhaken, während Aufgaben nur lesend erlaubt sind: Die Mitteilung „Nicht abgehakt“ erscheint.
7. Abmelden mit gemerkter Rückmeldung: Nach der nächsten Anmeldung geht nichts raus.

Auf KlyPhone: „Erledigt“ bei gesperrtem Gerät (iOS verlangt das Entsperren, danach ist die Aufgabe erledigt, ohne dass die App vorn war), dazu Wegwischen und Flugmodus mit Nachsenden.

CI grün.

## Für die Server-Spur

Nur notiert, ohne Issue (Q9). Weder Vertrag noch `client_api` sind betroffen, die App braucht beides nicht.

- **Erinnerungen an erledigte Aufgaben:** `/pending` und die Zustellung prüfen den Status der Aufgabe nicht (`services/notifications.js:598-621`), `/upcoming` schon (`routes/reminders.js:200-210`). Eine fällige, nicht verworfene Erinnerung an eine erledigte Aufgabe klingelt so in der Web-App weiter. Die App verwirft beim Abhaken nur die eine Erinnerung (Q7), spätere derselben Aufgabe bleiben am Server stehen.
- **Serien:** `spawnRecurrenceFollowup` (`routes/tasks.js:1751`) übernimmt keine Erinnerungen ins nächste Vorkommen.

## Fertig, wenn

- [ ] Antippen und Wegwischen einer Mitteilung verwerfen die Erinnerung am Server. (D5)
- [ ] „Erledigt“ hakt die Aufgabe ab, verwirft die Erinnerung und entfernt alle Mitteilungen der Aufgabe vom Gerät, auch bei gesperrtem Gerät nach dem Entsperren. (D5, iPhone)
- [ ] Termin-Mitteilungen haben keinen Knopf. (D5)
- [ ] Ohne Netz gemerkte Rückmeldungen gehen beim nächsten Abgleich raus, vor dem Abruf, und verfallen nach 24 Stunden. (Seam 2, D5)
- [ ] Abmelden und Widerruf lassen keine Rückmeldung zurück, die später gesendet wird. (Seam 2, D5)
- [ ] Ein 403 beim Abhaken erzeugt den Hinweis „Nicht abgehakt“. (Seam 2, D5)
- [ ] Alle neuen Texte liegen auf Englisch und Deutsch im String Catalog, die Suite ist in beiden Sprachen grün, CI ist grün.
