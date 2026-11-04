# Erinnerungen zurückschreiben: Recherche für Slice 4

Stand 04.11.2026. Grundlage für das Grilling zu [phase-1-slice-4.md](../plans/phase-1-slice-4.md). Der Server-Teil gilt für den Tag `v2.84.0` (`client_api: 1`) und wurde nur gelesen. Die Apple-Belege stammen aus der Doku über Sosumi und aus den Headern des iOS-SDK 27.2 in Xcode.

## 1. Mitteilungs-Aktionen (UserNotifications)

- **Kategorien beim Start.** Aktionen hängen an einer `UNNotificationCategory`, und die App muss ihre Kategorien beim Start mit `setNotificationCategories(_:)` anmelden. Jede Aktion braucht eine Kennung, die über alle Kategorien eindeutig ist, denn nur an ihr erkennt die App die Aktion. Eine lokale Mitteilung bekommt ihre Kategorie über `categoryIdentifier` am Inhalt. Quelle: „Declaring your actionable notification types“.
- **Ausführung.** Wählt jemand eine Aktion, startet iOS die App im Hintergrund und ruft `userNotificationCenter(_:didReceive:)` am Delegate auf. Seit iOS 15 gibt es dafür eine `async`-Variante. Ohne diese Methode reagiert die App auf keine eigene Aktion. Am Ende muss der Completion Handler laufen; bei der `async`-Variante ist das die Rückkehr aus der Methode.
- **Optionen je Aktion** (`UNNotificationActionOptions`):
  - `.foreground` bringt die App in den Vordergrund.
  - `.authenticationRequired` heißt: Bei gesperrtem Gerät verlangt iOS zuerst das Entsperren und meldet die Aktion erst danach an die App.
  - `.destructive` hebt den Knopf rot hervor. Ein Doppeltippen auf der Apple Watch (Series 9, Ultra 2) löst die erste Aktion ohne `.destructive` aus.
- **Gesperrtes Gerät.** Laut Apple kann eine Aktion ohne `.authenticationRequired` bei gesperrtem Gerät laufen. Dateien mit dem Schutz `complete` sind dann nicht lesbar. Das Device Credential liegt mit `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` im Keychain (Slice 1) und ist nach dem ersten Entsperren seit dem Neustart lesbar, also auch bei gesperrtem Gerät.
- **Antippen und Wegwischen.** Antippen ohne Knopf kommt als `UNNotificationDefaultActionIdentifier` an und öffnet die App. Wegwischen meldet iOS nur mit der Kategorie-Option `.customDismissAction`, dann als `UNNotificationDismissActionIdentifier`.
- **Laufzeit im Hintergrund.** Apple nennt keine feste Zeit für eine Aktion im Hintergrund. Zusätzliche Zeit holt `UIApplication.beginBackgroundTask(withName:expirationHandler:)`. Wie viel es ist, sagt `backgroundTimeRemaining`, und vor Ablauf ruft iOS den Expiration Handler. Wer die Aufgabe nicht beendet, wird beendet. Apple rät, den Aufruf so früh wie möglich zu setzen. Für mehr Zeit verweist die Doku auf Background Tasks. Folge: Ein Netzaufruf aus `didReceive` ist nicht garantiert fertig. Wer ihn nicht verlieren will, merkt ihn sich auf dem Gerät und schickt ihn später nach.
- **Neu in iOS 27:** An `UNNotificationAction`, `UNNotificationCategory` und am Delegate ändert sich nichts. Das SDK 27.2 bringt nur `UNMutableNotificationContent.appEntityIdentifiers` (Overlay `_UserNotifications_AppIntents`). Damit lässt sich eine Mitteilung mit App-Intents-Entitäten verknüpfen. Für Slice 4 ist das nicht nötig.
- **Swift 6:** Wie in Slice 3: Die UN-Typen sind nicht `Sendable`, deshalb müssen die Delegate-Methoden `nonisolated` sein. Was aus `response` gebraucht wird (Kennung der Aktion, `userInfo`), wird vor jedem Wechsel des Actors in eigene `Sendable`-Werte kopiert.

## 2. Server (`v2.84.0`, nur gelesen)

