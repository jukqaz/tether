#!/usr/bin/env python3
"""Real helper transactions versus a real external flock. All OS writes are dry-run."""
import fcntl
from service_fixture import Fixture

count = 0
def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)

def configure(f, **values):
    before = f.ok('snapshot')
    return f.rpc('configure', control=before['control'] | values,
                 epoch=before['epoch'], revision=before['revision'])

with Fixture(control={'enabled': False}) as f:
    f.ok('attachApp')
    lock = f.folder/'recovery.lock'
    inode = lock.stat().st_ino
    with lock.open('r+') as holder:
        fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        reply = configure(f, enabled=True)
        assert not reply['ok'] and reply['error'] == 'recoveryLockBusy', reply
        status = reply['status']
        assert not status['sleepDisabled'] and not status['ownsOverride'], status
        assert 'recoveryLockBusy' in f.logs()
        assert 'command request: pmset -a disablesleep 1' not in f.logs()
        passed('external transaction blocks a new helper OS write')
    status = f.step()['status']
    assert status['sleepDisabled'] and status['ownsOverride'], status
    assert lock.stat().st_ino == inode
    passed('helper retries on the same inode after the transaction releases')
    before = f.logs().count('command request: pmset -a disablesleep 0')
    with lock.open('r+') as holder:
        fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        reply = configure(f, enabled=False)
        assert not reply['ok'] and reply['error'] == 'recoveryLockBusy', reply
        status = reply['status']
        assert status['sleepDisabled'] and status['ownsOverride'], status
        assert f.logs().count('command request: pmset -a disablesleep 0') == before
        passed('external transaction blocks helper restoration and preserves journal')
    status = f.step()['status']
    assert not status['sleepDisabled'] and not status['ownsOverride'], status
    passed('deferred restoration completes when the lock releases')

with Fixture(control={'enabled': False}) as f:
    f.ok('attachApp')
    lock = f.folder/'recovery.lock'
    lock.chmod(0o666)
    reply = configure(f, enabled=True)
    assert not reply['ok'] and reply['error'] == 'recoveryLockUnavailable', reply
    status = reply['status']
    assert not status['sleepDisabled'] and not status['ownsOverride'], status
    assert 'recoveryLockUnavailable' in f.logs()
    lock.chmod(0o600)
    passed('unsafe lock refuses helper activation')

with Fixture() as f:
    f.ok('attachApp')
    assert f.ok('snapshot')['status']['ownsOverride']
    # Another serialized recovery has consumed this lease. A cached helper must
    # not use it to clear a later, unowned override.
    (f.folder/'power-ownership.json').unlink()
    status = f.config(enabled=False)['status']
    assert status['sleepDisabled'] and not status['ownsOverride'], status
    assert 'command request: pmset -a disablesleep 0' not in f.logs()
    passed('consumed journal is reloaded before restoring an override')

print('TOTAL', count, 'recovery lock integration scenarios passed')
