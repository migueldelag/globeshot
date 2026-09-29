#!/bin/zsh
# Builds Globe Screenshot.app, installs it to ~/Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Globe Screenshot"
APP="build/$NAME.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/GlobeScreenshot" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity so the Input Monitoring and Accessibility grants survive rebuilds.
# Defaults to the local "FXMic Dev" identity (made by ~/code/fx-mic-claude/tools/make_signing_identity.sh).
IDENTITY="${SIGN_IDENTITY:-FXMic Dev}"
FXMIC_KC="$HOME/Library/Keychains/fxmic-signing.keychain-db"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  [ -f "$HOME/.fxmic/signing-keychain.pw" ] && security unlock-keychain -p "$(cat "$HOME/.fxmic/signing-keychain.pw")" "$FXMIC_KC" 2>/dev/null || true
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "no \"$IDENTITY\" signing identity, signing ad hoc: permissions have to be granted again after every rebuild"
  codesign --force --sign - "$APP"
fi

pkill -x GlobeScreenshot && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$NAME.app"
ditto "$APP" "$HOME/Applications/$NAME.app"
open "$HOME/Applications/$NAME.app"
echo "installed and started ~/Applications/$NAME.app"
