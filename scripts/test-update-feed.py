#!/usr/bin/env python3
"""Regression checks for channel retention and immutable release ordering."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET
spec = importlib.util.spec_from_file_location('feed', Path(__file__).with_name('update-feed.py'))
feed = importlib.util.module_from_spec(spec); spec.loader.exec_module(feed)

class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def prepare(self, build, channel='beta', beta=1, version='2026.9.1', minimum_macos='26.0'):
        info = dict(CFBundleShortVersionString=version, CFBundleVersion=str(build), TetherReleaseChannel=channel, TetherBetaIteration=beta, LSMinimumSystemVersion=minimum_macos)
        tag, archive = feed.identity(info)
        generated = self.root/f'generated-{build}.xml'
        generated.write_text(f'<rss xmlns:sparkle="{feed.NS}"><channel><title>Tether</title><item><title>Tether</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString><sparkle:minimumSystemVersion>{minimum_macos}</sparkle:minimumSystemVersion><enclosure url="{feed.REPO}/releases/download/{tag}/{archive}"/></item></channel></rss>')
        return generated, info
    def release(self, build, previous=None, **kwargs):
        generated, info = self.prepare(build, **kwargs); destination = self.root/str(build)
        feed.merge(generated, previous, info, destination)
        return destination/'appcast.xml'
    def test_beta_then_stable_then_next_beta_keeps_both_downloads(self):
        first = self.release(42)
        second = self.release(43, first, beta=2)
        third = self.release(44, second, channel='stable', beta=0)
        fourth = self.release(45, third, version='2026.9.2')
        items = ET.parse(fourth).findall('./channel/item')
        self.assertEqual([x.findtext(feed.S+'version') for x in items], ['45','44'])
        self.assertEqual([x.findtext(feed.S+'channel') for x in items], ['beta',None])
        downloads = json.loads((fourth.parent/'downloads.json').read_text())
        self.assertEqual(downloads['stable']['version'], '2026.9.1')
        self.assertIn('Beta 1', downloads['beta']['version'])
    def test_first_beta_does_not_claim_stable_is_published(self):
        first = self.release(42)
        self.assertNotIn('stable',json.loads((first.parent/'downloads.json').read_text()))
        self.assertIn('아직 배포되지 않음',(first.parent/'README.md').read_text())
    def test_old_stable_and_new_beta_keep_their_own_os_requirements(self):
        # Historical releases retain their original minimum; new candidates require 26.
        stable = self.release(42, channel='stable', beta=0, minimum_macos='15.0')
        beta = self.release(43, stable, version='2026.9.2', minimum_macos='26.0')
        items = ET.parse(beta).findall('./channel/item')
        self.assertEqual([x.findtext(feed.S+'minimumSystemVersion') for x in items], ['26.0','15.0'])
        downloads = json.loads((beta.parent/'downloads.json').read_text())
        self.assertEqual(downloads['stable']['minimum_macos'], '15.0')
        self.assertEqual(downloads['beta']['minimum_macos'], '26.0')
        rows = (beta.parent/'README.md').read_text().splitlines()
        self.assertIn('macOS 15.0 이상', next(row for row in rows if row.startswith('| 정식 |')))
        self.assertIn('macOS 26.0 이상', next(row for row in rows if row.startswith('| 베타 |')))
    def test_wrong_or_missing_os_requirement_is_rejected(self):
        for value in ['15.0', '', 'unknown']:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                generated, info = self.prepare(42)
                tree = ET.parse(generated)
                tree.find('./channel/item/'+feed.S+'minimumSystemVersion').text = value
                tree.write(generated)
                feed.merge(generated, None, info, self.root/'bad')
    def test_build_reuse_and_display_downgrade_rejected(self):
        first = self.release(43, version='2026.10.1')
        for build, version in [(43,'2026.10.1'),(42,'2026.10.1'),(44,'2026.9.2')]:
            with self.subTest(build=build, version=version), self.assertRaises(AssertionError):
                self.release(build, first, version=version)
    def test_beta_iteration_cannot_be_reused(self):
        first = self.release(42)
        with self.assertRaises(AssertionError): self.release(43, first)
    def test_stable_version_cannot_be_republished_or_followed_by_same_version_beta(self):
        first = self.release(42, channel='stable', beta=0)
        for channel, beta in [('stable',0),('beta',2)]:
            with self.assertRaises(AssertionError): self.release(43, first, channel=channel, beta=beta)
    def test_invalid_version_and_channel_rejected(self):
        for version in ['2026.09.1','2026.13.1','2026.9.0','0.1.0','2026.9.1-beta.1']:
            with self.assertRaises(AssertionError): self.prepare(42,version=version)
        for channel, beta in [('nightly',1),('stable',1),('beta',0)]:
            with self.assertRaises(AssertionError): self.prepare(42,channel=channel,beta=beta)
    def test_signature_enclosure_url_cannot_point_to_other_release(self):
        generated, info = self.prepare(42)
        generated.write_text(generated.read_text().replace('beta.1/','beta.2/'))
        with self.assertRaises(AssertionError): feed.merge(generated,None,info,self.root/'bad')

if __name__ == '__main__': unittest.main(verbosity=2)
