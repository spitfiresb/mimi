#!/usr/bin/env bash
# Build the production overlay in an isolated app with no capture dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

PREVIEW_APP="build/Mimi Glass Preview.app"
mkdir -p "$PREVIEW_APP/Contents/MacOS"
xcrun clang -fobjc-arc -c Sources/ObjCShims/MMExceptionCatcher.m -o build/GlassPreviewExceptions.o
xcrun swiftc -swift-version 5 -D GLASS_PREVIEW \
    -import-objc-header Sources/ObjCShims/include/MMExceptionCatcher.h \
    Sources/Mimi/OverlayPanel.swift Sources/Mimi/NativeGlassTuner.swift \
    tools/native-overlay-preview/main.swift \
    build/GlassPreviewExceptions.o \
    -o "$PREVIEW_APP/Contents/MacOS/MimiGlassPreview"
cat > "$PREVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>MimiGlassPreview</string>
    <key>CFBundleIdentifier</key><string>com.zainsaeed.mimi.glasspreview</string>
    <key>CFBundleName</key><string>Mimi Glass Preview</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$PREVIEW_APP"
pkill -x MimiGlassPreview 2>/dev/null || true
for _ in {1..20}; do
    pgrep -x MimiGlassPreview >/dev/null || break
    sleep 0.1
done
if pgrep -x MimiGlassPreview >/dev/null; then
    echo "The previous preview has not quit yet." >&2
    exit 1
fi
open -n "$PREVIEW_APP" --args "$@"
