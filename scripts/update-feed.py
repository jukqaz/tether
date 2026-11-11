#!/usr/bin/env python3
"""Build a stable-only appcast from a new item and previously verified release history.
The caller verifies the previous feed before invoking this script and signs the result after.
Historical beta items are ordering evidence only and never enter the new feed.
"""
import argparse
import json
import plistlib
import re
from pathlib import Path
import xml.etree.ElementTree as ET

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
S = '{' + NS + '}'
ET.register_namespace('sparkle', NS)
REPO = 'https://github.com/jukqaz/tether'
FEED_URL = 'https://raw.githubusercontent.com/jukqaz/tether/updates/appcast.xml'

def calendar_version(value):
    assert re.fullmatch(r'[1-9][0-9]{3}\.[1-9][0-9]?\.[1-9][0-9]*', value), 'use YYYY.M.sequence without leading zeros'
    parts = tuple(map(int, value.split('.')))
    assert 1 <= parts[1] <= 12, 'invalid month'
    return parts

def identity(info):
    version = info['CFBundleShortVersionString']; calendar_version(version)
    build = int(info['CFBundleVersion']); assert build > 41, 'never reset the build counter'
    assert info.get('TetherReleaseChannel') == 'stable', 'only stable releases may be generated'
    assert 'TetherBetaIteration' not in info, 'remove retired beta iteration metadata'
    return f'v{version}', f'Tether-{version}-arm64.zip'

def minimum_macos(value):
    assert value and re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', value), 'missing or invalid minimum macOS'
    return value

def merge(generated, previous, info, destination):
    tag, archive = identity(info)
    root = ET.parse(generated).getroot(); channel = root.find('channel')
    assert channel is not None
    fresh = channel.findall('item'); assert len(fresh) == 1
    item = fresh[0]; build = int(info['CFBundleVersion']); version = info['CFBundleShortVersionString']
    assert item.findtext(S + 'version') == str(build), 'build mismatch'
    assert item.findtext(S + 'shortVersionString') == version, 'version mismatch'
    assert item.find(S + 'channel') is None, 'new stable items must not declare an update channel'
    assert minimum_macos(item.findtext(S + 'minimumSystemVersion')) == minimum_macos(info.get('LSMinimumSystemVersion')), 'minimum macOS mismatch'
    enclosure = item.find('enclosure'); assert enclosure is not None
    assert enclosure.get('url') == f'{REPO}/releases/download/{tag}/{archive}'
    existing = [] if previous is None else ET.parse(previous).findall('./channel/item')
    seen = set()
    for old in existing:
        old_build = int(old.findtext(S + 'version')); assert old_build not in seen, 'duplicate build'
        seen.add(old_build)
        assert old_build < build, 'build must increase across all historical releases'
        old_channel = old.findtext(S + 'channel')
        assert old_channel in [None, 'beta'], 'unknown historical update channel'
        old_display = old.findtext(S + 'shortVersionString')
        if old_channel == 'beta':
            match = re.fullmatch(r'(.+) Beta ([1-9][0-9]*)', old_display or '')
            assert match, 'invalid historical beta version'
            old_version = match[1]
        else:
            old_version = old_display
        assert calendar_version(old_version) <= calendar_version(version), 'display version must not go backwards'
        if old_version == version:
            assert old_channel == 'beta', 'stable display version already released'
    item.find('title').text = 'Tether ' + version
    # The previous signed feed may contain beta releases. Their ordering was
    # checked above, but the new signed feed contains only the fresh stable item.
    downloads = {'stable': dict(version=version, build=build, url=enclosure.get('url'),
                                minimum_macos=info['LSMinimumSystemVersion'])}
    destination.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(destination/'appcast.xml', encoding='utf-8', xml_declaration=True)
    (destination/'downloads.json').write_text(json.dumps(downloads, indent=2)+'\n')
    value = downloads['stable']
    (destination/'README.md').write_text(
        '# Tether 다운로드\n\nApple Silicon · 정식 업데이트만 제공합니다.\n\n'
        '| 버전 | 다운로드 | 최소 OS |\n|---|---|---|\n'
        f"| {value['version']} | [설치 파일]({value['url']}) | macOS {value['minimum_macos']} 이상 |\n"
        '\n설치본보다 낮은 빌드로 자동 변경하지 않습니다.\n\n'
        '이 페이지와 appcast.xml은 검증된 릴리스 자산을 업로드한 후 함께 갱신합니다.\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('generated', type=Path); parser.add_argument('destination', type=Path)
    parser.add_argument('--previous', type=Path); parser.add_argument('--info', type=Path, default=Path('Resources/Info.plist'))
    args = parser.parse_args()
    merge(args.generated, args.previous, plistlib.loads(args.info.read_bytes()), args.destination)
