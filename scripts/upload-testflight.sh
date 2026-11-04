#!/usr/bin/env bash
# Baut einen Commit von origin/main und lädt ihn zu App Store Connect (TestFlight) hoch.
#
#   scripts/upload-testflight.sh <commit-sha> [--dry-run]
#
# Gebaut wird immer in einem frischen, temporären git worktree genau an <commit-sha>, nie
# aus dem Arbeitsverzeichnis. Ablauf in drei Schritten:
#   1. xcodegen generate, xcodebuild archive (Release, generic/platform=iOS)
#   2. xcodebuild -exportArchive mit scripts/ExportOptions.plist (destination export) zu .ipa
#   3. xcrun altool --upload-package lädt die .ipa mit einem App-Store-Connect-API-Key hoch
# Version und Build-Nummer kommen aus project.yml des Build-Commits; sie werden nicht
# hochgezählt (manageAppVersionAndBuildNumber false), das passiert per Commit.
#
# --dry-run: Schritte 1 und 2, ohne Upload und ohne API-Key. Die .ipa bleibt in einem
# temporären Verzeichnis liegen, der Pfad wird ausgegeben.
#
# Signieren (Schritte 1 und 2) passiert lokal und ohne API-Key: automatische Signierung über
# das in Xcode (Settings -> Accounts) angemeldete Konto und das Zertifikat "Apple Distribution"
# im Schlüsselbund. -allowProvisioningUpdates erlaubt xcodebuild, mit diesem Konto fehlende
# Profile zu laden oder anzulegen (laut `xcodebuild -help` reicht dafür ein in Xcode
# angemeldetes Konto, ein Key ist nicht nötig). Ohne den Schalter klappt der Export nur,
# wenn das App-Store-Profil schon lokal liegt.
#
# Schlüsselbund: Beim ersten Signieren fragt macOS, ob codesign den privaten Schlüssel von
# "Apple Distribution" benutzen darf. Dort "Immer erlauben" wählen (mit dem Anmeldepasswort
# des Macs), sonst hängt der Export, bis jemand den Dialog bestätigt.
#
# Upload (Schritt 3) per App-Store-Connect-API-Key aus der Umgebung:
#   ASC_KEY_ID      Key-ID
#   ASC_ISSUER_ID   Issuer-ID
#   ASC_KEY_PATH    optional, Default ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8,
#                   wird an altool als --p8-file-path übergeben
# Key-Inhalt, Key-ID und Issuer-ID gibt das Skript nie aus. Deshalb kein `set -x`, und die
# altool-Ausgabe läuft durch einen Filter, der diese Werte schwärzt.
#
# Warum ein Key mit Rolle Developer reicht (geprüft am 2026-11-04):
# - Der Key wird nur für den Upload benutzt, nicht für Zertifikate oder Profile.
# - Builds hochladen dürfen Account Holder, Admin, App Manager und Developer, Quelle:
#   https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
#   (nennt altool, Transporter, Xcode und die App Store Connect API als Wege).
# - altool-Aufruf laut `xcrun altool --help` (altool 27.10.4, Xcode 27.2):
#   `altool --upload-package <file> --api-key <id> --api-issuer <id>`, Key-Datei per
#   `--p8-file-path`; ohne diese Option sucht altool AuthKey_<id>.p8 unter anderem in
#   ~/.appstoreconnect/private_keys. --upload-app gibt es noch, --upload-package ist der
#   Weg aus den Beispielen der Hilfe.
set -euo pipefail

usage() {
  echo "Aufruf: scripts/upload-testflight.sh <commit-sha> [--dry-run]" >&2
  exit 2
}

SHA_ARG=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) usage ;;
    *) [[ -z "$SHA_ARG" ]] || usage; SHA_ARG="$arg" ;;
  esac
done
[[ -n "$SHA_ARG" ]] || usage

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
cd "$REPO_ROOT"

KEYCHAIN_HINT='Hinweis: Hängt oder scheitert das Signieren, wartet vermutlich ein Schlüsselbund-Dialog
("codesign möchte auf den Schlüssel ... zugreifen"). Dort "Immer erlauben" für den privaten
Schlüssel von "Apple Distribution" wählen. Außerdem muss in Xcode -> Settings -> Accounts das
Konto des Teams angemeldet sein.'

# --- API-Key (nur für den Upload, vor dem Bauen prüfen) -------------------------------
KEY_PATH=""
REDACT=()
if [[ "$DRY_RUN" -eq 0 ]]; then
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
    cat >&2 <<'MSG'
Abbruch: ASC_KEY_ID und ASC_ISSUER_ID sind nicht gesetzt.

