# Entwürfe: öffentliche Position zum iOS-Client

Stand 01.11.2026, geprüft gegen `ulsklyc/yuvomi` bei `f7dbd295b` (v2.83.0). Nichts davon ist veröffentlicht oder im Server-Repo geändert. Die Texte selbst sind Englisch wie die Doku des Projekts und verwenden nach den Repo-Regeln `-` statt Gedankenstrichen.

## Reihenfolge

| Schritt | Was | Wann |
|---|---|---|
| 1 | `docs/SPEC.md`, `docs/SCOPE.md` und `docs/ROADMAP.md` anpassen | zuerst, als reiner Doku-PR |
| 2 | Kommentar auf #255 | nach dem Merge, damit er auf die Texte verweisen kann |
| 3 | `docs/DECISIONS.md`, Eintrag 18 | mit dem ersten gemergten Phase-0-Slice |

**Abweichung von unserer Absprache:** `DECISIONS.md` wandert von "vor dem Coding" zu Schritt 3. Die Einleitung der Datei sagt selbst "anything not built yet lives in its thread", und der Eintrag soll unter "Where the rule lives" echte Stellen nennen. Die Position ist durch Schritt 1 und 2 trotzdem öffentlich, bevor App-Code entsteht.

`ROADMAP.md` wird laut Kopf der Datei "on the interface train" angefasst, also am besten mit einem Mittwochs- oder Sonntags-Release. `README.md:83` und `docs/index.html` sagen "no app store" nur über die PWA. Das bleibt wahr und ändert sich nicht.

`yuvomi-ios` ist zurzeit privat, deshalb verlinkt keiner der Texte das Repo.

---

## 1. `docs/SPEC.md:3`

Heute:

> Self-hosted family planner web app for a single household (2-6 people). No app store, no public access. Deployment via Docker or Podman (rootless, SELinux-ready) on a private Linux server behind an Nginx reverse proxy with SSL.

Neu:

