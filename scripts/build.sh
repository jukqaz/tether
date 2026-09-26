#!/bin/sh
# Builds build/Tether.app with an ad-hoc signature (personal use; no Developer ID needed).
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product Tether
swift build -c release --product TetherHelper
swift build -c release --product TetherCLI
BIN=$(swift build -c release --show-bin-path)

APP=build/Tether.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Tether" "$APP/Contents/MacOS/Tether"
# Helpers/, not MacOS/: "tether" and "Tether" collide on a case-insensitive volume.
cp "$BIN/TetherCLI" "$APP/Contents/Helpers/tether"
cp "$BIN/TetherHelper" "$APP/Contents/Resources/tether-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/local.tether.helper.plist Resources/install-helper.sh Resources/uninstall-helper.sh Resources/Tether.icns \
  "$APP/Contents/Resources/"
# Strings live in code (English and Korean); these tell macOS which languages the app speaks.
for lang in en ko; do mkdir -p "$APP/Contents/Resources/$lang.lproj"; done

codesign --force --sign - --identifier local.tether.helper "$APP/Contents/Resources/tether-helper"
codesign --force --sign - --identifier local.tether.cli "$APP/Contents/Helpers/tether"
codesign --force --sign - "$APP"
echo "built $APP"
