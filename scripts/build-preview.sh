#!/bin/sh
# A self-contained UI preview. The dedicated bundle ID only launches an unprivileged dry-run
# helper with temporary fixtures; it cannot install a daemon or change live power settings.
set -eu
cd "$(dirname "$0")/.."
DESIGN_PREVIEW=false
case "${1:-}" in
    --design) DESIGN_PREVIEW=true ;;
    '') ;;
    *) echo 'Usage: scripts/build-preview.sh [--design [--run]]' >&2; exit 2 ;;
esac
if [ "$DESIGN_PREVIEW" = true ]; then
    swift build --product Tether
    DESIGN_BIN=$(swift build --show-bin-path)
    APP='build/Tether Design.app'
else
    [ -d build/Tether.app ] || { echo 'Run scripts/build.sh first' >&2; exit 1; }
    APP='build/Tether Preview.app'
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "$DESIGN_PREVIEW" = true ]; then
    mkdir -p "$APP/Contents/Frameworks"
    ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
    cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
    cp "$DESIGN_BIN/Tether" "$APP/Contents/MacOS/Tether"
else
    ditto build/Tether.app/Contents/Frameworks "$APP/Contents/Frameworks"
    cp build/Tether.app/Contents/Resources/Sparkle-LICENSE.txt "$APP/Contents/Resources/"
    cp build/Tether.app/Contents/MacOS/Tether "$APP/Contents/MacOS/Tether"
    cp build/Tether.app/Contents/Resources/tether-helper "$APP/Contents/Resources/tether-helper"
fi
if [ "$DESIGN_PREVIEW" = true ]; then
    # A clean worktree must preview the actual source icon, not a generic icon
    # or resources left behind by an unrelated production build.
    MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
    xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
        --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon \
        --output-partial-info-plist "$PWD/build/design-icon-info.plist" --output-format human-readable-text
    if [ ! -s "$APP/Contents/Resources/AppIcon.icns" ] || [ ! -s "$APP/Contents/Resources/Assets.car" ]; then
        echo 'Icon Composer did not produce both app icon files.' >&2
        exit 1
    fi
else
    for icon in Assets.car AppIcon.icns; do
        if [ -f "build/Tether.app/Contents/Resources/$icon" ]; then
            cp "build/Tether.app/Contents/Resources/$icon" "$APP/Contents/Resources/"
        fi
    done
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ "$DESIGN_PREVIEW" = true ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.jukqaz.tether.design' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Tether Design' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tether Design' "$APP/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.jukqaz.tether.preview' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Tether Preview' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tether Preview' "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$APP/Contents/Info.plist"
for lang in en ko; do mkdir -p "$APP/Contents/Resources/$lang.lproj"; done
xattr -cr "$APP"
if [ "$DESIGN_PREVIEW" = false ]; then
    codesign --force --sign - "$APP/Contents/Resources/tether-helper"
fi
codesign --force --sign - "$APP"
echo "built $APP"
if [ "$DESIGN_PREVIEW" = true ] && [ "${2:-}" = --run ]; then
    /usr/bin/open -n "$APP"
fi
