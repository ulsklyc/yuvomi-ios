#!/usr/bin/env bash
# Baut einen Commit von origin/main und lädt ihn zu App Store Connect (TestFlight) hoch.
#
#   scripts/upload-testflight.sh <commit-sha> [--dry-run]
#
# Gebaut wird immer in einem frischen, temporären git worktree genau an <commit-sha>, nie
# aus dem Arbeitsverzeichnis. Ablauf: xcodegen generate, xcodebuild archive (Release,
# generic/platform=iOS), xcodebuild -exportArchive mit scripts/ExportOptions.plist.
# Version und Build-Nummer kommen aus project.yml des Build-Commits; sie werden nicht
# hochgezählt (manageAppVersionAndBuildNumber false), das passiert per Commit.
#
# --dry-run: exportiert die .ipa nur lokal in ein temporäres Verzeichnis (destination
# export) und gibt den Pfad aus. Der API-Key ist dafür nicht nötig; ist er gesetzt, wird er
# zum Signieren benutzt, sonst die in Xcode angemeldeten Accounts.
#
# Anmeldung für den Upload per App-Store-Connect-API-Key aus der Umgebung:
#   ASC_KEY_ID      Key-ID
#   ASC_ISSUER_ID   Issuer-ID
#   ASC_KEY_PATH    optional, Default ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
# Key-Inhalt, Key-ID und Issuer-ID gibt das Skript nie aus. Deshalb kein `set -x`, und die
# xcodebuild-Ausgabe läuft durch einen Filter, weil xcodebuild seine Kommandozeile mitloggt.
#
# Welche Rolle der Key braucht (geprüft am 2026-11-04):
# - Nur hochladen dürfen Account Holder, Admin, App Manager und Developer, Quelle:
#   https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
# - Dieses Skript signiert beim Export aber per Cloud-Signing (-allowProvisioningUpdates):
#   xcodebuild legt dabei ein cloud-verwaltetes Verteilungszertifikat und ein App-Store-
#   Profil an. Laut https://developer.apple.com/help/account/access/roles darf das ohne
#   Zusatzrechte nur Admin (oder Account Holder). App Manager braucht dafür zusätzlich
#   "Access to Certificates, Identifiers & Profiles" und das Recht für cloud-verwaltete
#   Zertifikate, Developer darf Distribution-Profile gar nicht anlegen. Diese Zusatzrechte
#   vergibt Users and Access an Personen, ein Team-Key hat nur seine Rolle.
# => Kleinste Rolle, mit der dieses Skript zuverlässig läuft: Admin.
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

# --- API-Key -------------------------------------------------------------------------
KEY_ARGS=()
REDACT=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  if [[ ! -r "$KEY_PATH" ]]; then
    echo "Abbruch: Die Key-Datei aus ASC_KEY_PATH bzw. dem Default-Pfad ist nicht lesbar." >&2
    exit 1
  fi
  KEY_ARGS=(-authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
            -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  REDACT=("$ASC_KEY_ID" "$ASC_ISSUER_ID" "$KEY_PATH")
elif [[ "$DRY_RUN" -eq 0 ]]; then
  cat >&2 <<'EOF'
Abbruch: ASC_KEY_ID und ASC_ISSUER_ID sind nicht gesetzt.

So legt man den Key einmalig an:
  1. App Store Connect -> Users and Access -> Integrations -> App Store Connect API
     -> Team Keys -> "+" (beim ersten Mal muss der Account Holder den API-Zugang anfragen).
  2. Name frei, Rolle "Admin" (kleinste Rolle, mit der Cloud-Signing beim Export klappt,
     siehe Kopf dieses Skripts).
  3. AuthKey_<KEY_ID>.p8 herunterladen (geht nur einmal) und ablegen unter
     ~/.appstoreconnect/private_keys/ (chmod 600), nie ins Repo.
  4. Key-ID und Issuer-ID (oben auf der Seite) exportieren, etwa in ~/.zshrc:
       export ASC_KEY_ID=...
       export ASC_ISSUER_ID=...
     Optional ASC_KEY_PATH, wenn die .p8 woanders liegt.
EOF
  exit 1
fi

# Schreibt xcodebuild-Ausgabe weiter, mit geschwärzten Key-Werten.
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

ARCHIVE="$WORK/Yuvomi.xcarchive"
echo "==> xcodebuild archive"
xcodebuild archive \
  -project "$BUILD_TREE/Yuvomi.xcodeproj" \
  -scheme Yuvomi \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK/DerivedData" \
  -allowProvisioningUpdates \
  ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
  2>&1 | redact

APP_PLIST="$ARCHIVE/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$APP_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$APP_PLIST")"

OPTIONS="$WORK/ExportOptions.plist"
cp "$EXPORT_OPTIONS" "$OPTIONS"
if [[ "$DRY_RUN" -eq 1 ]]; then
  plutil -replace destination -string export "$OPTIONS"
  # Liegt außerhalb von $WORK, damit die .ipa das Aufräumen übersteht.
  EXPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yuvomi-ipa.XXXXXX")"
else
  EXPORT_DIR="$WORK/export"
fi

echo "==> xcodebuild -exportArchive ($([[ "$DRY_RUN" -eq 1 ]] && echo "export, Probelauf" || echo upload))"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
  2>&1 | redact

echo
echo "Commit:  $SHA"
echo "Version: $VERSION"
echo "Build:   $BUILD"
if [[ "$DRY_RUN" -eq 1 ]]; then
  IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
  if [[ -z "$IPA" ]]; then
    echo "Abbruch: Der Export hat keine .ipa erzeugt." >&2
    exit 1
  fi
  echo "IPA:     $IPA"
else
  echo "Hochgeladen. Die Verarbeitung in App Store Connect dauert danach noch einige Minuten."
fi
