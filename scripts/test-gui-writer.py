#!/usr/bin/env python3
"""Native exec-boundary GUI checks against private temporary targets; no host power writes."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
if os.geteuid() == 0:
    raise SystemExit('Run without root; this suite never changes macOS power or GUI state')
BIN = Path(subprocess.check_output(['swift', 'build', '--disable-sandbox', '--show-bin-path'], cwd=ROOT, text=True).strip())
DRIVER = BIN/'TetherWriterFixture'
RECOVERY = BIN/'TetherRecoveryCLI'
probe = subprocess.run([str(DRIVER), '--gui-preflight'], capture_output=True, text=True, timeout=3)
if probe.returncode == 78:
    print('SKIP native GUI writer scenarios: no verified active graphical login; pure root policy tests are separate', flush=True)
    raise SystemExit(0)
assert probe.returncode == 0, ('GUI preflight failed', probe.returncode, probe.stderr)
COUNT = 0

def wait_for(test, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if test(): return
        time.sleep(.005)
    raise AssertionError('Native GUI gate did not reach the expected state')

def busy(folder):
    with (folder/'recovery.lock').open('r+') as handle:
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return True
        return False

def prepare(temp):
    folder = Path(temp); folder.chmod(0o700); (folder/'mock').mkdir()
    shutil.copy2(DRIVER, folder/'mock/pmset')
    return folder

def change(folder, mutation):
    path = folder/'helper-state.json'
    state = json.loads(path.read_text())
    if mutation in ['revoked', 'legacy']: state.pop('guiOwner')
    elif mutation == 'controller': state['controllerUID'] += 1
    elif mutation == 'pid': state['appPID'] += 1
    elif mutation == 'start': state['appStarted'] -= 1
    elif mutation == 'login': state['guiOwner']['login']['sessionID'] = 0
    elif mutation == 'boot': state['guiOwner']['bootID'] = 'different-boot'
    elif mutation == 'missing': path.unlink(); return
    elif mutation == 'mode': path.chmod(0o640); return
    else: assert mutation is None, mutation; return
    if mutation == 'legacy': state.pop('controllerUID')
    path.write_text(json.dumps(state))

def passed(message):
    global COUNT
    COUNT += 1
    print('PASS native GUI writer', message, flush=True)

def queued(mode, mutation=None, expected=0):
    with tempfile.TemporaryDirectory(prefix='tether-recovery-test-', dir='/private/tmp') as temp:
        folder = prepare(temp)
        env = os.environ | {'TETHER_RECOVERY_TEST_ROOT': str(folder)}
        parent = subprocess.Popen([str(DRIVER), 'gated-gui-'+mode, str(folder)], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            marker = folder/'gui-ready'
            wait_for(lambda: marker.exists() and marker.read_text().isdigit())
            record = json.loads((folder/'power-writer.json').read_text())
            assert record['phase'] == 'running' and record['writerPID'] == int(marker.read_text())
            assert record['guiOwner']['login']['uid'] == os.getuid()
            assert record['guiOwner']['process']['started'] > 0
            assert record['intentEpoch'] == 'gui-gate-test' and record['intentRevision'] == 9
            assert busy(folder) and not (folder/'effect').exists() and not (folder/'child.pid').exists()
            change(folder, mutation)
            (folder/'gui-permit').write_text('continue')
            stdout, stderr = parent.communicate(timeout=7)
            assert parent.returncode == 0, (mode, mutation, parent.returncode, stdout, stderr)
            result = json.loads((folder/'gui-result.json').read_text())
            assert result == dict(result='observed', status=str(expected), terminationConfirmed='true', timedOut='false'), result
            assert not (folder/'power-writer.json').exists() and not busy(folder)
            if expected == 0:
                operations = dict(acquire='-a disablesleep 1', display='displaysleepnow', sleep='sleepnow', release='-a disablesleep 0')
                assert (folder/'effect').read_text() == operations[mode]
            else:
                assert not (folder/'effect').exists() and not (folder/'child.pid').exists(), 'Denied gate ran the target'
            passed(f'{mode}, {mutation or "confirmed controller"}, exit {expected}')
        finally:
            if parent.poll() is None: parent.kill(); parent.communicate(timeout=2)
            # Only the identity-checked native resolver can stop this suite's gate.
            if (folder/'power-writer.json').exists():
                time.sleep(5)
                result = subprocess.run([str(RECOVERY), '--resolve', '--support', str(folder)],
                    env=env, capture_output=True, text=True, timeout=3)
                assert result.returncode == 0, ('Fixture cleanup could not resolve its own writer', result.stderr)
            wait_for(lambda: not busy(folder), timeout=2)

for mode in ['acquire', 'display', 'sleep']:
    queued(mode)
    queued(mode, 'revoked', 77)
for mutation in ['controller', 'pid', 'start', 'login', 'boot', 'legacy', 'missing', 'mode']:
    queued('acquire', mutation, 77)
queued('controller-exit', expected=77)
queued('release', 'revoked')
print(f'TOTAL {COUNT} native GUI writer scenarios passed (unprivileged temporary targets; not root/physical OS validation)', flush=True)
