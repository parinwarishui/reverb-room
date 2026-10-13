#!/bin/bash
# Builds SSH with SwiftPM and wraps it into a runnable .app (no Xcode needed).
#
#   ./build.sh          build (release), then launch
#   ./build.sh debug    the same release build, then stream the app's log lines here
#
# PERMISSION NOTE: macOS ties "System Audio Recording" permission to the app's
# code signature. Ad-hoc signing gives every rebuild a new identity, so you get
# re-prompted after each build. Fix once by creating a self-signed certificate:
#   Keychain Access › Certificate Assistant › Create a Certificate…
#   Name: SSH Dev   Identity Type: Self Signed Root   Certificate Type: Code Signing

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SSH"
BUNDLE_ID="com.yourname.stadiums-self-hosted"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ENTITLEMENTS="SSH.entitlements"
SIGN_IDENTITY_NAME="SSH Dev"

# Don't rebuild over a running copy. SIGTERM is handled by the app: it tears the
# tap down (un-muting the source) before exiting. That can take a couple of
# seconds if a pipeline is mid-build, so wait for it (up to 10 s).
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "Stopping running $APP_NAME first..."
  pkill -TERM -x "$APP_NAME" 2>/dev/null || true
  for _ in $(seq 50); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.2
  done
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "error: $APP_NAME is still running after 10 s. Quit it from the menu bar, then run this again." >&2
    exit 1
  fi
fi

echo "Compiling..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Hardened runtime: macOS then ignores DYLD_* environment variables and refuses to
# load libraries that aren't signed by Apple or by us, so no other code can be
# injected into SSH to use its system-audio permission.
SIGN_FLAGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID")

# Find the certificate by name, then sign with its SHA-1 hash. Signing by name
# fails as "ambiguous" when two certificates share it; this explains why instead.
SIGN_HASHES="$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$SIGN_IDENTITY_NAME\"" 'length($2) == 40 && $2 ~ /^[0-9A-F]+$/ && index($0, name) { print $2 }' \
  | sort -u)"
SIGN_COUNT="$(printf '%s' "$SIGN_HASHES" | grep -c . || true)"

if [[ "$SIGN_COUNT" -gt 1 ]]; then
  echo "error: found $SIGN_COUNT code-signing certificates named \"$SIGN_IDENTITY_NAME\". Delete the extra ones in Keychain Access, then run this again." >&2
  exit 1
elif [[ "$SIGN_COUNT" -eq 1 ]]; then
  echo "Signing with \"$SIGN_IDENTITY_NAME\" ($SIGN_HASHES), so the permission persists across rebuilds..."
  codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_HASHES" "$APP_BUNDLE"
else
  echo "Signing ad-hoc (no \"$SIGN_IDENTITY_NAME\" certificate found — see note at top of this script)..."
  codesign "${SIGN_FLAGS[@]}" --sign - "$APP_BUNDLE"
fi

echo "Built: $APP_BUNDLE"

# Always launch via `open`. Running the binary directly from a terminal (or from
# VS Code's debugger) makes macOS attribute audio-capture permission to the
# terminal instead of SSH.
open "$APP_BUNDLE"

if [[ "${1:-}" == "debug" ]]; then
  echo "Launched. Streaming SSH logs (Ctrl+C stops the log, not the app)..."
  echo "App and device names show as <private>; see README › Troubleshooting."
  exec log stream --style compact --predicate 'eventMessage CONTAINS "[SSH]"'
else
  echo "Launched. For logs: ./build.sh debug"
fi
