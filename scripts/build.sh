#!/bin/sh
# Builds build/Tether.app with an ad-hoc signature (personal use; no Developer ID needed).
# Optional arguments are forwarded to every swift build, including --show-bin-path.
set -eu
cd "$(dirname "$0")/.."

swift build "$@" -c release --product Tether
swift build "$@" -c release --product TetherHelper
swift build "$@" -c release --product TetherCLI
swift build "$@" -c release --product TetherRecoveryCLI
BIN=$(swift build "$@" -c release --show-bin-path)

APP=build/Tether.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp "$BIN/Tether" "$APP/Contents/MacOS/Tether"
# Helpers/, not MacOS/: "tether" and "Tether" collide on a case-insensitive volume.
cp "$BIN/TetherCLI" "$APP/Contents/Helpers/tether"
cp "$BIN/TetherHelper" "$APP/Contents/Resources/tether-helper"
cp "$BIN/TetherRecoveryCLI" "$APP/Contents/Resources/tether-power-recovery"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Record the exact source identity. A dirty build remains useful locally, but cannot be published.
python3 - "$APP/Contents/Info.plist" <<'PY'
import os, plistlib, subprocess, sys
from pathlib import Path
p = Path(sys.argv[1]); info = plistlib.loads(p.read_bytes())
info['TetherSourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
info['TetherSourceDirty'] = bool(subprocess.check_output(['git', 'status', '--porcelain']))
# Release identity comes from the checked-in Info.plist.
if feed := os.environ.get('TETHER_UPDATE_FEED_URL'):
    info['SUFeedURL'] = feed
p.write_bytes(plistlib.dumps(info, sort_keys=False))
PY
cp Resources/local.tether.helper.plist Resources/local.tether.watchdog.plist Resources/tether-watchdog.sh Resources/tether-recovery-lock.sh \
  Resources/install-helper.sh Resources/uninstall-helper.sh "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Onboarding"
cp Resources/Onboarding/connected.png Resources/Onboarding/disconnected.png Resources/Onboarding/motion-preview.mp4 \
  "$APP/Contents/Resources/Onboarding/"
# Compile both the flat icon and Liquid Glass catalog for the source runtime minimum.
# Info.plist names both representations "AppIcon".
MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon --output-partial-info-plist build/icon-info.plist \
  --output-format human-readable-text >/dev/null
# Strings live in code (English and Korean); these tell macOS which languages the app speaks.
for lang in en ko; do mkdir -p "$APP/Contents/Resources/$lang.lproj"; done
# Required system-action metadata is extracted before signing; failure aborts packaging.
./scripts/extract-app-intents.sh "$APP" Release
python3 scripts/check-platform.py "$APP"

# Extended attributes (com.apple.provenance and the like) would ride along into the release zip.
xattr -cr "$APP"
codesign --force --sign - --identifier local.tether.helper "$APP/Contents/Resources/tether-helper"
codesign --force --sign - --identifier local.tether.power-recovery "$APP/Contents/Resources/tether-power-recovery"
codesign --force --sign - --identifier local.tether.cli "$APP/Contents/Helpers/tether"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP"
