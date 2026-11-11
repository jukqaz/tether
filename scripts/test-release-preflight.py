#!/usr/bin/env python3
"""Exercise release source gates without signing keys, builds or host changes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class ReleaseSourceTests(unittest.TestCase):
    script = (ROOT / 'scripts/release.sh').read_bytes()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tether-release-preflight-', dir='/tmp')
        self.folder = Path(self.temp.name)
        (self.folder / 'scripts').mkdir()
        (self.folder / 'scripts/release.sh').write_bytes(self.script)
        self.original = 'committed release source\n'
        self.source = self.folder / 'source.txt'
        self.source.write_text(self.original)
        self.git('init', '-q')
        self.git('add', 'scripts/release.sh', 'source.txt')
        self.git('-c', 'user.name=Tether Test', '-c', 'user.email=test@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'isolated fixture')

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.folder, check=True,
                              capture_output=True, text=True, timeout=10)

    def release(self, *arguments, environment=None):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('TETHER_') and key != 'SPARKLE_TOOLS_DIR'}
        # No signing key is supplied. A clean checkout reaches the normal key
        # requirement; dirty source must be rejected before that boundary.
        env.update(environment or {})
        result = subprocess.run(['sh', 'scripts/release.sh', *arguments],
                                cwd=self.folder, env=env, capture_output=True,
                                text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / 'build').exists())
        self.assertFalse((self.folder / 'dist').exists())
        return result

    def test_clean_source_reaches_signing_configuration_without_generating_artifacts(self):
        error = self.release().stderr
        self.assertIn('TETHER_SIGNING_KEY_FILE', error)
        self.assertNotIn('requires a clean source checkout', error)

    def test_explicit_stable_flag_reaches_normal_signing_configuration(self):
        self.assertIn('TETHER_SIGNING_KEY_FILE', self.release('--stable').stderr)

    def test_retired_beta_flags_and_unknown_arguments_are_rejected_before_signing(self):
        for arguments in [('--beta',), ('--prerelease',), ('--nightly',), ('--stable', '--stable')]:
            with self.subTest(arguments=arguments):
                result = self.release(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn('Usage:', result.stderr)
                self.assertNotIn('TETHER_SIGNING_KEY_FILE', result.stderr)

    def test_invalid_previous_feed_signature_stops_before_building(self):
        for relative in ['scripts/update-feed.py', 'Resources/Info.plist', 'Sources/TetherCore/IPC/TetherPaths.swift']:
            destination = self.folder / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        tools = self.folder / 'fake-tools/bin'
        tools.mkdir(parents=True)
        signer = tools / 'sign_update'
        signer.write_text('#!/bin/sh\n[ "$3" = --verify ] || exit 8\nexit 9\n')
        signer.chmod(0o755)
        previous = self.folder / 'previous.xml'
        previous.write_text('<rss><channel/></rss>\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Tether Test', '-c', 'user.email=test@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'release metadata fixture')
        result = self.release(environment={
            'TETHER_SIGNING_KEY_FILE': str(self.folder / 'unused-fixture-key'),
            'SPARKLE_TOOLS_DIR': str(tools.parent),
            'TETHER_PREVIOUS_APPCAST': str(previous),
        })
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertFalse((self.folder / 'unused-fixture-key').exists())

    def test_modified_tracked_source_is_rejected_before_signing(self):
        self.source.write_text('uncommitted release source\n')
        self.assertIn('requires a clean source checkout', self.release().stderr)

    def test_staged_source_is_rejected_before_signing(self):
        self.source.write_text('staged release source\n')
        self.git('add', 'source.txt')
        self.assertIn('requires a clean source checkout', self.release().stderr)

    def test_untracked_source_is_rejected_before_signing(self):
        (self.folder / 'untracked source.txt').write_text('new release source\n')
        self.assertIn('requires a clean source checkout', self.release().stderr)

    def test_unavailable_git_state_cannot_reach_signing_configuration(self):
        shutil.rmtree(self.folder / '.git')
        error = self.release().stderr
        self.assertIn('not a git repository', error)
        self.assertNotIn('TETHER_SIGNING_KEY_FILE', error)


if __name__ == '__main__':
    unittest.main(verbosity=2)
