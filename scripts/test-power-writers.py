#!/usr/bin/env python3
"""Kill the real writer's parent in isolated non-root fixtures. No OS power writes."""
import fcntl
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = (Path(os.environ['TETHER_TEST_BIN']) if os.environ.get('TETHER_TEST_BIN') else
       Path(subprocess.check_output(['swift', 'build', '--disable-sandbox', '--show-bin-path'], cwd=ROOT, text=True).strip()))
DRIVER = BIN / 'TetherWriterFixture'
HELPER = BIN / 'TetherHelper'
LIBRARY = ROOT / 'Resources/tether-recovery-lock.sh'

def wait_for(test, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if test():
            return
        time.sleep(.01)
    raise AssertionError('Fixture did not reach the expected state')

def busy(path):
    with path.open('r+') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False

def resolve(folder):
    return subprocess.run([str(DRIVER), 'resolve', str(folder)], capture_output=True, text=True, timeout=3)

def cleanup(folder):
    return subprocess.run([str(DRIVER), 'cleanup', str(folder)], capture_output=True, text=True, timeout=3)

def crash_case(mode):
    with tempfile.TemporaryDirectory(prefix='tether-writer-test-', dir='/private/tmp') as temp:
        folder = Path(temp); folder.chmod(0o700)
        journal = folder/'power-writer.json'
        parent = subprocess.Popen([str(DRIVER), mode, str(folder)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        child = None
        try:
            wait_for(lambda: (folder/'child.pid').exists() and (folder/'child.pid').read_text().isdigit())
            child = int((folder/'child.pid').read_text())
            if mode == 'registered':
                wait_for(lambda: journal.exists() and json.loads(journal.read_text()).get('writerPID') == child)
            else:
                wait_for(lambda: (folder/'before-registration.pid').exists())
            wait_for(lambda: (folder/'child-identity.json').exists())
            identity = folder/'child-identity.json'
            saved_identity = identity.read_bytes()
            mismatch = json.loads(saved_identity)
            mismatch['started'] += 1
            try:
                identity.write_text(json.dumps(mismatch))
                assert cleanup(folder).returncode == 0, 'A different process lifetime must not be signalled'
            finally:
                identity.write_bytes(saved_identity)
            before = journal.read_bytes()
            saved = json.loads(before)
            assert saved['intentEpoch'] == 'test-epoch' and saved['intentRevision'] == 7
            assert saved['phase'] == ('running' if mode == 'registered' else 'prepared')
            parent.kill(); parent.wait(timeout=2)
            assert busy(folder/'recovery.lock'), 'Writer must retain the flock after parent SIGKILL'
            assert resolve(folder).returncode != 0, 'A live writer must prevent the next transaction'
            assert journal.read_bytes() == before, 'Rejected recovery must retain its journal'
            time.sleep(1.55)
            result = resolve(folder)
            if mode == 'before-registration':
                assert result.returncode != 0 and journal.read_bytes() == before
                assert busy(folder/'recovery.lock'), 'Unknown PID must retain the lock, even after its deadline'
                # Only the fixture's saved native process identity authorizes cleanup.
                # Production still refuses to guess an unregistered writer PID.
                stopped = cleanup(folder)
                assert stopped.returncode == 0, (stopped.stdout, stopped.stderr)
                wait_for(lambda: not busy(folder/'recovery.lock'))
                result = resolve(folder)
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert not journal.exists() and not busy(folder/'recovery.lock')
            time.sleep(.1)
            assert not (folder/'late-write').exists()
            print('PASS parent crash', mode, flush=True)
        finally:
            if parent.poll() is None:
                parent.kill(); parent.wait(timeout=2)
            if (folder/'child-identity.json').exists():
                stopped = cleanup(folder)
                assert stopped.returncode == 0, (stopped.stdout, stopped.stderr)
            elif (folder/'recovery.lock').exists() and busy(folder/'recovery.lock'):
                # An interrupted test setup may not have published its identity.
                # Let this isolated, fixed-duration stand-in exit naturally.
                wait_for(lambda: not busy(folder/'recovery.lock'), timeout=5)

def capability_case(kind):
    with tempfile.TemporaryDirectory(prefix='tether-writer-test-', dir='/private/tmp') as temp:
        folder = Path(temp); folder.chmod(0o700)
        legacy = folder/'legacy-helper'
        called = folder/'called'
        if kind == 'old-unknown-flags':
            source = '#!/bin/sh\nprintf daemon > "$TETHER_PROBE_CALLED"\n'
        else:
            source = '#!/bin/sh\n# --validate-settings\ncase " $* " in *" --validate-settings "*) printf settings-valid; exit 0;; esac\nprintf daemon > "$TETHER_PROBE_CALLED"\n'
        legacy.write_text(source); legacy.chmod(0o700)
        script = '. "$1"; recovery_lock_path "$2"; RECOVERY_HELPER="$3"; if recovery_helper_capable; then exit 9; fi'
        result = subprocess.run(['/bin/sh', '-c', script, 'test', str(LIBRARY), str(folder), str(legacy)],
            env=dict(os.environ, TETHER_PROBE_CALLED=str(called)), capture_output=True, text=True, timeout=3)
        assert result.returncode == 0 and not called.exists(), (kind, result.stdout, result.stderr)
        print('PASS upgrade capability probe', kind, flush=True)

def current_capability():
    result = subprocess.run([str(HELPER), '--validate-settings', '--writer-recovery-capability'], capture_output=True, text=True, timeout=3)
    assert result.returncode == 0 and result.stdout.strip() == 'power-writer-recovery-v1', result
    print('PASS current helper terminates in capability mode', flush=True)

if os.geteuid() == 0:
    raise SystemExit('Run without root; this test never changes macOS power settings')
for mode in ['registered', 'before-registration']:
    crash_case(mode)
for kind in ['old-unknown-flags', 'old-validator']:
    capability_case(kind)
current_capability()
print('TOTAL 5 writer crash/upgrade scenarios passed', flush=True)
