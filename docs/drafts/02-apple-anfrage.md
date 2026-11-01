# Entwurf: Anfrage an Apple Developer Support

Stand 01.11.2026, nicht abgeschickt. Der Text geht an den Developer Support über [developer.apple.com/contact](https://developer.apple.com/contact/), angemeldet mit dem Konto, unter dem die App erscheinen soll.

Ziel ist eine schriftliche Einordnung zu Guideline 5.1.1 (ix), bevor die App eingereicht wird. Der Support kann die spätere Review-Entscheidung wahrscheinlich nicht verbindlich vorwegnehmen. Eine Antwort ist deshalb eine gute Grundlage, aber keine Garantie, und sie gehört später in die Review-Notes.

Das Zitat von 5.1.1 (ix) ist am 01.11.2026 gegen die aktuelle Guideline geprüft. Der Text nennt ausdrücklich "not by an individual developer". Offen ist also vor allem, ob ein Client für selbst gehostete Software unter "provide services" fällt und ob Familiendaten wie Termine schon als "sensitive user information" gelten. Deshalb fragt die Anfrage beides direkt.

---

**Subject:** Guideline 5.1.1(ix): client app for a self-hosted server, individual account

Hello,

I am preparing a free iOS app and would like to understand, before I submit, whether my individual developer account is the right account for it.

**What the app is.** Yuvomi is an open-source (MIT), self-hosted family planner. Each household runs it on its own server. The iOS app would be a native SwiftUI client that connects to the server address the user enters, in the same way as existing clients for Home Assistant, Nextcloud or Jellyfin.

**What I do and do not provide.**

- I publish the software. I do not operate a service, host any user data or have access to it.
- The app connects only to the user's own server. There is no server of mine in between.
- The app does not create accounts. Accounts are created by the household on its own server.
- The app is free, with no in-app purchases, no advertising and no tracking.

**What the first version contains.** Overview, tasks, shopping lists, calendar, and reminders that are scheduled locally on the device. It contains no health or financial features.

**What may come later.** The server software also has modules for health records (for example vitals and medication) and household finances (budgets, shared expenses). A later version of the app could show that data, again only between the device and the user's own server. It would not offer banking, payments, medical advice or any other regulated service, and it would not provide these as a service of mine. A later version may also read from and write to HealthKit, with the user's permission.

**My questions.**

1. Guideline 5.1.1(ix) says that "Apps that provide services in highly regulated fields (such as banking and financial services, healthcare, ...) or that require sensitive user information should be submitted by a legal entity that provides the services, and not by an individual developer." Does this apply to a client for self-hosted software like this one, where the publisher provides no service?
2. Can the first version, without health or financial features, be submitted from my individual account? It shows a family's tasks, shopping lists and calendar from their own server, and I would like to confirm that this does not count as sensitive user information in the sense of this guideline.
3. If a later version shows health or financial data from the user's own server, would that change the answer, and would it require moving the app to an organization account?

Thank you for your help.

Ulas Kalayci