So legt man den Key einmalig an:
  1. App Store Connect -> Users and Access -> Integrations -> App Store Connect API
     -> Team Keys -> "+" (beim ersten Mal muss der Account Holder den API-Zugang anfragen).
  2. Name frei, Rolle "Developer" (reicht für den Upload, signiert wird lokal, siehe Kopf
     dieses Skripts).
  3. AuthKey_<KEY_ID>.p8 herunterladen (geht nur einmal) und ablegen unter
     ~/.appstoreconnect/private_keys/ (chmod 600), nie ins Repo.
  4. Key-ID und Issuer-ID (oben auf der Seite) exportieren, etwa in ~/.zshrc:
       export ASC_KEY_ID=...
       export ASC_ISSUER_ID=...
     Optional ASC_KEY_PATH, wenn die .p8 woanders liegt.
Ein Probelauf ohne Key geht mit --dry-run.
MSG
    exit 1
  fi
  KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  if [[ ! -r "$KEY_PATH" ]]; then
    echo "Abbruch: Die Key-Datei aus ASC_KEY_PATH bzw. dem Default-Pfad ist nicht lesbar." >&2
    exit 1
  fi
  REDACT=("$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH")
fi

# Schreibt Werkzeug-Ausgabe weiter, mit geschwärzten Key-Werten.
redact() {
  if [[ ${#REDACT[@]} -eq 0 ]]; then
    cat
    return
  fi
  perl -pe 'BEGIN { @v = map { quotemeta } splice(@ARGV); } for my $x (@v) { s/$x/<geschwärzt>/g }' "${REDACT[@]}"
}

# --- Commit prüfen -------------------------------------------------------------------
git fetch --quiet origin main
if ! SHA="$(git rev-parse --verify --quiet "${SHA_ARG}^{commit}")"; then
  echo "Abbruch: $SHA_ARG ist kein bekannter Commit." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$SHA" origin/main; then
  echo "Abbruch: $SHA ist nicht auf origin/main erreichbar." >&2
  exit 1
fi

# --- Temporärer Worktree -------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/yuvomi-testflight.XXXXXX")"
BUILD_TREE="$WORK/src"
cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$BUILD_TREE" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Worktree an $SHA"
git worktree add --quiet --detach "$BUILD_TREE" "$SHA"

echo "==> xcodegen generate"
(cd "$BUILD_TREE" && xcodegen generate --quiet)

# --- 1. Archiv -----------------------------------------------------------------------
ARCHIVE="$WORK/Yuvomi.xcarchive"
echo "==> xcodebuild archive (signiert lokal; bei Schlüsselbund-Dialog \"Immer erlauben\")"
if ! xcodebuild archive \
  -project "$BUILD_TREE/Yuvomi.xcodeproj" \
  -scheme Yuvomi \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK/DerivedData" \
  -allowProvisioningUpdates; then
  echo "Abbruch: xcodebuild archive ist gescheitert." >&2
  echo "$KEYCHAIN_HINT" >&2
  exit 1
fi

APP_PLIST="$ARCHIVE/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$APP_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$APP_PLIST")"

# --- 2. Export -----------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  # Liegt außerhalb von $WORK, damit die .ipa das Aufräumen übersteht.
  EXPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yuvomi-ipa.XXXXXX")"
else
  EXPORT_DIR="$WORK/export"
fi

echo "==> xcodebuild -exportArchive (signiert mit Apple Distribution; bei Schlüsselbund-Dialog \"Immer erlauben\")"
if ! xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates; then
  echo "Abbruch: xcodebuild -exportArchive ist gescheitert." >&2
  echo "$KEYCHAIN_HINT" >&2
  exit 1
fi

IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "$IPA" ]]; then
  echo "Abbruch: Der Export hat keine .ipa erzeugt." >&2
  exit 1
fi

# --- 3. Upload -----------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "==> xcrun altool --upload-package"
  if ! xcrun altool --upload-package "$IPA" \
    --api-key "$ASC_KEY_ID" \
    --api-issuer "$ASC_ISSUER_ID" \
    --p8-file-path "$KEY_PATH" \
    --output-format normal \
    2>&1 | redact; then
    echo "Abbruch: Der Upload mit altool ist gescheitert (Key-Rolle mindestens Developer, App in" >&2
    echo "App Store Connect angelegt, Build-Nummer noch nicht vergeben?)." >&2
    exit 1
  fi
fi

echo
echo "Commit:  $SHA"
echo "Version: $VERSION"
echo "Build:   $BUILD"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "IPA:     $IPA"
  echo "Probelauf: nichts hochgeladen."
else
  echo "Hochgeladen. Die Verarbeitung in App Store Connect dauert danach noch einige Minuten."
fi
