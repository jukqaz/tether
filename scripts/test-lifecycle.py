#!/usr/bin/env python3
"""Exercise the real helper with isolated files and dry-run power commands only."""
import json
from service_fixture import Fixture

count = 0


def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)


def configure(f):
    before = f.ok('snapshot')
    return f.rpc('configure', control=before['control'], epoch=before['epoch'], revision=before['revision'])


with Fixture() as f:
    f.ok('attachApp')
    mark = len(f.logs())
    r = f.ok('detachApp')
    assert r['control']['enabled'] and not r['status']['appConnected']
    assert not r['status']['ownsOverride'] and r['status']['lastEvent'] == 'clamshellReleased'
    log = f.logs()[mark:]
    assert 'app requested detach' in log and 'appConnected=false' in log
    assert 'sleep now: clamshell off' not in log and 'IOPMSleepSystem' not in log
    passed('app detach releases power without falsely recording a sleep request')
    f.ok('attachApp')
    mark = len(f.logs())
    r = f.step(external=True, nativeDisplayVerified=True)
    assert not r['status']['ownsOverride'] and r['status']['lastEvent'] == 'clamshellReleased'
    assert 'sleep now: clamshell off' not in f.logs()[mark:]
    passed('native display handoff is a release, not a user sleep command')

# Missing app detection uses the same ten-minute boundary in an isolated clock.
# It does not alter real wall time, files, launchd jobs or power settings.
missing = '/tmp/tether-removed-fixture/Tether.app/Contents/MacOS/Tether'
with Fixture(control={'appPath': missing}, appPresenceClock=0) as f:
    f.ok('attachApp')
    assert f.ok('snapshot')['status']['ownsOverride']
    f.patch(appPresenceClock=599)
    configure(f)
    assert 'would remove' not in f.logs()
    f.patch(appPresenceClock=600, commandFailure=True)
    r = configure(f)
    assert r['error'] == 'pmsetFailed' and r['status']['ownsOverride']
    assert json.loads((f.folder / 'power-ownership.json').read_text())['owned']
    assert 'removal deferred' in f.logs() and 'would remove' not in f.logs()
    passed('orphan cleanup retains helper and journal when sleep release fails')
    f.patch(commandFailure=False)
    configure(f)
    assert not json.loads((f.folder / 'power-ownership.json').read_text())['owned']
    assert 'would remove the helper' in f.logs()
    passed('orphan cleanup retries restoration before permitting removal')

for scope in ['Battery', 'AC']:
    for failure, error in [('commandFailure', 'pmsetFailed'), ('commandNoEffect', 'powerVerificationFailed'),
                           ('powerModeUnreadable', 'lowPowerUnreadable')]:
        with Fixture(control={'enabled': False, 'appPath': missing}, appPresenceClock=0) as f:
            f.stop()
            state_path = f.folder / 'helper-state.json'
            state = json.loads(state_path.read_text()) if state_path.exists() else {}
            key = 'saved' + scope + 'LowPower'
            state[key] = 0
            state_path.write_text(json.dumps(state))
            f.patch(**{scope.lower() + 'PowerMode': 1, failure: True})
            f.start()
            f.patch(appPresenceClock=600)
            r = configure(f)
            assert r['error'] == error, r
            assert json.loads(state_path.read_text())[key] == 0
            assert 'removal deferred' in f.logs() and 'would remove' not in f.logs()
            f.patch(**{failure: False})
            configure(f)
            assert key not in json.loads(state_path.read_text())
            assert 'would remove the helper' in f.logs()
            passed(f'{scope} restore {failure} preserves recovery until verified')

with Fixture(control={'enabled': False, 'appPath': missing}, appPresenceClock=0,
             externalOverride=True) as f:
    mark = len(f.logs())
    f.patch(appPresenceClock=600)
    configure(f)
    assert 'would remove the helper' in f.logs()[mark:]
    assert 'disablesleep 0' not in f.logs()[mark:]
    passed('orphan cleanup leaves another app sleep override alone')

print('TOTAL', count, 'lifecycle scenarios passed')
