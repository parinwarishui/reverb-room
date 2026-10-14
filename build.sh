#!/bin/bash
# Builds Reverb Room with SwiftPM and wraps it into an app bundle. No Xcode needed.
#
#   ./build.sh            build "build/Reverb Room.app" and open it
#   ./build.sh install    build, copy to /Applications, and open that copy
#   ./build.sh check      run the DSP self-check
#   ./build.sh logs       stream the running app's log lines
#
# macOS ties the System Audio Recording permission to the code signature. With a
# code-signing certificate named "Reverb Room Dev" in your keychain, the permission
# survives rebuilds; without one the app is signed ad hoc and asks again each time.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Reverb Room"
EXECUTABLE="ReverbRoom"
BUNDLE_ID="local.reverbroom.app"
SIGN_NAME="Reverb Room Dev"
APP="build/$APP_NAME.app"

case "${1:-}" in
  check)
    exec swift run -c release dsp-check
    ;;
  logs)
    exec log stream --style compact --predicate 'eventMessage CONTAINS "[ReverbRoom]"'
    ;;
esac

# Quit a running copy first. It handles SIGTERM by un-muting Music before exiting.
if pgrep -x "$EXECUTABLE" >/dev/null; then
  echo "Quitting the running $APP_NAME..."
  pkill -TERM -x "$EXECUTABLE" || true
  for _ in $(seq 50); do
    pgrep -x "$EXECUTABLE" >/dev/null || break
    sleep 0.2
  done
  if pgrep -x "$EXECUTABLE" >/dev/null; then
    echo "error: $APP_NAME is still running. Quit it from the menu bar and try again." >&2
    exit 1
  fi
fi

echo "Compiling..."
swift build -c release --product "$EXECUTABLE"
BIN="$(swift build -c release --show-bin-path)/$EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign by SHA-1 so two certificates with the same name give a clear error.
HASHES="$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$SIGN_NAME\"" 'length($2) == 40 && index($0, name) { print $2 }' | sort -u)"
COUNT="$(printf '%s' "$HASHES" | grep -c . || true)"
SIGN_FLAGS=(--force --options runtime --entitlements ReverbRoom.entitlements --identifier "$BUNDLE_ID")
if [[ "$COUNT" -gt 1 ]]; then
  echo "error: $COUNT certificates are named \"$SIGN_NAME\". Delete the extras in Keychain Access." >&2
  exit 1
elif [[ "$COUNT" -eq 1 ]]; then
  echo "Signing with \"$SIGN_NAME\"..."
  codesign "${SIGN_FLAGS[@]}" --sign "$HASHES" "$APP"
else
  echo "Signing ad hoc (no \"$SIGN_NAME\" certificate; macOS will re-ask for permission after each build)..."
  codesign "${SIGN_FLAGS[@]}" --sign - "$APP"
fi

TARGET="$APP"
if [[ "${1:-}" == "install" ]]; then
  TARGET="/Applications/$APP_NAME.app"
  rm -rf "$TARGET"
  ditto "$APP" "$TARGET"
  echo "Installed: $TARGET"
fi

# Always launch through `open`, so macOS attributes the audio permission to the
# app and not to the terminal.
open "$TARGET"
echo "Launched $TARGET"
