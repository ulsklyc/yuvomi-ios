#!/usr/bin/env bash
# Erzeugt den API-Client aus Spec/openapi.json nach Sources/YuvomiAPI/Generated/.
#
#   scripts/generate-api.sh
#
# Bricht bei jeder Generator-Warnung ab. Im Spike vom 02.11.2026 war eine Warnung das
# einzige Zeichen dafür, dass Eigenschaften still aus den Modellen fielen.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Sources/YuvomiAPI/Generated"
CONFIG="$REPO_ROOT/Sources/YuvomiAPI/openapi-generator-config.yaml"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

swift build --package-path "$REPO_ROOT/Tools" --product swift-openapi-generator -c release >/dev/null

mkdir -p "$OUT"
"$REPO_ROOT/Tools/.build/release/swift-openapi-generator" generate \
  --config "$CONFIG" \
  --output-directory "$OUT" \
  "$REPO_ROOT/Spec/openapi.json" 2>&1 | tee "$LOG"

if grep -qi "warning" "$LOG"; then
  echo "Abbruch: Der Generator hat Warnungen gemeldet (siehe oben)." >&2
  exit 1
fi
