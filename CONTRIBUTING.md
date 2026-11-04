# Contributing to Yuvomi for iOS

Thanks for your interest in contributing! This app is a small, deliberately plain native client for the [Yuvomi server](https://github.com/ulsklyc/yuvomi). This guide covers what you need to know before submitting code.

Have a question or an idea before diving in? Start a thread in the [Yuvomi Discussions](https://github.com/ulsklyc/yuvomi/discussions) - the app and the server share one place for that.

---

## Hard Constraints

These are architectural decisions, not temporary limitations. The following will **not** be merged:

- **Third-party SDKs that talk to anyone but the user's server.** No analytics, crash reporting, ads or tracking of any kind. The app talks to one server, the one the user signs in to.
- **Architecture frameworks.** No TCA, no Redux-style stores. One `@Observable` model per screen is the pattern.
- **Hand-edited generated code.** `Sources/YuvomiAPI/Generated/` comes from `scripts/generate-api.sh`; CI fails if it does not match `Spec/openapi.json`.
- **A checked-in Xcode project.** `Yuvomi.xcodeproj`, `App/Info.plist` and the entitlements are generated from `project.yml` by XcodeGen. Change `project.yml` instead.
- **Features the server does not have.** The app is a client: it shows and changes what the server holds. Anything that needs new data or a new endpoint starts as a change to the [server](https://github.com/ulsklyc/yuvomi), and the app follows once a server release carries it.

New Swift package dependencies are evaluated case by case and must remain minimal. When in doubt, open an issue before writing code.

---

## Development Setup

### Prerequisites

- A Mac with **Xcode 27** (the app targets iOS 27)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A Yuvomi server **v2.84.0** or newer to sign in to - your own, or a local one from the [server repository](https://github.com/ulsklyc/yuvomi/blob/main/CONTRIBUTING.md#development-setup) on `http://localhost:3000`

### Getting started

```bash
git clone https://github.com/ulsklyc/yuvomi-ios.git
cd yuvomi-ios
xcodegen generate
open Yuvomi.xcodeproj
```

Pick an iPhone simulator and run the `Yuvomi` scheme. The simulator reaches a server on your Mac at `localhost`. Plain HTTP is accepted only on the local network (`localhost`, LAN addresses, `.local` names); anything else needs HTTPS.

To run on your own iPhone, set your development team in `project.yml` (`DEVELOPMENT_TEAM`) and generate again. Run `xcodegen generate` again after every change to `project.yml` and after adding or removing files.

### Running tests

```bash
xcodebuild test -project Yuvomi.xcodeproj -scheme Yuvomi \
  -destination "platform=iOS Simulator,name=<iPhone>" -testLanguage en
```

CI runs in English. If your Mac or simulator is set to another language, keep `-testLanguage en`, or tests that read UI text may pass for you and fail in CI.

Tests use [Swift Testing](https://developer.apple.com/documentation/testing). They run without a server: the API layer is tested against the real decoder with the recorded responses in `Fixtures/demo/`, and the feature models against the protocols in `YuvomiCore`.

### The API client

The client in `Sources/YuvomiAPI/Generated/` is generated from `Spec/openapi.json`, a pinned copy of the server's OpenAPI spec.

- `scripts/generate-api.sh` regenerates it and stops at the first generator warning.
- `scripts/update-spec.sh` pulls the spec of a newer server release tag.

A change that needs a newer server raises the minimum server version, so say so in the PR.

---

## Project Structure

```
App/                   # App entry point, wires the modules together; assets, Info.plist strings
Sources/
  YuvomiCore/          # Domain models, session, Keychain, protocols - knows nothing about HTTP
  YuvomiAPI/           # Generated client behind the core's protocols
    Generated/         # Never edit by hand
  LoginFeature/        # One SwiftUI module per area of the app
  TasksFeature/
  RemindersFeature/
  DesignSystem/        # UI pieces the screens share
Tests/                 # One test target per module
Spec/openapi.json      # Pinned server spec
Fixtures/demo/         # Recorded responses from a Yuvomi demo instance
scripts/               # Code generation and spec updates
project.yml            # XcodeGen source of the Xcode project
```

**Key patterns:**

- **Dependency direction:** feature modules -> `YuvomiCore` <- `YuvomiAPI`. The core knows neither the generator nor its runtime, and generated types never leave `YuvomiAPI`. A feature module never imports `YuvomiAPI`.
- **Fixtures are real.** `Fixtures/demo/` holds actual server responses, pulled as described in `Fixtures/README.md`. Do not write them by hand: a hand-written fixture tests what you think the server sends, not what it sends.

---

## Workflow

### 1. Find or create an issue

Before starting work, check the [existing issues](https://github.com/ulsklyc/yuvomi-ios/issues). For anything beyond a trivial fix, open an issue first to discuss the approach.

### 2. Fork and branch

```bash
# Fork on GitHub, then:
git clone https://github.com/YOUR-USERNAME/yuvomi-ios.git
cd yuvomi-ios
git remote add upstream https://github.com/ulsklyc/yuvomi-ios.git
git checkout -b fix/your-change
```

Branch prefixes: `feat/`, `fix/`, `refactor/`, `docs/`, `chore/`.

### 3. Commit

- **Subject line:** says what is true after the change, from the user's side ("reminders survive a restart of the phone"), not an order to the code. Max 72 characters, no period. A prefix like `fix:` or `feat(reminders):` is welcome but not required.
- **Body:** explain *why*, not *what* - the diff shows the what.
- One logical change per commit.

### 4. Open a pull request

- Target branch: `main`
- Link the related issue: `Closes #123` for a bug the PR fixes completely, `Refs #123` otherwise
- Keep PRs focused - one feature or fix per PR. Something that would make sense on its own (a refactor you needed along the way, a new dependency) goes in a separate PR, first.
- Screenshots for any visible change, in light and dark mode

**Before opening:**

- [ ] Tests pass with `-testLanguage en`
- [ ] `xcodegen generate` and a clean build work from a fresh checkout
- [ ] A fix carries a test that fails without it
- [ ] New UI text is in the String Catalogs, in English and German
- [ ] No change to `Sources/YuvomiAPI/Generated/` without a matching change to `Spec/openapi.json`

### 5. Review and merge

PRs are reviewed by the maintainer; expect feedback within a few days. An automated AI review (OpenAI Codex) also comments on pull requests. Its findings are informational; the maintainer's review decides. Once approved, PRs are merged by the maintainer, usually squashed into a single commit.

---

## Code Conventions

- **Swift 6 with strict concurrency.** The build has no concurrency warnings, and a new one is fixed rather than silenced.
- **One `@Observable` model per screen.** Views stay thin; logic that can be tested lives in the model or in the core.
- **UI text only through String Catalogs** (`Localizable.xcstrings`). English is the source language; every new string needs a German translation too. No hard-coded user-facing strings.
- **Accessibility:** controls have labels, layouts hold up at the largest Dynamic Type sizes, and nothing relies on color alone.
- **Hyphens, not dashes:** write `-`, never `—` or `–`, in UI text, docs, comments and commit messages.

### Testing

- Swift Testing (`@Test`, `#expect`), not XCTest.
- No network: the API layer runs against fixtures, everything above it against the core's protocols.
- Deterministic: no dependency on the wall clock, the time zone or the simulator's language - pass in what a test depends on.
- A fix is proven by a test that was red before the fix. A guard that was never seen red is not evidence.

---

## AI Assistance

**AI coding agents are used here, openly.** Much of the code in this repository was drafted with them, and an automated review comments on pull requests. Nothing reaches `main` without the maintainer deciding that it should.

**If you contribute, say so if an agent wrote it.** One line in the PR description is enough. It will not slow the review down; it tells the reviewer where to look - plausible-looking APIs that do not exist, or tests that assert what the code happens to do rather than what it should. What is expected of the contribution does not change: you understand it, and you can answer questions about it in review.

---

## Reporting Issues

### Bugs

[Open a bug report](https://github.com/ulsklyc/yuvomi-ios/issues/new/choose). The app build, the iOS version and the server version decide where to look first. If the web app shows the same problem, it is a server bug - report it in the [server repository](https://github.com/ulsklyc/yuvomi/issues/new/choose).

### Feature requests

Describe the **use case** before proposing a solution, in the [Yuvomi Discussions](https://github.com/ulsklyc/yuvomi/discussions/new?category=ideas). Many features need the server first; the discussion is where that gets sorted out.

### Security vulnerabilities

Do **not** open a public issue. Use [GitHub Private Vulnerability Reporting](https://github.com/ulsklyc/yuvomi-ios/security/advisories/new) instead. See [`SECURITY.md`](SECURITY.md) for details.

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
