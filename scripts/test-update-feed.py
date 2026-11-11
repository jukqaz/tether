#!/usr/bin/env python3
"""Regression checks for stable-only feeds and immutable historical release ordering."""
import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('feed', Path(__file__).with_name('update-feed.py'))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)
spec = importlib.util.spec_from_file_location('verify_release', Path(__file__).with_name('verify-release.py'))
verify_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_release)


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def prepare(self, build, version='2026.11.1', minimum_macos='26.0', **metadata):
        info = dict(CFBundleShortVersionString=version, CFBundleVersion=str(build),
                    TetherReleaseChannel='stable', LSMinimumSystemVersion=minimum_macos)
        info.update(metadata)
        tag, archive = feed.identity(info)
        generated = self.root / f'generated-{build}.xml'
        generated.write_text(
            f'<rss xmlns:sparkle="{feed.NS}"><channel><title>Tether</title><item><title>Tether</title>'
            f'<sparkle:version>{build}</sparkle:version>'
            f'<sparkle:shortVersionString>{version}</sparkle:shortVersionString>'
            f'<sparkle:minimumSystemVersion>{minimum_macos}</sparkle:minimumSystemVersion>'
            f'<enclosure url="{feed.REPO}/releases/download/{tag}/{archive}"/>'
            '</item></channel></rss>')
        return generated, info

    def history(self, releases):
        root = ET.Element('rss')
        channel = ET.SubElement(root, 'channel')
        for build, version, name in releases:
            generated, _ = self.prepare(build, version=version)
            item = ET.parse(generated).find('./channel/item')
            if name is not None:
                ET.SubElement(item, feed.S + 'channel').text = name
            if name == 'beta':
                item.find(feed.S + 'shortVersionString').text = f'{version} Beta 1'
                item.find('title').text = f'Tether {version} Beta 1'
                item.find('enclosure').set('url',
                    f'{feed.REPO}/releases/download/v{version}-beta.1/Tether-{version}-beta.1-arm64.zip')
            channel.append(item)
        destination = self.root / 'history.xml'
        ET.ElementTree(root).write(destination)
        return destination

    def release(self, build=60, previous=None, **kwargs):
        generated, info = self.prepare(build, **kwargs)
        destination = self.root / str(build)
        feed.merge(generated, previous, info, destination)
        return destination / 'appcast.xml'

    def assert_stable_output(self, appcast, version='2026.11.1', build=60, minimum='26.0'):
        items = ET.parse(appcast).findall('./channel/item')
        self.assertEqual(len(items), 1)
        item = items[0]
        self.assertIsNone(item.find(feed.S + 'channel'))
        self.assertEqual(item.findtext(feed.S + 'version'), str(build))
        self.assertEqual(item.findtext(feed.S + 'shortVersionString'), version)
        self.assertEqual(item.findtext(feed.S + 'minimumSystemVersion'), minimum)
        downloads = json.loads((appcast.parent / 'downloads.json').read_text())
        self.assertEqual(set(downloads), {'stable'})
        self.assertEqual(downloads['stable'], dict(version=version, build=build,
            url=f'{feed.REPO}/releases/download/v{version}/Tether-{version}-arm64.zip', minimum_macos=minimum))
        readme = (appcast.parent / 'README.md').read_text()
        self.assertNotIn('베타', readme)
        self.assertNotIn('beta', readme.lower())
        self.assertIn(f'macOS {minimum} 이상', readme)

    def test_first_stable_produces_one_download(self):
        self.assert_stable_output(self.release())

    def test_public_beta_is_ordering_evidence_and_remains_unchanged(self):
        previous = self.history([(59, '2026.11.1', 'beta')])
        before = previous.read_bytes()
        self.assert_stable_output(self.release(previous=previous))
        self.assertEqual(previous.read_bytes(), before)

    def test_mixed_legacy_feed_outputs_only_new_stable_and_its_os_requirement(self):
        previous = self.history([(58, '2026.10.1', None), (59, '2026.11.1', 'beta')])
        tree = ET.parse(previous)
        tree.find('./channel/item/' + feed.S + 'minimumSystemVersion').text = '15.0'
        tree.write(previous)
        self.assert_stable_output(self.release(previous=previous))

    def test_next_stable_replaces_the_previous_stable(self):
        first = self.release(build=60)
        next_feed = self.release(build=61, previous=first, version='2026.11.2')
        self.assert_stable_output(next_feed, version='2026.11.2', build=61)

    def test_wrong_or_missing_os_requirement_is_rejected(self):
        for value in ['15.0', '', 'unknown']:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                generated, info = self.prepare(60)
                tree = ET.parse(generated)
                tree.find('./channel/item/' + feed.S + 'minimumSystemVersion').text = value
                tree.write(generated)
                feed.merge(generated, None, info, self.root / 'bad')

    def test_all_historical_builds_and_display_versions_prevent_downgrades(self):
        previous = self.history([(58, '2026.10.1', None), (59, '2026.11.1', 'beta')])
        for build, version in [(59, '2026.11.1'), (58, '2026.11.2'), (60, '2026.10.2')]:
            with self.subTest(build=build, version=version), self.assertRaises(AssertionError):
                self.release(build, previous, version=version)

    def test_dropped_beta_with_higher_display_version_still_blocks_downgrade(self):
        previous = self.history([(58, '2026.12.1', 'beta'), (59, '2026.11.1', None)])
        with self.assertRaisesRegex(AssertionError, 'backwards'):
            self.release(previous=previous, version='2026.11.2')

    def test_duplicate_historical_build_is_rejected(self):
        previous = self.history([(59, '2026.10.1', None), (59, '2026.11.1', 'beta')])
        with self.assertRaisesRegex(AssertionError, 'duplicate build'):
            self.release(previous=previous)

    def test_stable_display_version_cannot_be_republished(self):
        previous = self.release(60)
        with self.assertRaisesRegex(AssertionError, 'already released'):
            self.release(61, previous)

    def test_invalid_version_or_retired_beta_metadata_is_rejected(self):
        for version in ['2026.09.1', '2026.13.1', '2026.9.0', '0.1.0', '2026.9.1-beta.1']:
            with self.subTest(version=version), self.assertRaises(AssertionError):
                self.prepare(60, version=version)
        for metadata in [dict(TetherReleaseChannel='beta'), dict(TetherReleaseChannel='nightly'),
                         dict(TetherBetaIteration=0), dict(TetherBetaIteration=1)]:
            with self.subTest(metadata=metadata), self.assertRaises(AssertionError):
                self.prepare(60, **metadata)

    def test_generated_channel_marker_is_rejected_even_if_empty_or_stable(self):
        for name in ['beta', 'stable', '']:
            with self.subTest(name=name), self.assertRaisesRegex(AssertionError, 'must not declare'):
                generated, info = self.prepare(60)
                tree = ET.parse(generated)
                ET.SubElement(tree.find('./channel/item'), feed.S + 'channel').text = name
                tree.write(generated)
                feed.merge(generated, None, info, self.root / 'bad')

    def test_unknown_or_malformed_legacy_channel_is_rejected(self):
        for name in ['nightly', 'beta']:
            with self.subTest(name=name), self.assertRaises(AssertionError):
                previous = self.history([(59, '2026.11.1', name)])
                if name == 'beta':
                    tree = ET.parse(previous)
                    tree.find('./channel/item/' + feed.S + 'shortVersionString').text = '2026.11.1'
                    tree.write(previous)
                self.release(previous=previous)

    def test_enclosure_url_cannot_point_to_another_release(self):
        generated, info = self.prepare(60)
        generated.write_text(generated.read_text().replace('/v2026.11.1/', '/v2026.11.1-beta.1/'))
        with self.assertRaises(AssertionError):
            feed.merge(generated, None, info, self.root / 'bad')

    def test_archive_verifier_accepts_only_matching_stable_identity(self):
        generated, info = self.prepare(60)
        item = ET.parse(generated).find('./channel/item')
        verify_release.verify_stable_identity(info, info, item, 'v2026.11.1')
        for key, value in [('TetherReleaseChannel', 'beta'), ('TetherBetaIteration', 0)]:
            changed = info | {key: value}
            for source, bundle in [(changed, info), (info, changed)]:
                with self.subTest(key=key), self.assertRaises(AssertionError):
                    verify_release.verify_stable_identity(bundle, source, item, 'v2026.11.1')
        for tag in ['v2026.11.1-beta.1', 'v2026.11.2']:
            with self.subTest(tag=tag), self.assertRaises(AssertionError):
                verify_release.verify_stable_identity(info, info, item, tag)
        beta = copy.deepcopy(item)
        ET.SubElement(beta, feed.S + 'channel').text = 'beta'
        with self.assertRaises(AssertionError):
            verify_release.verify_stable_identity(info, info, beta, 'v2026.11.1')
        wrong_display = copy.deepcopy(item)
        wrong_display.find(feed.S + 'shortVersionString').text = '2026.11.1 Beta 1'
        with self.assertRaises(AssertionError):
            verify_release.verify_stable_identity(info, info, wrong_display, 'v2026.11.1')

    def test_archive_verifier_rejects_additional_feed_items_before_extraction(self):
        generated, _ = self.prepare(60)
        tree = ET.parse(generated)
        channel = tree.find('./channel')
        channel.append(copy.deepcopy(channel.find('item')))
        tree.write(self.root / 'appcast.xml')
        archive = self.root / 'Tether-2026.11.1-arm64.zip'
        archive.write_bytes(b'not an archive')
        Path(str(archive) + '.sha256').write_text(
            f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n')
        with self.assertRaisesRegex(AssertionError, 'exactly one stable'):
            verify_release.verify(archive, 'v2026.11.1', False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
