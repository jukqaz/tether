#!/bin/sh
# Build a signed Sparkle update, its checksum and appcast. Does not publish anything.
set -eu
cd "$(dirname "$0")/.."
# Local candidate builds may be dirty; signed release preparation must use a
# reviewable commit. Reject before reading a signing key or generating artifacts.
RELEASE_SOURCE_STATUS=$(git status --porcelain)
if [ -n "$RELEASE_SOURCE_STATUS" ]; then
  printf '%s\n' 'Release preparation requires a clean source checkout. Use scripts/build.sh for a local candidate.' >&2
  exit 1
fi
: "${TETHER_SIGNING_KEY_FILE:?Set the path to the private Ed25519 key file}"
: "${SPARKLE_TOOLS_DIR:?Set the path to the official Sparkle 2.10.0 tools}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
CHANNEL=$(/usr/libexec/PlistBuddy -c "Print :TetherReleaseChannel" Resources/Info.plist)
BETA=$(/usr/libexec/PlistBuddy -c "Print :TetherBetaIteration" Resources/Info.plist)
case "${1:---$CHANNEL}" in
  --beta|--prerelease) [ "$CHANNEL" = beta ] || { echo 'Info.plist is not a beta release.' >&2; exit 2; } ;;
  --stable) [ "$CHANNEL" = stable ] || { echo 'Info.plist is not a stable release.' >&2; exit 2; } ;;
  *) echo 'Usage: scripts/release.sh [--prerelease|--stable]' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'Too many arguments.' >&2; exit 2; }
# Validate the release identity before building; it must match both app and helper.
python3 - <<'PYCODE'
import importlib.util, plistlib, re
from pathlib import Path
spec=importlib.util.spec_from_file_location('feed','scripts/update-feed.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
i=plistlib.loads(Path('Resources/Info.plist').read_bytes());m.identity(i)
s=Path('Sources/TetherCore/IPC/TetherPaths.swift').read_text()
assert re.search(r'version = "([^"\n]+)"',s)[1] == i['CFBundleShortVersionString']
assert re.search(r'build = (\d+)',s)[1] == i['CFBundleVersion']
assert i['SUFeedURL'] == m.FEED_URL
PYCODE
TAG="v$VERSION"
[ "$CHANNEL" != beta ] || TAG="$TAG-beta.$BETA"
ZIP="Tether-${TAG#v}-arm64.zip"
if [ -n "${TETHER_PREVIOUS_APPCAST:-}" ]; then
  "$SPARKLE_TOOLS_DIR/bin/sign_update" --ed-key-file "$TETHER_SIGNING_KEY_FILE" --verify "$TETHER_PREVIOUS_APPCAST"
else
  [ "${TETHER_INITIALIZE_FEED:-0}" = 1 ] || { echo 'Supply the current signed TETHER_PREVIOUS_APPCAST; only the first feed may use TETHER_INITIALIZE_FEED=1.' >&2; exit 1; }
fi
[ "$(uname -m)" = arm64 ] || { echo 'This release pipeline currently requires Apple Silicon.' >&2; exit 1; }
swift scripts/verify-update-key.swift "$TETHER_SIGNING_KEY_FILE" Resources/update-public-key.txt
sh scripts/build.sh
mkdir -p dist
rm -f "dist/$ZIP"
ditto -c -k --norsrc --keepParent build/Tether.app "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
STAGE=$(mktemp -d build/appcast-XXXXXXXX)
trap 'rm -rf "$STAGE"' 0
cp "dist/$ZIP" "$STAGE/$ZIP"
"$SPARKLE_TOOLS_DIR/bin/generate_appcast" --ed-key-file "$TETHER_SIGNING_KEY_FILE" \
  --download-url-prefix "https://github.com/jukqaz/tether/releases/download/$TAG/" \
  --link https://github.com/jukqaz/tether --maximum-deltas 0 "$STAGE"
if [ -n "${TETHER_PREVIOUS_APPCAST:-}" ]; then
  python3 scripts/update-feed.py "$STAGE/appcast.xml" dist/update-channel --previous "$TETHER_PREVIOUS_APPCAST"
else
  python3 scripts/update-feed.py "$STAGE/appcast.xml" dist/update-channel
fi
"$SPARKLE_TOOLS_DIR/bin/sign_update" --ed-key-file "$TETHER_SIGNING_KEY_FILE" dist/update-channel/appcast.xml
"$SPARKLE_TOOLS_DIR/bin/sign_update" --ed-key-file "$TETHER_SIGNING_KEY_FILE" --verify dist/update-channel/appcast.xml
cp dist/update-channel/appcast.xml dist/appcast.xml
python3 scripts/verify-release.py "dist/$ZIP" --tag "$TAG" --require-clean
printf 'Prepared %s for %s. App signing is ad-hoc, not Developer ID or notarization.\n' "$ZIP" "$TAG"
