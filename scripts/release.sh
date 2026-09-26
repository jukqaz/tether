#!/bin/sh
# Builds Tether.app and packs it for a GitHub release: dist/Tether-<version>.zip plus its SHA-256.
set -eu
cd "$(dirname "$0")/.."

sh scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Tether.app/Contents/Info.plist)
mkdir -p dist
ZIP="dist/Tether-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Tether.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "packed $ZIP"
