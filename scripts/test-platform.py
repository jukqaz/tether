#!/usr/bin/env python3
"""Prove the compatibility gate rejects incompatible real Mach-O binaries."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('platform_check', Path(__file__).with_name('check-platform.py'))
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)


class PlatformTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = tempfile.TemporaryDirectory(prefix='tether-platform-code-')
        cls.code = Path(cls.compiled.name)
        source = cls.code / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        for name, target in [('compatible', 'arm64-apple-macos26.0'),
                             ('too_new', 'arm64-apple-macos27.0'),
                             ('intel', 'x86_64-apple-macos26.0')]:
            subprocess.run(['xcrun', 'clang', '-target', target, str(source), '-o', str(cls.code/name)],
                           check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.compiled.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tether-platform-app-')
        self.app = Path(self.temp.name) / 'Tether.app'
        self.contents = self.app / 'Contents'
        for name in ('MacOS/Tether', 'Resources/tether-helper', 'Resources/tether-power-recovery', 'Helpers/tether'):
            target = self.contents/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.code/'compatible', target)
        (self.contents/'Info.plist').write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '26.0'}))
        # Only the container header is checked here; visual icon validation is separate.
        (self.contents/'Resources/AppIcon.icns').write_bytes(b'icns\x00\x00\x00\x10icp4\x00\x00\x00\x08')
        (self.contents/'Resources/Assets.car').touch()

    def tearDown(self):
        self.temp.cleanup()

    def test_arm64_minimum_matches_without_claiming_runtime_coverage(self):
        result = platform.verify(self.app, '26.0')
        self.assertEqual(len(result['binaries']), 4)
        self.assertFalse(result['runtime_on_minimum_os_verified'])

    def test_higher_minimum_hidden_behind_compatible_plist_is_rejected(self):
        shutil.copy2(self.code/'too_new', self.contents/'Resources/tether-helper')
        with self.assertRaisesRegex(ValueError, 'requires macOS 27.0'):
            platform.verify(self.app, '26.0')

    def test_nested_updater_with_no_arm64_is_rejected(self):
        target = self.contents/'Frameworks/Updater.app/Contents/MacOS/Updater'
        target.parent.mkdir(parents=True)
        shutil.copy2(self.code/'intel', target)
        with self.assertRaisesRegex(ValueError, 'missing arm64'):
            platform.verify(self.app, '26.0')

    def test_nested_bundle_metadata_cannot_raise_minimum(self):
        target = self.contents/'Frameworks/Updater.app/Contents/Info.plist'
        target.parent.mkdir(parents=True)
        target.write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '27.0'}))
        with self.assertRaisesRegex(ValueError, 'nested bundle requires'):
            platform.verify(self.app, '26.0')

    def test_app_metadata_must_match_source(self):
        with self.assertRaisesRegex(ValueError, 'bundle/source'):
            platform.verify(self.app, '27.0')

    def test_flat_icon_cannot_be_omitted(self):
        (self.contents/'Resources/AppIcon.icns').unlink()
        with self.assertRaises(FileNotFoundError):
            platform.verify(self.app, '26.0')

    def test_recovery_executor_cannot_be_omitted(self):
        (self.contents/'Resources/tether-power-recovery').unlink()
        with self.assertRaises(FileNotFoundError):
            platform.verify(self.app, '26.0')


if __name__ == '__main__':
    unittest.main(verbosity=2)