> Self-hosted family planner web app for a single household (2-6 people). The web app is the complete product and needs no app store; an optional native iOS client lives in its own repository and talks to the same `/api/v1` (see [SCOPE.md](SCOPE.md#where-the-line-falls-in-practice)). No public access. Deployment via Docker or Podman (rootless, SELinux-ready) on a private Linux server behind an Nginx reverse proxy with SSL.

---

## 2. `docs/SCOPE.md`, neuer Punkt unter "Where the line falls in practice"

Einfügen direkt nach dem Punkt **Health providers**:

> - **A native app** - the web app stays the complete product, and it goes on a phone without a store, an account or a build step. A Flutter rewrite to replace or sit beside it stays a "not this way" (#255): a second implementation of every feature is a second project, on a maintainer count of one. A native iOS client is the same shape as every other bridge. It lives in its own repository, talks only to `/api/v1`, needs no Yuvomi cloud and no account with anyone but the household's own server, and does what a browser cannot do on an iPhone: widgets, Shortcuts, NFC, HealthKit. It covers what is useful on a phone and links to the browser for the rest. What it does not remove is the store dependency #255 named, and that cost is taken on knowingly: the review, the yearly fee and the release cycle sit with the client and never with the server. Android has no gap of this kind today, because the web app already installs and receives push there, so there is no native Android client on the table; the API a client needs is kept free of platform-specific routes either way.

---

## 3. `docs/ROADMAP.md`, neuer Abschnitt vor "Later"

> ## A native client on iOS
>
> The things people keep asking a browser to do on an iPhone - a widget for today, a shopping list from Shortcuts, tapping an NFC tag, Apple Health - cannot be done from a browser (#255, #639, #914). The answer in [SCOPE.md](SCOPE.md#where-the-line-falls-in-practice) is a client next to Yuvomi, not a second Yuvomi.
>
> - **Decided.** SwiftUI in its own repository, against `/api/v1` only, with the web app as the complete product. A device signs in with a password or pairs through a QR code from the web app, so a household that only uses SSO is not left out. The first version has no push relay: reminders are scheduled on the phone itself, and nothing leaves the household.
> - **Open.** The server work a client needs: a device credential for every member, pairing, a way to read upcoming reminders. A push relay would be a hosted service, and that is a separate decision that has not been made.

---

## 4. Kommentar auf #255

Der Issue bleibt geschlossen: Eine Flutter-App ist weiterhin kein Plan, und die Antwort ändert nur die Position zu einem nativen Client.

> A follow-up, because part of my answer here no longer holds and I would rather say so than let it stand.
>
> The "no" to a Flutter app stays. What changed is that I closed the wider question with it. Since then, the same requests kept coming back in a form the web cannot answer: Apple Health (#639), tapping an NFC tag (#914), widgets, Shortcuts. So I am planning a native iOS client after all, in SwiftUI, in its own repository.
>
> Going through the reasons above, one at a time:
>
> - **No build step, no framework.** Unchanged. The client lives in its own repository, and nothing about Yuvomi itself changes shape.
> - **Doubling the maintenance.** Still the real cost, which is why this is not a second Yuvomi. The web app stays the complete product. The client covers what is useful on a phone and sends you to the browser for the rest, so a new feature does not have to be built twice.
> - **Self-hosting and the App Store.** This one I am accepting, not solving. The store review, the yearly fee and a second release cycle are real and they are mine to carry. What stays true is the part that matters most: the client talks only to your own server, with no Yuvomi cloud and no account with anybody else.
> - **iOS limits.** Web Push did arrive, so this one has aged as predicted. What a browser still cannot reach is the list above.
>
> A few expectations, so nobody is surprised later:
>
> - The first version has no push relay. Reminders are scheduled on the phone itself, which means a change made on another device arrives at the next refresh. A relay would be a hosted service, and that is its own decision.
> - It starts small: overview, tasks, shopping, calendar. Health and budget do not come first.
> - There is no native Android client planned. The web app already installs and gets push there, which is the gap this closes on iOS. The server side stays platform-neutral, so that door is not locked.
> - The web app stays free of any store and keeps working exactly as it does.
>
> There is no date. The direction is written down in [SCOPE.md](https://github.com/ulsklyc/yuvomi/blob/main/docs/SCOPE.md) and [ROADMAP.md](https://github.com/ulsklyc/yuvomi/blob/main/docs/ROADMAP.md), and server changes will show up in the changelog as they ship.

Hinweis: Der ursprüngliche Text sprach von "Oikos". Der Kommentar sagt bewusst "Yuvomi", ohne die Umbenennung zu erklären.

---

## 5. `docs/DECISIONS.md`, Eintrag 18 (kommt mit dem ersten Phase-0-Slice)

Die Nummer unmittelbar vor dem Merge prüfen, zurzeit endet die Datei bei 17.

> ## 18. A native client is a client, not a second app
>
> **Anything native lives outside this repository and talks only to `/api/v1`. The web app stays the complete product, and no server feature exists for one platform alone.**
>
> The question came up as a Flutter app beside the web app (#255), as a bridge to Apple Health (#639) and as tapping an NFC tag (#914), and the answer came out the same each time: the API is the contract, the bridge is a client. A native iOS client is that shape at full size. It is allowed to be useful without being complete, so a new feature is never owed twice, and it can go away without taking anything with it.
>
> What this rules out on the server is the slow version of a second app: a route only the client can use, a field shaped for one screen, or a credential with powers the web app does not have. A device credential is a person acting on their own device with their own rights. It expires after 90 days without use, like a session, it ends with the same acts that end a session, and it cannot issue another credential. Platform is a value in a field, not a code path.
>
> ### Where the rule lives
>
> - `server/auth.js`: `POST /api/v1/auth/device-tokens` and the pairing routes, in the same rule as every sign-in (`canSignIn`).
> - `apiTokenUsableSql()`: the one place that says when a credential still counts.
> - `invalidateUserSessions()`: the one way a session ends also ends the devices.
> - `test:device-tokens`, `test:device-pairing`.
>
> ### What would reopen it
>
> A need that cannot be met through `/api/v1` at all. A hosted push relay does not reopen this entry; it is a decision about running a service, and it is made in its own thread.
