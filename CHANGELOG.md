# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Sign in to your own Yuvomi server with a password.** Enter the server's address and sign in
  with your password and, if your account uses it, two-factor authentication. The app needs
  Yuvomi v2.84.0 or newer.
- **Pair the iPhone without a password.** The Yuvomi web app shows a short pairing code, as a QR
  code to scan, a link that opens the app, or something to type in. That also works for households
  that only sign in with single sign-on. Every signed-in phone shows up in the web app and can be
  signed out from there.
- **Your tasks, read from the server.** The task list shows them as the server holds them, with
  priorities and due dates.
- **Reminders on the phone.** Upcoming reminders for tasks and events are scheduled on the device
  and arrive even while the app is closed or the phone is locked. The app refreshes them in the
  background; a switch turns them off for this phone only.
