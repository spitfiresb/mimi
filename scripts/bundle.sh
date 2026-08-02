#!/usr/bin/env bash
# Assemble Mimi.app from the SPM build product.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUNDLE_ID="com.zainsaeed.mimi"
APP="build/Mimi.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Mimi"

# Quit a running copy so we can overwrite it.
pkill -x Mimi 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Mimi"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

# Ad-hoc signing produces a new code hash every build, and TCC keys Accessibility
# approval to that hash. An existing "on" toggle from a previous build is stale:
# it looks granted but isn't. Clear it so the grant starts fresh and can be
# turned on again. Set RESET_TCC=0 to skip.
if [ "${RESET_TCC:-1}" = "1" ]; then
	tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 \
		&& echo "reset Accessibility approval for $BUNDLE_ID"
fi

echo "built $APP"
echo
echo "Next: launch it, then System Settings > Privacy & Security > Accessibility"
echo "      and switch Mimi on. The toggle will be off and unchecked."
