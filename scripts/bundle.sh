#!/usr/bin/env bash
# Assemble Mimi.app from the SPM build product.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUNDLE_ID="com.zainsaeed.mimi"
APP="build/Mimi.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Mimi"

# Quit a running copy so we can overwrite it. Note whether one was actually up,
# so we can put it back afterwards — a dead menu bar app looks identical to a
# broken hotkey, and that's a confusing half hour.
WAS_RUNNING=0
pkill -x Mimi 2>/dev/null && WAS_RUNNING=1 || true

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

# Relaunch if it was running before. Set RELAUNCH=0 to skip.
if [ "$WAS_RUNNING" = "1" ] && [ "${RELAUNCH:-1}" = "1" ]; then
	open "$APP"
	echo "relaunched Mimi"
fi

echo
echo "Next: System Settings > Privacy & Security > Accessibility and switch Mimi on."
echo "      The toggle will be off and unchecked — the reset above cleared it."
echo "      Until it's on, the hotkey does nothing and the menu bar reads"
echo "      \"Waiting for Accessibility permission…\"."
