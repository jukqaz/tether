#!/usr/bin/env python3
"""Check packaged arm64 code and minimum OS metadata without launching the app."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
MACHO = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError(f'invalid macOS version: {value!r}')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def code_minimum(output):
    if re.search(r'platform\s+MACOS\b', output):
        match = re.search(r'^\s*minos\s+(\S+)', output, re.MULTILINE)
    elif 'LC_VERSION_MIN_MACOSX' in output:
        match = re.search(r'^\s*version\s+(\S+)', output, re.MULTILINE)
    else:
        match = None
    if not match:
        raise ValueError('missing macOS minimum load command')
    version(match[1])
    return match[1]


def verify(app, minimum):
    maximum = version(minimum)
    contents = app / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    if version(info.get('LSMinimumSystemVersion')) != maximum:
        raise ValueError('bundle/source minimum macOS mismatch')
    for name in ('MacOS/Tether', 'Resources/tether-helper', 'Resources/tether-power-recovery', 'Helpers/tether'):
        binary = contents / name
        with binary.open('rb') as stream:
            if stream.read(4) not in MACHO:
                raise ValueError(f'not Mach-O code: {name}')
    icon = (contents / 'Resources/AppIcon.icns').read_bytes()
    if icon[:4] != b'icns' or len(icon) <= 8 or int.from_bytes(icon[4:8], 'big') != len(icon):
        raise ValueError('missing or invalid flat app icon')
    if not (contents / 'Resources/Assets.car').is_file():
        raise ValueError('missing Liquid Glass icon catalog')
    checked = []
    for path in sorted(contents.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        if path.name == 'Info.plist':
            nested = plistlib.loads(path.read_bytes())
            limit = nested.get('LSMinimumSystemVersionByArchitecture', {}).get(
                'arm64', nested.get('LSMinimumSystemVersion'))
            if limit is not None and version(limit) > maximum:
                raise ValueError(f'nested bundle requires macOS {limit}: {path}')
        with path.open('rb') as stream:
            if stream.read(4) not in MACHO:
                continue
        arches = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
        if 'arm64' not in arches:
            raise ValueError(f'missing arm64 slice: {path}')
        output = subprocess.check_output(['xcrun', 'vtool', '-show-build', '-arch', 'arm64', str(path)], text=True)
        limit = code_minimum(output)
        if version(limit) > maximum:
            raise ValueError(f'arm64 code requires macOS {limit}, advertised {minimum}: {path}')
        checked.append(dict(path=str(path.relative_to(app)), minimum_macos=limit))
    return dict(minimum_macos=minimum, architecture='arm64', binaries=checked,
                runtime_on_minimum_os_verified=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    minimum = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['LSMinimumSystemVersion']
    print(json.dumps(verify(args.app.resolve(), minimum), indent=2))
