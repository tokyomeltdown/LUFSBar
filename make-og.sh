#!/bin/bash
# Renders og-source.html to docs/og-image.png at the size social cards crop to.
#
# Chrome rather than a screenshot tool, because the size has to be exact: a card
# that is a pixel off gets rescaled and the type goes soft.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT="$ROOT/docs/og-image.png"

[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME"; exit 1; }

# --headless writes screenshot.png into the working directory and ignores a
# path given to --screenshot in some builds, so it renders into a scratch
# directory and the result is moved.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
"$CHROME" --headless --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --window-size=1200,630 \
    --screenshot="$TMP/og-image.png" \
    "file://$ROOT/og-source.html" >/dev/null 2>&1

[ -f "$TMP/og-image.png" ] || { echo "Chrome produced no image"; exit 1; }
mv "$TMP/og-image.png" "$OUT"

sips -g pixelWidth -g pixelHeight "$OUT"
echo "wrote $OUT"
