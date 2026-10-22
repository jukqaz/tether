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

    def release(self):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('TETHER_') and key != 'SPARKLE_TOOLS_DIR'}
        # No signing key is supplied. A clean checkout reaches the normal key
        # requirement; dirty source must be rejected before that boundary.
        result = subprocess.run(['sh', 'scripts/release.sh', '--prerelease'],
                                cwd=self.folder, env=env, capture_output=True,
                                text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / 'build').exists())
        self.assertFalse((self.folder / 'dist').exists())
        return result.stderr

    def test_clean_source_reaches_signing_configuration_without_generating_artifacts(self):
        error = self.release()
        self.assertIn('TETHER_SIGNING_KEY_FILE', error)
        self.assertNotIn('requires a clean source checkout', error)

    def test_modified_tracked_source_is_rejected_before_signing(self):
        self.source.write_text('uncommitted release source\n')
        self.assertIn('requires a clean source checkout', self.release())

    def test_staged_source_is_rejected_before_signing(self):
        self.source.write_text('staged release source\n')
        self.git('add', 'source.txt')
        self.assertIn('requires a clean source checkout', self.release())

    def test_untracked_source_is_rejected_before_signing(self):
        (self.folder / 'untracked source.txt').write_text('new release source\n')
        self.assertIn('requires a clean source checkout', self.release())

    def test_unavailable_git_state_cannot_reach_signing_configuration(self):
        shutil.rmtree(self.folder / '.git')
        error = self.release()
        self.assertIn('not a git repository', error)
        self.assertNotIn('TETHER_SIGNING_KEY_FILE', error)


if __name__ == '__main__':
    unittest.main(verbosity=2)