Alle Zeilen gelten für `v2.84.0`. **[abgeleitet]** markiert, was aus dem Code folgt, aber von keinem Test belegt ist.

### `PATCH /api/v1/reminders/{id}/dismiss`

Handler: `server/routes/reminders.js:705-735`.

- **Nur die eigene Zeile.**
  - Die Abfrage ist `WHERE id = ? AND created_by = ?`. Eine fremde oder unbekannte Erinnerung ergibt 404, auch für Admins (`test-reminders-routes.js:461`).
  - Eine an einen Termin vererbte Erinnerung (`assigned_from`) ist eine eigene Zeile der zugewiesenen Person, die sie damit selbst verwerfen kann.
  - Ob die Person die Aufgabe oder den Termin noch sieht, prüft dismiss nicht.
- **Zwei Rechte-Prüfungen:**
  1. `/reminders` gehört zum Modul `calendar` (`server/scopes.js:29`), und PATCH braucht `write`. Bei `read` kommt 403 `module_read_only`, bei `none` 403 `module_access_denied` (`server/index.js:775-783`). **[abgeleitet]** Wer im Kalender nur lesen darf, kann auch eine Aufgaben-Erinnerung nicht verwerfen.
  2. `mayTouchOrigin(…, 'write')` ordnet die Herkunft einem Modul zu, `task` → `tasks` und `event` → `calendar`. Die Prüfung schlägt nur bei `none` an und antwortet dann mit 403 `module_access_denied`.
- **Idempotent [abgeleitet]:** Die Abfrage filtert nicht nach `dismissed`, ein zweiter Aufruf gibt wieder 200 `{data:{id}}`. Dazu kommt der allgemeine `Idempotency-Key`.
- **Gelöscht:** Trigger löschen die Erinnerungen einer gelöschten Aufgabe oder eines gelöschten Termins (`server/db.js:11371-11378`). Danach antwortet dismiss mit 404.
- **Auch vorab:** Eine Erinnerung, deren Zeitpunkt noch kommt, lässt sich verwerfen. Danach fehlt sie in `/upcoming` und `/pending` (`test-reminders-upcoming.js:206`).
- **Wirkung:** Web-Push und Kanäle stellen nur `dismissed = 0 AND pushed_at IS NULL` zu (`services/notifications.js:598`). Die Glocke der PWA (`/pending`) liest dieselbe Bedingung.
- **Nicht endgültig:** Verschiebt jemand einen Termin in die Zukunft (Inbound-Sync, neue Uhrzeit), setzt der Server `dismissed = 0` wieder (`services/calendar-occurrence-overrides.js:2388-2405`).
- **Tests:** `test-reminders-routes.js:451, 456, 461, 472, 575`, `test-reminders-upcoming.js:206`, `test-push.js:487`, `test-openapi-client-responses.js:266`. Kein Test deckt ein zweites dismiss oder ein Device Credential an dieser Route ab.

### `PATCH /api/v1/tasks/{id}/status`

Handler: `server/routes/tasks.js:1893-2073`. Der Body ist `{status, done_by_user_id?}`.

- **Wer darf:** wer die Aufgabe sieht (`mayAccessTask`): bei `visibility='all'` alle, sonst die Ersteller:in und die Zuständigen. Wer sie nicht sieht, bekommt 404 `tasks_task_not_found`. Auf einer gesperrten Aufgabe ist Abhaken ausdrücklich erlaubt (`test-task-lock.js:168`).
- **Modulrecht:** Nötig ist `tasks: write`. Bei `read` kommt 403 `module_read_only`, bei `none` 403 `module_access_denied`.
- **Kinder:** Die Startrechte der Rolle `child` lassen `tasks` und `calendar` auf `write` (`server/permissions.js:250-273`). Ein Admin hat auf dem Gerät nur die Rechte eines Mitglieds (`permissions.js:830-832`).
- **Schon erledigt:** 200. Punkte, Verlauf und das nächste Vorkommen hängen nur am Übergang nach `done` (`test-tasks-recurrence.js:287`, `test-rewards.js:79`). Doppeltes Abhaken schadet also nicht.
- **Gelöscht:** 404. **Abgelegt:** keine Sperre, `archived_at` ist eine eigene Achse.
- **Antwort:** `{data:{id, status, archived_at, next_due_date}}`.
- **Tests:** `test-tasks-routes.js:261, 268, 877, 920`, `test-tasks-recurrence.js:257-287`, `test-task-lock.js:168`.

