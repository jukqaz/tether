#!/bin/sh
# Extract compiler-produced App Intents metadata into an uninstalled local build bundle.
# Usage: scripts/extract-app-intents.sh build/Tether.app [Release|Debug]
# This does not launch the app, register Shortcuts, authenticate or install anything.
set -eu
cd "$(dirname "$0")/.."

APP_INTENTS_BUNDLE=${1:?Usage: extract-app-intents.sh build/Tether.app [Release|Debug]}
APP_INTENTS_CONFIGURATION=${2:-Release}
case "$APP_INTENTS_CONFIGURATION" in Release|Debug) ;; *) echo 'Expected Release or Debug.' >&2; exit 2 ;; esac

# The helper may only write inside this checkout's local build directory.
python3 - "$APP_INTENTS_BUNDLE" <<'PY'
from pathlib import Path
import sys
root = Path.cwd().resolve()
app = Path(sys.argv[1]).resolve()
if not app.is_relative_to(root / 'build') or app.suffix != '.app' or not app.is_dir():
    raise SystemExit('App Intents extraction requires an existing uninstalled .app inside build/.')
for relative in ['Contents/MacOS/Tether', 'Contents/Info.plist', 'Contents/Resources']:
    path = app / relative
    if not path.exists() or not path.resolve().is_relative_to(app):
        raise SystemExit('The app executable, Info.plist and resources must exist inside the local bundle.')
PY
APP_INTENTS_ARCHS=$(xcrun lipo -archs "$APP_INTENTS_BUNDLE/Contents/MacOS/Tether")
case "$APP_INTENTS_ARCHS" in arm64) ;; *) echo "Unsupported metadata architecture: $APP_INTENTS_ARCHS" >&2; exit 1 ;; esac
APP_INTENTS_MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_INTENTS_BUNDLE/Contents/Info.plist")
APP_INTENTS_SDK=$(xcrun --sdk macosx --show-sdk-path)
APP_INTENTS_SWIFTC=$(xcrun --find swiftc)
APP_INTENTS_TOOLCHAIN=$(dirname "$(dirname "$(dirname "$APP_INTENTS_SWIFTC")")")
APP_INTENTS_XCODE=$(xcodebuild -version | awk '/^Build version / { print $3 }')
[ -n "$APP_INTENTS_XCODE" ] || { echo 'Could not read the Xcode build version.' >&2; exit 1; }
APP_INTENTS_STAGE=$(mktemp -d "$PWD/build/app-intents.XXXXXX")
trap 'rm -rf "$APP_INTENTS_STAGE"' 0
trap 'exit 1' 1 2 15

python3 - "$APP_INTENTS_CONFIGURATION" "$APP_INTENTS_ARCHS" "$APP_INTENTS_STAGE" <<'PY'
from pathlib import Path
import json, sys
configuration, architecture, stage = sys.argv[1:]
root = Path.cwd()
# Xcode-backed SwiftPM writes one const-values file per source in Debug and a
# whole-module file in Release. Read the output map instead of guessing filenames.
output_map = (root / '.build/out/Intermediates.noindex/Tether.build' / configuration /
              'Tether-p.build/Objects-normal' / architecture / 'Tether-OutputFileMap.json')
if not output_map.is_file():
    # Also accept classic SwiftPM's compiler output map when it provides constants.
    candidates = sorted((root / '.build').glob(f'*-apple-macosx/{configuration.lower()}/Tether.build/output-file-map.json'))
    if len(candidates) != 1:
        raise SystemExit(f'Missing unambiguous Tether compiler output map for {configuration}; build that product first.')
    output_map = candidates[0]
output = json.loads(output_map.read_text())
sources = sorted(Path(name) for name in output if name.endswith('.swift'))
constants = sorted({Path(values['const-values']) for values in output.values() if values.get('const-values')})
if not sources or not constants or any(not p.is_file() for p in sources + constants):
    raise SystemExit('Missing source or compiler constant metadata. App Intents cannot be silently omitted.')
