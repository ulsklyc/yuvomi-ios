<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="Yuvomi app icon" width="92" />

  <h1>Yuvomi for iOS</h1>

  <p><strong>Your family's Yuvomi, native on the iPhone.<br>It talks to your own server and nothing else.</strong></p>

  <p>
    The companion app for <a href="https://github.com/ulsklyc/yuvomi">Yuvomi</a>, the self-hosted
    family planner. Sign in to the server your household runs, see your tasks and get reminders
    on the phone, even when the app is closed.
  </p>

  <p>
    <img src="https://img.shields.io/badge/status-early%20development-6C3AED?style=flat-square" alt="Status: early development">
    <img src="https://img.shields.io/badge/iOS-27%2B-6C3AED?style=flat-square" alt="Requires iOS 27 or later">
    <img src="https://img.shields.io/badge/Swift-6-6C3AED?style=flat-square" alt="Swift 6">
    <a href="https://github.com/ulsklyc/yuvomi-ios/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ulsklyc/yuvomi-ios/ci.yml?branch=main&style=flat-square&color=6C3AED&label=CI" alt="CI status"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-6C3AED?style=flat-square" alt="MIT license"></a>
  </p>

  <p>
    <a href="https://github.com/ulsklyc/yuvomi"><strong>→ Yuvomi server</strong></a>&nbsp;&nbsp;·&nbsp;
    <a href="https://yuvomi.cloud/"><strong>yuvomi.cloud</strong></a>&nbsp;&nbsp;·&nbsp;
    <a href="#build-from-source">Build from source</a>&nbsp;&nbsp;·&nbsp;
    <a href="README.de.md" hreflang="de">Auf&nbsp;Deutsch</a>
  </p>

  <p><b>1</b>&nbsp;server,&nbsp;yours&nbsp;&nbsp;·&nbsp; <b>0</b>&nbsp;trackers&nbsp;&nbsp;·&nbsp; <b>0</b>&nbsp;in-app&nbsp;purchases&nbsp;&nbsp;·&nbsp; <b>2</b>&nbsp;languages</p>
</div>

The web app of Yuvomi already goes on every home screen, straight from the browser. This app is
for the things a native app does better on an iPhone: signing in by scanning a code, and reminders
that the phone schedules itself, so they arrive on time without a push relay.

---

## What it does today

- **Sign in to your own server.** Enter its address and sign in with your password and, if your
  account uses it, two-factor authentication.
- **Or pair without a password.** The Yuvomi web app shows a short pairing code, as a QR code, a
  link that opens the app, or something to type in. That also works for households that only sign
  in with single sign-on. Every signed-in phone shows up in the web app and can be signed out
  from there.
- **Your tasks**, read from the server as they are, with priorities and due dates.
- **Reminders on the phone.** Upcoming reminders for tasks and events are scheduled on the device
  and arrive even while the app is closed or the phone is locked. The app refreshes them in the
  background; a switch turns them off for this phone only.

The PWA stays the full Yuvomi. The app grows step by step, and anything it cannot do yet is one
tap away in the browser.

## Questions

**Which server do I need?** Yuvomi **v2.84.0** or newer, reachable from the phone. The app only
ever talks to the server you sign in to: no account with us, no analytics, no third-party SDKs.

**Which iPhones?** Any iPhone that runs iOS 27. Older devices keep using the web app.

**Where do I get it?** Not in the App Store yet. The app is in early development and heads for
TestFlight first. Until then you can [build it yourself](#build-from-source).

**What does it cost?** Nothing. Free, MIT-licensed, no in-app purchases.

---

## Build from source

You need a Mac with **Xcode 27** and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml` and not checked in.

```bash
git clone https://github.com/ulsklyc/yuvomi-ios.git
cd yuvomi-ios
xcodegen generate
open Yuvomi.xcodeproj
```

Pick an iPhone simulator and run the `Yuvomi` scheme. To run on your own iPhone, set your
development team in `project.yml` (`DEVELOPMENT_TEAM`) and generate again.

<details>
<summary><b>Tests, the API client and the demo data</b></summary>

<br>

- **Tests** run in the simulator, the same way CI runs them:
  `xcodebuild test -project Yuvomi.xcodeproj -scheme Yuvomi -destination "platform=iOS Simulator,name=<iPhone>"`.
  CI runs in English; add `-testLanguage en` to match it locally.
- **The API client** in `Sources/YuvomiAPI/Generated/` is generated from `Spec/openapi.json`, a
  pinned copy of the server's OpenAPI spec. Never edit it by hand: run `scripts/generate-api.sh`,
  which stops at the first generator warning. `scripts/update-spec.sh` pulls the spec of a newer
  server release. CI fails if the checked-in client does not match the spec.
- **`Fixtures/demo/`** holds real responses from a Yuvomi demo instance. Previews and tests decode
  them with the real decoder; see `Fixtures/README.md` for how they are pulled.

</details>

<details>
<summary><b>How the code is organised</b></summary>

<br>

| Module | What it holds |
|---|---|
| `YuvomiCore` | Domain models, the session, the Keychain and the protocols everything else implements. Knows nothing about HTTP. |
| `YuvomiAPI` | The generated client behind the core's protocols. Generated types never leave this module. |
| `LoginFeature`, `TasksFeature`, `RemindersFeature` | One SwiftUI module per area of the app. |
| `DesignSystem` | UI pieces the screens share, so far the label that explains a problem. |
| `App/` | Wires the modules together. |

Swift 6 with strict concurrency, one `@Observable` model per screen, tests with Swift Testing.
Texts live in String Catalogs, English first, German alongside.

</details>

---

## License

MIT, like Yuvomi itself. See [LICENSE](LICENSE).

Want to help? Start with [CONTRIBUTING.md](CONTRIBUTING.md). Security issues are reported privately as described in [SECURITY.md](SECURITY.md), and [PRIVACY.md](PRIVACY.md) explains what the app does with your data.