### `PATCH /api/v1/tasks/{id}/check`

Hakt eine Zeile `- [ ]` der Checkliste in `description` ab (`tasks.js:2131-2179`). Status, Punkte und Serie bleiben unberührt. Für „Erledigt“ an der Mitteilung ist die Route also nicht gedacht.

### Erledigt und Erinnerung

- **Kein automatisches Verwerfen:** `routes/tasks.js` fasst die Tabelle `reminders` nicht an. Die Erinnerung einer erledigten Aufgabe bleibt bestehen. `/upcoming` blendet sie aus, solange die Aufgabe erledigt oder abgelegt ist, und zeigt sie nach dem Wiederöffnen wieder (`reminders.js:200-210`, `test-reminders-upcoming.js:213`).
- **[abgeleitet]** `/pending` und Web-Push prüfen den Status nicht. Ist eine erledigte Aufgabe fällig und ihre Erinnerung nicht verworfen, klingelt die PWA trotzdem. Wer abhakt und Glocke und Web-Push stillhalten will, muss zusätzlich verwerfen.
- **Laut Spec** (`/reminders/upcoming`): „A client still has to cancel its own notification when a task is checked off, because this list only changes at the next fetch.“
- **Serien:** Beim Abhaken einer wiederkehrenden Aufgabe entsteht ein neues Vorkommen mit neuer id, aber ohne Erinnerung (`spawnRecurrenceFollowup`, `tasks.js:1751`). Eine Termin-Erinnerung hängt am ersten Vorkommen und feuert einmal **[abgeleitet]**.
- **Termine** kennen keinen Status „erledigt“. Es gibt weder ein Feld noch eine Route dafür.

### Device Credential und Rechte

Ein Device Credential hat keine Scopes, es gelten die Rechte der Person als Mitglied (`server/auth.js:1091-1095`, `3317-3320`). Rechte gibt es je Modul (`none`, `read`, `write`), je Rolle oder je Person. Ohne Eintrag gilt `write`.

### Unterschied zu `v2.85.0`

`v2.85.0` ändert weder dismiss noch den Status-Handler noch die Rechte. Neu sind der Filter für gelöschte erste Vorkommen (#2495) und die Rotation bei Aufgabenserien (#2372). Erinnerungen werden auch dort nicht in das nächste Vorkommen übernommen.

## 3. Generierter Client

- `dismissReminder` und `updateTaskStatus` sind schon generiert, beide unter den 39 Operationen.
- `TaskStatusInput` braucht keinen `typeOverride`. Aus `done_by_user_id` (`integer | null`) wird `Int?` und fällt bei `nil` weg. Die App lässt das Feld weg, damit gelten die Zuständigen.
- Mit `unset`, `clear` und `set` hat Slice 4 deshalb weiterhin nichts zu tun.
- Ein neuer Lauf über `scripts/prune-spec.mjs` ist nicht nötig.
- Ein Fixture für die Antworten fehlt. Die Tests der Adapter brauchen Antworten für dismiss und status: einmal 200, dazu 401, 403, 404 und keine Antwort.

## 4. Was daraus für die App folgt

- `UpcomingReminder` braucht `entity_id` (Pflicht in der Spec), damit die Mitteilung weiß, welche Aufgabe sie abhakt und welche sie öffnet.
- „Erledigt“ an einer Aufgabe heißt zwei Aufrufe: `status: done`, dann dismiss. Das zweite hält PWA und Web-Push still. Für Termine bleibt nur dismiss.
- Ein 403 bei dismiss ist für ein Mitglied mit `calendar: read` erreichbar, auch bei einer Aufgabe. Ein 404 heißt: gelöscht oder nicht (mehr) sichtbar. Beides ist endgültig, ein Wiederholen bringt nichts.
- Weil beide Aufrufe idempotent sind, darf die App bei Netzfehlern bedenkenlos wiederholen.
