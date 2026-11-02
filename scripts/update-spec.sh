#!/usr/bin/env bash
# Holt die Spec eines Server-Tags und legt die gekürzte Fassung nach Spec/openapi.json.
#
#   scripts/update-spec.sh v2.84.0
#
# Danach scripts/generate-api.sh laufen lassen und beides zusammen committen.
# Braucht Node und Netz; einen laufenden Server oder Admin-Zugang braucht es nicht.
set -euo pipefail

TAG="${1:?Aufruf: scripts/update-spec.sh <server-tag>, etwa v2.84.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Nur die Teile des Tags, die buildOpenApiSpec() und die Operationsliste brauchen.
curl -fsSL "https://codeload.github.com/ulsklyc/yuvomi/tar.gz/refs/tags/${TAG}" \
  | tar -xz -C "$WORK" --strip-components=1 \
      "yuvomi-${TAG#v}/server" "yuvomi-${TAG#v}/public" \
      "yuvomi-${TAG#v}/package.json" "yuvomi-${TAG#v}/test/openapi-client-operations.js"

node "$REPO_ROOT/scripts/prune-spec.mjs" "$WORK" > "$REPO_ROOT/Spec/openapi.json.tmp"
mv "$REPO_ROOT/Spec/openapi.json.tmp" "$REPO_ROOT/Spec/openapi.json"
echo "Spec/openapi.json aus ${TAG}: $(grep -c '"operationId"' "$REPO_ROOT/Spec/openapi.json") Operationen"
