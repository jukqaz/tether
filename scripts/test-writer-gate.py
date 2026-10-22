#!/usr/bin/env python3
"""Prove a native power writer cannot exec before its identity is durable. No OS writes."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(subprocess.check_output(['swift', 'build', '--disable-sandbox', '--show-bin-path'], cwd=ROOT, text=True).strip())
DRIVER = BIN/'TetherWriterFixture'
RECOVERY = BIN/'TetherRecoveryCLI'

def wait_for(test, timeout=3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if test(): return
        time.sleep(.01)
    raise AssertionError('Native gate did not reach the expected state')

def busy(folder):
    with (folder/'recovery.lock').open('r+') as handle:
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return True
        return False

def env(folder):
    return os.environ | {'TETHER_RECOVERY_TEST_ROOT': str(folder)}

def command(folder, mode):
    return subprocess.run([str(RECOVERY), mode, '--support', str(folder)],
                          env=env(folder), capture_output=True, text=True, timeout=3)

def clear(folder):
    with (folder/'recovery.lock').open('r+') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run([str(RECOVERY), '--clear', '--support', str(folder)], stdin=handle,
                                env=env(folder), capture_output=True, text=True, timeout=3)
        assert result.returncode == 0, (result.stdout, result.stderr)

def prepare(temp):
    folder = Path(temp); folder.chmod(0o700)
    (folder/'mock').mkdir()
    shutil.copy2(DRIVER, folder/'mock/pmset')
    return folder

def normal(kind):
    with tempfile.TemporaryDirectory(prefix='tether-recovery-test-', dir='/private/tmp') as temp:
        folder=prepare(temp)
        if kind=='gated-recovery-deferred':
            observation=folder/'recovery-sleep.json'
            observation.write_text(json.dumps(dict(power='battery',lidClosed=True,sleepDisabled=False,
                fullWake=True,foreignKeepAwake=False)))
            observation.chmod(0o600)
        result=subprocess.run([str(DRIVER), kind, str(folder)], env=env(folder), capture_output=True, text=True, timeout=4)
        assert result.returncode == 0, (kind, result.stdout, result.stderr)
        assert not (folder/'power-writer.json').exists() and not busy(folder)
        if kind == 'gated-success': assert (folder/'effect').read_text() == '-a disablesleep 1'
        else: assert not (folder/'effect').exists() and not (folder/'child.pid').exists()
        if kind=='gated-recovery-deferred': assert (folder/'registered.pid').exists(), 'Must cross the parent verification'
        print('PASS native gate', kind, flush=True)

def cancelled(kind, let_expire=False):
    with tempfile.TemporaryDirectory(prefix='tether-recovery-test-', dir='/private/tmp') as temp:
        folder=prepare(temp)
        parent=subprocess.Popen([str(DRIVER), kind, str(folder)], env=env(folder), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        journal=folder/'power-writer.json'
        try:
            marker=folder/('before-registration.pid' if kind == 'gated-before-registration' else 'after-registration.pid')
            wait_for(lambda: marker.exists() and marker.read_text().isdigit())
            saved=journal.read_bytes(); record=json.loads(saved)
            assert record['gateExecutable'] == str(DRIVER)
            assert record['intentEpoch'] == 'gated-test' and record['intentRevision'] == 8
            assert not (folder/'child.pid').exists() and not (folder/'effect').exists()
            if kind == 'gated-before-registration':
                assert record['phase'] == 'prepared' and record.get('writerPID') is None
            else:
                assert record['phase'] == 'running' and record['writerPID'] == int(marker.read_text())
                assert record['writer']['pid'] == record['writerPID'] and record['writer']['started'] > 0
            if let_expire:
                # Do not terminate the gate: its own registration deadline must cancel it.
                time.sleep(2.15)
                assert parent.poll() is None and busy(folder)
                assert command(folder, '--resolve').returncode == 0
            parent.kill(); parent.wait(timeout=2)
            started=time.monotonic()
            wait_for(lambda: not busy(folder), timeout=2)
            elapsed=time.monotonic()-started
            assert journal.read_bytes() == saved, 'EOF must not consume a transaction without the common lock'
            assert command(folder, '--resolve').returncode == 0
            clear(folder)
            assert not journal.exists() and not (folder/'child.pid').exists() and not (folder/'effect').exists()
            print('PASS native gate cancellation', kind, 'deadline' if let_expire else 'parent SIGKILL',
                  f'lock released in {elapsed:.3f}s', flush=True)
        finally:
            if parent.poll() is None: parent.kill(); parent.wait(timeout=2)
            # No raw PID signals: EOF/deadline cancels the isolated gate, and native
            # identity recovery handles any published writer if the test failed.
            result=command(folder, '--resolve')
            if result.returncode == 75:
                time.sleep(2.1)
                result=command(folder, '--resolve')
            wait_for(lambda: not busy(folder), timeout=3)

if os.geteuid() == 0:
    raise SystemExit('Run without root; no macOS power settings are changed')
for kind in ['gated-success', 'gated-invalid', 'gated-recovery-deferred']: normal(kind)
cancelled('gated-before-registration')
cancelled('gated-after-registration')
cancelled('gated-after-registration', let_expire=True)
with tempfile.TemporaryDirectory(prefix='tether-recovery-test-', dir='/private/tmp') as temp:
    folder=prepare(temp)
    result=subprocess.run([str(RECOVERY), '--writer-gate', '--support', str(folder), '--transaction', str(uuid.uuid4())],
                          env=env(folder), capture_output=True, text=True, timeout=3)
    assert result.returncode != 0 and not (folder/'effect').exists()
    print('PASS gate entry without a trusted journal/lock/permission is refused', flush=True)
print('TOTAL 7 native writer gate scenarios passed', flush=True)
