# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Yuvomi for iOS, please report it responsibly. **Do not open a public issue.**

Instead, use [GitHub Private Vulnerability Reporting](https://github.com/ulsklyc/yuvomi-ios/security/advisories/new) to submit your report. This creates a private advisory visible only to you and the maintainer.

Include:

- Description of the vulnerability
- Steps to reproduce, with the iOS version, the device and the app build (commit or TestFlight build number)
- The Yuvomi server version you tested against
- Potential impact
- Suggested fix (if you have one)

If the problem sits in the server rather than in the app - an endpoint that hands out more than it should, a pairing code that stays valid too long - report it to the [server repository](https://github.com/ulsklyc/yuvomi/security/advisories/new) instead. When you are not sure which side it belongs to, report it here; it will be moved, not dropped.

What you can expect:

- an **acknowledgment within 7 days**;
- a **classification within 14 days** - confirmed, duplicate, or outside the [scope](#scope) below - with the reasoning.

Every advisory that is published gets a CVE requested through GitHub and names the reporter and the fixed version.

## Scope

The app is a client for a Yuvomi server that the household runs itself. The security model assumes:

- The phone is the user's own, with a passcode set and not jailbroken
- The server is reachable over HTTPS; plain HTTP is only accepted on the local network (see below)
- Whoever administers the server is trusted by the household

Out of scope, generally:

- Attacks that need an unlocked phone in hand, a jailbroken device or a debugger attached to the app
- Findings in the server or its web app - those belong in the [server repository](https://github.com/ulsklyc/yuvomi/security)
- Missing hardening in the server's TLS setup, which the operator configures

## Security Features

- **No password is stored on the phone.** Signing in with a password (and two-factor authentication, where the account has it) or redeeming a pairing code gets a device credential from the server. Only that credential is kept, in the Keychain, one entry per server address.
- **The credential stays on this device.** The Keychain entry uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in the data-protection Keychain: it goes neither into iCloud Keychain nor into a backup, and it is readable only after the phone has been unlocked once since its last restart (so background refreshes of reminders work, but a phone that was switched off and never unlocked gives nothing away).
- **Every signed-in phone is visible and revocable on the server.** It shows up in the web app and can be signed out from there. Signing out in the app deletes the credential locally first, so it always succeeds on the phone, and then asks the server to revoke it; if the server cannot be reached at that moment, the phone is still listed in the web app and can be signed out there. A credential the server has revoked is dropped by the app on its next request.
- **HTTPS everywhere, plain HTTP only on the local network.** App Transport Security is on with `NSAllowsLocalNetworking` as the only exception, for servers on `localhost`, a LAN address or a `.local` name. An address without a scheme is treated as `https`.
- **The pairing link is confirmed before it is redeemed.** `yuvomi://pair` is not an exclusive URL scheme - another app can register it too - so the app shows which server a link points to and redeems the code only after the user confirms it.
- **The app talks to one server and nothing else.** No analytics, no crash reporters, no third-party SDKs. Reminders are scheduled locally on the phone, so no push relay sees their content.
- **The camera is used for one thing.** It scans the QR code from the web app while pairing, and only while that screen is open.

## Supported Versions

Only the latest build receives security fixes. The app is in early development and not in the App Store yet; until it is, "latest" means the head of `main`.
