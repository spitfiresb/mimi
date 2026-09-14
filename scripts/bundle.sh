#!/usr/bin/env bash
# Assemble Mimi.app from the SPM build product.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
JOBS="${JOBS:-1}"
BUNDLE_ID="com.zainsaeed.mimi"
APP="build/Mimi.app"

nice -n 15 swift build -c "$CONFIG" -j "$JOBS" --product Mimi
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Mimi"

# Quit a running copy so we can overwrite it. Note whether one was actually up,
# so we can put it back afterwards — a dead menu bar app looks identical to a
# broken hotkey, and that's a confusing half hour.
#
# Must VERIFY the kill: if an instance survives SIGTERM, `open` silently
# activates the stale copy instead of launching the new binary, and every
# "fix" after that is tested against old code.
WAS_RUNNING=0
pkill -x Mimi 2>/dev/null && WAS_RUNNING=1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
	pgrep -x Mimi >/dev/null || break
	sleep 0.3
done
if pgrep -x Mimi >/dev/null; then
	echo "Mimi survived SIGTERM; escalating"
	pkill -9 -x Mimi 2>/dev/null || true
	sleep 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Mimi"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

# Ad-hoc signing produces a new code hash every build, and TCC keys approvals
# to that hash. Stale grants are worse than missing ones: Accessibility looks
# granted but the tap never installs, and Microphone still *reports* authorized
# while coreaudiod silently delivers zero audio buffers — dictations record
# 0.0s with no error anywhere (2026-08-11). Clear both so each grant starts
# fresh and re-prompts. Per the user's standing instruction, always reset
# Accessibility when replacing/relaunching Mimi. RESET_TCC=0 only preserves
# the Microphone grant.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null
echo "reset Accessibility approval for $BUNDLE_ID"
if [ "${RESET_TCC:-1}" = "1" ]; then
	tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 \
		&& echo "reset Microphone approval for $BUNDLE_ID"
fi

echo "built $APP"

# Relaunch if it was running before, and verify the process is genuinely new —
# a stale survivor would make `open` a no-op. Set RELAUNCH=0 to skip.
if [ "$WAS_RUNNING" = "1" ] && [ "${RELAUNCH:-1}" = "1" ]; then
	open "$APP"
	sleep 1
	# Any survivor was escalated to SIGKILL and re-checked above, so a process
	# here is necessarily the new one — no age check needed.
	#
	# The age check this replaces used `ps -o etimes=`, a keyword macOS ps does
	# not have. Under `set -e` the failing substitution killed the script right
	# here, silently, so the Accessibility instructions below never printed on
	# the one run that always needs them: the one that just reset TCC.
	NEW_PID="$(pgrep -x Mimi | head -1 || true)"
	if [ -n "$NEW_PID" ]; then
		echo "relaunched Mimi (pid $NEW_PID)"
	else
		echo "WARNING: Mimi did not come back after open" >&2
	fi
fi

echo
echo "Next: System Settings > Privacy & Security > Accessibility and switch Mimi on."
if [ "${RESET_TCC:-1}" = "1" ]; then
	echo "macOS may also prompt for Microphone."
else
	echo "The existing Microphone grant was preserved."
fi
