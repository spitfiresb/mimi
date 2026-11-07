#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from Resources/Brand/mimi-app-icon.svg.
#
# Rasterizes with headless Chrome (ImageMagick's built-in SVG renderer drops
# clip paths and filters), then downsamples with sips and packs with iconutil.
# The generated .icns is checked in, so building Mimi never needs Chrome.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SRC="Resources/Brand/mimi-app-icon.svg"
OUT="Resources/AppIcon.icns"
[ -x "$CHROME" ] || { echo "Google Chrome not found; set CHROME=/path/to/chrome" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A page that shows the SVG at exactly 1024×1024 on a transparent background.
cat > "$WORK/icon.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;background:transparent}img{display:block;width:1024px;height:1024px}</style>
<img src="file://$PWD/$SRC">
HTML

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --user-data-dir="$WORK/profile" --default-background-color=00000000 \
    --window-size=1024,1024 --allow-file-access-from-files \
    --screenshot="$WORK/icon_1024.png" "file://$WORK/icon.html" >/dev/null 2>&1

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
cp "$WORK/icon_1024.png" "${PREVIEW:-$WORK/discard.png}"
echo "wrote $OUT"
