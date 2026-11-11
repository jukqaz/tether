#!/usr/bin/env python3
"""Verify the archived app and its isolated helper/CLI. Never installs or changes host power."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, **kwargs)

def rpc(path, action):
    request = dict(version=2, id=str(uuid.uuid4()), action=action)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        client.sendall(json.dumps(request).encode() + b'\n')
        data = b''
        while not data.endswith(b'\n'):
            part = client.recv(8192)
            assert part, 'incomplete helper response'
            data += part
    result = json.loads(data)
    assert result['id'].lower() == request['id'] and result['ok'], result
    return result

def verify_packaged_runtime(app, info, state):
    helper_binary = app / 'Contents/Resources/tether-helper'
    recovery_binary = app / 'Contents/Resources/tether-power-recovery'
    cli_binary = app / 'Contents/Helpers/tether'
    for binary, identifier in [(helper_binary, 'local.tether.helper'),
                               (recovery_binary, 'local.tether.power-recovery')]:
        details = run('codesign', '-dv', binary).stderr.splitlines()
        assert f'Identifier={identifier}' in details, f'wrong packaged component: {binary.name}'
    assert run(recovery_binary, '--capability').stdout.strip() == 'power-recovery-executor-v2'
    assert run(recovery_binary, '--gate-capability').stdout.strip() == 'power-writer-gate-v3'
    assert run(helper_binary, '--validate-settings', '--recovery-write-capability').stdout.strip() == 'power-recovery-executor-v2'
    assert run(helper_binary, '--validate-settings', '--writer-gate-capability').stdout.strip() == 'power-writer-gate-v3'
    # This recognized terminating mode must never initialize a service, even when
    # the current host cannot supply hardware observations needed for installation.
    probe_env = {k:v for k,v in os.environ.items() if k != 'TETHER_INSTALL_TEST_ROOT'}
    install_target = run(helper_binary, '--validate-settings', '--helper-install-target', env=probe_env).stdout.strip()
    assert install_target in {f'helper-install-target-v1 {target}' for target in
                              ('portable', 'desktop', 'unavailable', 'unsupported')}, install_target
    state.mkdir()
    control = state / 'control.json'; control.write_text(json.dumps({'enabled': False}))
    fake = state / 'fake.json'
    # Test the packaged IPC path while deferring to native display management.
    # Kernel-dependent override ownership is covered by the separate power tests.
    fake.write_text(json.dumps(dict(power='ac', lid='open', sleepDisabled=False, fullWake=True,
                                    external=True, temperature=30, thermal=0, battery=80, current=-400)))
    service = state / 'service.sock'
    with (state / 'helper.log').open('w') as log:
        helper = subprocess.Popen([str(helper_binary), '--dry-run', '--control', str(control),
                                   '--status', str(state / 'status.json'), '--fake', str(fake)], stdout=log, stderr=log)
        try:
            for _ in range(100):
                assert helper.poll() is None, 'packaged helper exited before readiness'
                try:
                    reply = rpc(service, 'snapshot')
                    if reply.get('status'): break
                except (OSError, AssertionError): pass
                time.sleep(.03)
            else: raise AssertionError('packaged helper readiness timeout')
            status = reply['status']
            assert str(status['build']) == info['CFBundleVersion']
            assert status['version'] == info['CFBundleShortVersionString']
            assert not status['ownsOverride']
            run(helper_binary, '--check-service', '--socket', service)
            result = run(cli_binary, 'status', '--json', env=os.environ | {'TETHER_SERVICE_SOCKET': str(service)})
            json.loads(result.stdout)
            rpc(service, 'resume'); rpc(service, 'stop')
            assert not rpc(service, 'snapshot')['status']['ownsOverride']
        finally:
            helper.terminate()
            try: helper.wait(timeout=10)
            except subprocess.TimeoutExpired: helper.kill(); helper.wait(); raise

def verify_stable_identity(info, source_info, item, tag):
    assert info.get('TetherReleaseChannel') == source_info.get('TetherReleaseChannel') == 'stable', (
        'only stable source and bundles may be released')
    assert 'TetherBetaIteration' not in info and 'TetherBetaIteration' not in source_info, (
        'remove retired beta iteration metadata')
    assert tag == f"v{info['CFBundleShortVersionString']}", 'stable tag/version mismatch'
    assert item.find(SPARKLE + 'channel') is None, 'release feed must not contain a beta channel'
    assert item.findtext(SPARKLE + 'shortVersionString') == info['CFBundleShortVersionString'], (
        'stable feed/bundle display version mismatch')


def verify(archive, tag, require_clean):
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = Path(str(archive) + '.sha256').read_text().strip().split()
    assert checksum == [digest, archive.name], 'archive checksum mismatch'
    feed = archive.parent / 'appcast.xml'
    items = ET.parse(feed).findall('./channel/item')
    assert len(items) == 1, 'release feed must contain exactly one stable candidate'
    item = next((x for x in items if x.find('enclosure').get('url').endswith('/' + archive.name)), None)
    assert item is not None
    enclosure = item.find('enclosure')
    prefix = f'https://github.com/jukqaz/tether/releases/download/{tag}/'
    assert enclosure.attrib['url'] == prefix + archive.name
    assert int(enclosure.attrib['length']) == archive.stat().st_size
    with tempfile.TemporaryDirectory(prefix='tether-release-', dir='/tmp') as folder:
        folder = Path(folder)
        run('ditto', '-x', '-k', archive, folder)
        app = folder / 'Tether.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        source_info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        for key in ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'LSMinimumSystemVersion', 'SUPublicEDKey'):
            assert info[key] == source_info[key], f'bundle/source mismatch: {key}'
        assert info['CFBundleIdentifier'] == 'io.github.jukqaz.tether', 'preview is not a release'
        assert item.findtext(SPARKLE + 'version') == info['CFBundleVersion']
        assert item.findtext(SPARKLE + 'minimumSystemVersion') == info['LSMinimumSystemVersion']
        assert item.findtext(SPARKLE + 'hardwareRequirements') == 'arm64'
        assert info['SUPublicEDKey'] == (ROOT / 'Resources/update-public-key.txt').read_text().strip()
        assert info['SUFeedURL'] == 'https://raw.githubusercontent.com/jukqaz/tether/updates/appcast.xml'
        assert info['SURequireSignedFeed'] is True, 'signed feed verification must be enabled'
        assert info['SUSignedFeedFailureExpirationInterval'] == 0, 'invalid feeds must remain rejected indefinitely'
        assert info['SUVerifyUpdateBeforeExtraction'] is True, 'verify archives before extraction'
        verify_stable_identity(info, source_info, item, tag)
        commit = run('git', 'rev-parse', 'HEAD', cwd=ROOT).stdout.strip()
        assert info['TetherSourceCommit'] == commit, 'archive is from a different source commit'
        if require_clean:
            assert not info['TetherSourceDirty'], 'archive was built with uncommitted changes'
            assert not run('git', 'status', '--porcelain', cwd=ROOT).stdout, 'source has uncommitted changes'
        run('codesign', '--verify', '--deep', '--strict', app)
        run('python3', ROOT / 'scripts/check-platform.py', app)
        bundled_notice = app / 'Contents/Resources/Sparkle-LICENSE.txt'
        sparkle_notice = ROOT / '.build/artifacts/sparkle/Sparkle/LICENSE'
        assert bundled_notice.is_file() and bundled_notice.read_bytes() == sparkle_notice.read_bytes(), \
            'archive is missing the original Sparkle distribution license and notices'
        binaries = [app / 'Contents/MacOS/Tether', app / 'Contents/Resources/tether-helper',
                    app / 'Contents/Resources/tether-power-recovery', app / 'Contents/Helpers/tether']
        home_prefix = (Path.home().as_posix() + '/').encode()
        for binary in binaries:
            assert run('lipo', '-archs', binary).stdout.strip() == 'arm64'
            run('codesign', '--verify', '--strict', binary)
            assert home_prefix not in binary.read_bytes(), f'build machine path in {binary.name}'
        tools = Path(os.environ['SPARKLE_TOOLS_DIR'])
        key = Path(os.environ['TETHER_SIGNING_KEY_FILE'])
        run(tools / 'bin/sign_update', '--ed-key-file', key, '--verify', feed)
        signature = run(tools / 'bin/sign_update', '--ed-key-file', key, '-p', archive).stdout.strip()
        assert signature == enclosure.attrib[SPARKLE + 'edSignature'], 'archive signature mismatch'
        verify_packaged_runtime(app, info, folder / 'state')
        signature_info = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True).stderr
        assert 'Signature=adhoc' in signature_info, 'update signing documentation if signature type changes'
        assessment = subprocess.run(['spctl', '-a', '-vv', str(app)], capture_output=True, text=True)
        manifest = dict(version=info['CFBundleShortVersionString'], build=int(info['CFBundleVersion']),
                        tag=tag, channel=info['TetherReleaseChannel'], architecture='arm64',
                        minimum_macos=info['LSMinimumSystemVersion'], source_commit=commit,
                        source_dirty=info['TetherSourceDirty'], archive=archive.name, sha256=digest,
                        signature='ad-hoc', notarized=False, gatekeeper_accepted=assessment.returncode == 0,
                        gatekeeper_exit_code=assessment.returncode, gatekeeper_diagnostic=assessment.stderr.strip(),
                        checks=['checksum', 'bundle/source/build identity', 'nested code signatures', 'Sparkle license and notices',
                                'packaged arm64 and minimum macOS metadata',
                                'archive and feed Ed25519 signatures', 'packaged helper socket', 'packaged CLI',
                                'packaged recovery/helper capabilities',
                                'isolated resume/stop with native display deferral'], physical_lid_sleep_verified=False)
        (archive.parent / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--require-clean', action='store_true')
    args = parser.parse_args()
    verify(args.archive.resolve(), args.tag, args.require_clean)
