# Privacy Policy

This policy covers **Yuvomi for iOS**, the native app for a [Yuvomi](https://github.com/ulsklyc/yuvomi)
server that a household runs itself. It describes what the app does with data, as the code in this
repository implements it.

## In short

The app talks to one server: the one you enter when you sign in. It sends nothing to the project,
to the maintainer or to anyone else. There is no account with the project, no analytics, no crash
reporting, no advertising and no tracking, and the app contains no third-party SDKs.

## The server you sign in to

Everything the app shows - your tasks, upcoming reminders - comes from that server, and everything
it sends goes there:

- **When you sign in**, your username and password and, if your account uses it, the
  two-factor code; or, when you pair, the pairing code. Together with that, the app sends the
  device name "iPhone", the platform "ios" and an identifier that iOS assigns to the app on this
  phone (`identifierForVendor`), so the phone can be listed and signed out in the web app.
- **While you use the app**, the requests it needs to show your data, authenticated with the
  device credential the server issued.
- **When you answer a reminder notification**: tapping or swiping it away tells the server to
  dismiss that reminder, and "Mark as Done" on a task reminder sets that task to done.

What that server stores, for how long and who can see it is decided by whoever runs it - usually
your own household, not this project. Questions about that data go to the server's operator.

Plain HTTP is only accepted for servers on the local network (`localhost`, LAN addresses,
`.local` names); anything else needs HTTPS.

## On the phone

- **The device credential.** The app does not store your password. It keeps only the credential
  the server issued, in the iOS Keychain, with the setting
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: it stays on this device and goes neither
  into iCloud Keychain nor into a backup. Signing out deletes it from the phone and asks the
  server to revoke it.
- **Settings.** The address of your server and whether reminders are on for this phone are kept
  in the app's own settings on the device.
- **Reminders** are scheduled as local notifications on the phone, with the title of the task or
  event they belong to. The app uses no push service, so no relay sees their content.
- **Answers not yet sent.** When you answer a notification, the app first notes the answer in its
  own settings on the device, so it survives a restart and a lost connection. An entry holds
  whether the reminder was dismissed or the task checked off, the IDs of the reminder and of its
  task or event, the title of the task or event and the time you answered. An entry is removed
  once the server has it, when the server refuses it, or after 24 hours unsent.
- **Signing out** removes all of Yuvomi's scheduled and delivered notifications from the phone,
  forgets answers not yet sent and cancels the background refresh. The same happens when the
  server has revoked the phone's credential. Turning reminders off in the app removes the
  notifications too, but answers already given are still sent.

## Permissions

- **Camera** - only to scan the QR code from the Yuvomi web app while pairing, and only while that
  screen is open. The app neither stores nor sends images.
- **Notifications** - to show reminders. You can turn them off in the app for this phone, or in
  the iOS Settings.
- **Background App Refresh** - to refresh upcoming reminders from your server while the app is
  closed. It contacts no one but that server.

## Who is responsible

The app is an open-source project maintained by [@ulsklyc](https://github.com/ulsklyc) on GitHub.
The project itself operates no server and receives no data from the app. For data on a Yuvomi
server, the person or household running that server is responsible.

Questions about this policy can be raised privately through
[GitHub Private Vulnerability Reporting](https://github.com/ulsklyc/yuvomi-ios/security/advisories/new)
in this repository.

## Changes

Changes to this policy are made in this file; its history in the repository shows every change.
