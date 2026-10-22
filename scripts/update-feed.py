#!/usr/bin/env python3
"""Build a two-channel appcast from a newly generated item and a previously verified feed.
The caller must verify the old feed before invoking this script, and sign the result after.
"""
import argparse
import copy
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
    channel = info['TetherReleaseChannel']; assert channel in ['stable', 'beta']
    beta = info.get('TetherBetaIteration', 0)
    assert isinstance(beta, int) and (beta > 0 if channel == 'beta' else beta == 0), 'invalid beta iteration'
    suffix = f'-beta.{beta}' if channel == 'beta' else ''
    return f'v{version}{suffix}', f'Tether-{version}{suffix}-arm64.zip'

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
    assert minimum_macos(item.findtext(S + 'minimumSystemVersion')) == minimum_macos(info.get('LSMinimumSystemVersion')), 'minimum macOS mismatch'
    enclosure = item.find('enclosure'); assert enclosure is not None
    assert enclosure.get('url') == f'{REPO}/releases/download/{tag}/{archive}'
    existing = [] if previous is None else ET.parse(previous).findall('./channel/item')
    seen = set()
    for old in existing:
        old_build = int(old.findtext(S + 'version')); assert old_build not in seen, 'duplicate build'
        seen.add(old_build)
        assert old_build < build, 'build must increase across both channels'
        old_version = old.findtext(S + 'shortVersionString').split(' Beta ')[0]
        assert calendar_version(old_version) <= calendar_version(version), 'display version must not go backwards'
        assert old.findtext(S + 'channel') in [None, 'beta'], 'unknown update channel'
        if old_version == version:
            assert old.findtext(S + 'channel') == 'beta', 'stable display version already released'
            if info['TetherReleaseChannel'] == 'beta':
                old_iteration = int(old.findtext(S + 'shortVersionString').split(' Beta ')[1])
                assert old_iteration < info['TetherBetaIteration'], 'beta iteration must increase'
    if info['TetherReleaseChannel'] == 'beta':
        ET.SubElement(item, S + 'channel').text = 'beta'
        item.find(S + 'shortVersionString').text = f"{version} Beta {info['TetherBetaIteration']}"
    item.find('title').text = 'Tether ' + item.findtext(S + 'shortVersionString')
    # Keep one current item per channel; stable clients must retain a stable candidate.
    all_items = sorted([item] + existing, key=lambda x: int(x.findtext(S+'version')), reverse=True)
    for old in channel.findall('item'): channel.remove(old)
    retained = {}; downloads = {}
    for candidate in all_items:
        name = candidate.findtext(S+'channel') or 'stable'
        if name in retained: continue
        retained[name] = candidate; channel.append(copy.deepcopy(candidate))
        downloads[name] = dict(version=candidate.findtext(S+'shortVersionString'), build=int(candidate.findtext(S+'version')),
                               url=candidate.find('enclosure').get('url'),
                               minimum_macos=minimum_macos(candidate.findtext(S+'minimumSystemVersion')))
    destination.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(destination/'appcast.xml', encoding='utf-8', xml_declaration=True)
    (destination/'downloads.json').write_text(json.dumps(downloads, indent=2)+'\n')
    rows = []
    for name, title in [('stable','정식'),('beta','베타')]:
        value = downloads.get(name)
        rows.append(f"| {title} | [{value['version']}]({value['url']}) | macOS {value['minimum_macos']} 이상 |" if value else f'| {title} | 아직 배포되지 않음 | — |')
    (destination/'README.md').write_text('# Tether 다운로드\n\nApple Silicon · 최소 macOS는 각 설치 파일을 기준으로 표시합니다.\n\n| 채널 | 다운로드 | 최소 OS |\n|---|---|---|\n'+'\n'.join(rows)+'\n\n앱 설정에서 정식 / 정식 + 베타를 선택할 수 있습니다. 설치본보다 낮은 빌드로 자동 변경하지 않습니다.\n\n이 페이지와 appcast.xml은 검증된 릴리스 자산을 업로드한 후 함께 갱신합니다.\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('generated', type=Path); parser.add_argument('destination', type=Path)
    parser.add_argument('--previous', type=Path); parser.add_argument('--info', type=Path, default=Path('Resources/Info.plist'))
    args = parser.parse_args()
    merge(args.generated, args.previous, plistlib.loads(args.info.read_bytes()), args.destination)
