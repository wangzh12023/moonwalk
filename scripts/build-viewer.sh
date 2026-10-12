#!/usr/bin/env bash
# Rebuild the browser viewer (cmd/viewer, MoonBit + rabbita, JS backend) and
# store the release bundle where src/html embeds it at build time.
#
#   scripts/build-viewer.sh          # rebuild and update src/html/assets/viewer.js
#   scripts/build-viewer.sh --check  # fail if the committed bundle is stale (CI)
set -euo pipefail
cd "$(dirname "$0")/.."
moon build cmd/viewer --target js --release
JS=_build/js/release/build/cmd/viewer/viewer.js
DEST=src/html/assets/viewer.js
if [ "${1:-}" = "--check" ]; then
  if ! cmp -s "$JS" "$DEST"; then
    echo "src/html/assets/viewer.js is stale: run scripts/build-viewer.sh" >&2
    diff <(tr ';' '
' < "$DEST") <(tr ';' '
' < "$JS") | head -40 >&2 || true
    exit 1
  fi
  echo "viewer bundle is up to date"
  exit 0
fi
cp "$JS" "$DEST"
echo "updated $DEST ($(wc -c < "$DEST") bytes)"