intent_source = root / 'Sources/Tether/App/V4AppIntents.swift'
intent_constants = [p for p in constants if p.name == 'V4AppIntents.swiftconstvalues' or p.name.endswith('-primary.swiftconstvalues')]
if not intent_constants or any(p.stat().st_mtime_ns < intent_source.stat().st_mtime_ns for p in intent_constants):
    raise SystemExit('App Intents compiler constants are older than their source; rebuild Tether first.')
expected = {'Tether.TetherStartManualIntent', 'Tether.TetherControlWorkIntent', 'Tether.TetherAppShortcuts'}
found = set()
for path in constants:
    metadata = json.loads(path.read_text())
    found.update(item.get('typeName', '') for item in metadata)
if not expected.issubset(found):
    raise SystemExit('The compiler constants do not contain every Tether intent and shortcut provider. Rebuild with App Intents constant extraction enabled.')
for name, paths in [('sources.list', sources), ('constants.list', constants)]:
    if any('\n' in str(path) or '\r' in str(path) for path in paths):
        raise SystemExit('Source paths containing newlines cannot be represented in the metadata file list.')
    (Path(stage) / name).write_text(''.join(f'{path.resolve()}\n' for path in paths))
print(f'App Intents input: {len(sources)} sources, {len(constants)} compiler constant files ({configuration}).')
PY

# A fresh staging directory prevents stale metadata from masquerading as success.
APP_INTENTS_LOG="$PWD/build/app-intents-metadata.log"
if ! xcrun appintentsmetadataprocessor \
    --output "$APP_INTENTS_STAGE/output" \
    --toolchain-dir "$APP_INTENTS_TOOLCHAIN" \
    --module-name Tether \
    --sdk-root "$APP_INTENTS_SDK" \
    --xcode-version "$APP_INTENTS_XCODE" \
    --platform-family macOS \
    --deployment-target "$APP_INTENTS_MINIMUM" \
    --target-triple "$APP_INTENTS_ARCHS-apple-macosx$APP_INTENTS_MINIMUM" \
    --source-file-list "$APP_INTENTS_STAGE/sources.list" \
    --swift-const-vals-list "$APP_INTENTS_STAGE/constants.list" \
    > "$APP_INTENTS_LOG" 2>&1; then
    cat "$APP_INTENTS_LOG" >&2
    echo 'App Intents metadata extraction failed; the bundle is not ready.' >&2
    exit 1
fi
cat "$APP_INTENTS_LOG"
python3 - "$APP_INTENTS_STAGE/output/Metadata.appintents" <<'PY'
from pathlib import Path
import json, sys
metadata = Path(sys.argv[1])
actions = metadata / 'extract.actionsdata'
if not actions.is_file() or actions.stat().st_size == 0:
    raise SystemExit('Metadata extraction returned no actions. The bundle is not ready.')
document = json.loads(actions.read_text())
extracted = document.get('actions', {})
for name in ['TetherStartManualIntent', 'TetherControlWorkIntent']:
    if name not in extracted:
        raise SystemExit(f'Missing extracted action: {name}')
if not document.get('autoShortcutProviderMangledName') or len(document.get('autoShortcuts', [])) != 4:
    raise SystemExit('The extracted shortcut provider must contain all four current app shortcuts.')
if not (metadata / 'version.json').is_file():
    raise SystemExit('The App Intents metadata version file is missing.')
print('Verified two App Intents and four App Shortcuts.')
PY
APP_INTENTS_DESTINATION="$APP_INTENTS_BUNDLE/Contents/Resources/Metadata.appintents"
rm -rf "$APP_INTENTS_DESTINATION"
ditto "$APP_INTENTS_STAGE/output/Metadata.appintents" "$APP_INTENTS_DESTINATION"
echo "embedded $APP_INTENTS_DESTINATION"
