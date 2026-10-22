#!/usr/bin/env python3
"""Display observation recovery and legacy DarkWake repair through the real helper."""
import json
import time
from service_fixture import Fixture

count = 0
def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)

with Fixture(lid='closed', displaySleeping=True, displayClock=0) as f:
    mark = len(f.logs())
    for clock in [10, 20, 30]:
        r = f.step(displaySleeping=None, displayClock=clock)
        assert r['status']['ownsOverride'] and not r['protection'].get('blockReason')
        r = f.step(displaySleeping=True, displayClock=clock + 1)
        assert r['status']['ownsOverride']
    assert 'IOPMSleepSystem' not in f.logs()[mark:] and 'displaysleepnow' not in f.logs()[mark:]
    assert 'observation recovered' in f.logs()
    passed('transient display-query failures recover without sleep or repeated screen-off')
    f.step(displaySleeping=None, displayClock=100)
    assert f.step(displayClock=109.9)['status']['ownsOverride']
    r = f.step(displayClock=110)
    assert not r['protection'].get('blockReason') and r['status']['ownsOverride']
    assert r['status']['displayRecovery']['phase'] == 'stopped'
    assert 'observation unavailable beyond budget' in f.logs() and 'sleeping=unknown' in f.logs()
    assert 'IOPMSleepSystem' not in f.logs()[mark:]
    passed('continuous unknown display stops screen recovery while retaining work')
    before = f.ok('snapshot')['control']
    assert f.rpc('startHold', minutes=3)['error'] == 'unsupportedVersion'
    assert f.ok('snapshot')['control'] == before
    f.step(lid='open', displaySleeping=False)
    f.step(power='battery')
    f.ok('attachApp')
    assert f.ok('startManualSession', minutes=3)['status']['ownsOverride']
    passed('screen limitation never blocks a valid work timer')

with Fixture(lid='closed', displaySleeping=True, displayClock=0) as f:
    f.step(displaySleeping=None, displayClock=1)
    r = f.step(displaySleeping=False, displayClock=2)
    assert r['status']['ownsOverride'] and not r['protection'].get('blockReason')
    # Recovery before its 10-second retry should need only the first request.
    f.step(displayClock=11)
    r = f.step(displaySleeping=True, displayClock=11.5)
    assert r['status']['ownsOverride'] and not r['protection'].get('blockReason')
    assert f.logs().count('pmset displaysleepnow') == 1 and 'IOPMSleepSystem' not in f.logs()
    passed('known wake after missing observation recovers and keeps the session')

# Replay build 47 failure timing (0=request, 1=awake, 10=old stop).
with Fixture(lid='closed', displaySleeping=False, displayClock=0) as f:
    f.config(); assert f.logs().count('pmset displaysleepnow') == 1
    for clock in [1, 4, 7, 10]:r=f.step(displayClock=clock)
    assert r['status']['ownsOverride'] and not r['protection'].get('blockReason')
    assert f.logs().count('pmset displaysleepnow') == 2
    for clock in [13, 90, 300]:r=f.step(displaySleeping=True, displayClock=clock)
    assert r['status']['ownsOverride'] and 'IOPMSleepSystem' not in f.logs()
    assert f.logs().count('activity: display recovery requested') == 1
    assert f.logs().count('activity: display sleep confirmed') == 1
    assert 'activity: display recovery stopped' not in f.logs()
    passed('recorded build 47 display wake recovers on second request')

with Fixture(lid='closed', displaySleeping=False, displayClock=0) as f:
    f.config(); assert f.logs().count('pmset displaysleepnow') == 1
    for clock in [10, 20, 30]:r=f.step(displayClock=clock)
    assert not r['protection'].get('blockReason') and r['status']['ownsOverride']
    assert r['status']['displayRecovery']['phase'] == 'stopped'
    assert f.logs().count('pmset displaysleepnow') == 3
    assert 'screen recovery exhausted, work retained' in f.logs() and 'IOPMSleepSystem' not in f.logs()
    assert f.logs().count('activity: display recovery requested') == 2
    assert f.logs().count('activity: display recovery stopped') == 1
    mark=len(f.logs());f.step(displaySleeping=True, displayClock=31)
    assert 'displaysleepnow' not in f.logs()[mark:]
    passed('permanent screen opposition exhausts only the screen retry budget')

for values in [dict(lid='open'), dict(external=True), dict(power='battery'), dict(thermal=3), dict(battery=None)]:
    with Fixture(lid='closed', displaySleeping=False, displayClock=0) as f:
        f.config(); assert f.logs().count('pmset displaysleepnow') == 1
        mark=len(f.logs());r=f.step(displayClock=10, **values)
        assert 'displaysleepnow' not in f.logs()[mark:]
        if values.get('thermal') or 'battery' in values:
            assert r['protection'].get('blockReason') and not r['status']['ownsOverride']
        passed('display retry yields to current policy or protection: '+str(values))

with Fixture(lid='closed', displaySleeping=None, displayClock=0) as f:
    # Start the observation budget without issuing an unverified display command.
    f.config()
    assert f.step(displayClock=9)['status']['ownsOverride']
    r = f.step(displayClock=10)
    assert not r['protection'].get('blockReason') and r['status']['ownsOverride']
    assert r['status']['displayRecovery']['phase'] == 'stopped'
    assert f.logs().count('pmset displaysleepnow') == 0
    assert 'IOPMSleepSystem' not in f.logs()
    passed('initial unknown panel state never requests all-display sleep or ends work')

for cause in ['foreignDisplayRequest', 'displayRequestsUnavailable']:
    with Fixture(lid='closed', displaySleeping=False, displayClock=0, **{cause: True}) as f:
        for clock in [10, 20, 30]: r = f.step(displayClock=clock)
        assert r['status']['ownsOverride'] and not r['protection'].get('blockReason')
        assert r['status']['displayRecovery']['phase'] == 'deferred'
        assert 'displaysleepnow' not in f.logs() and 'IOPMSleepSystem' not in f.logs()
        passed('foreign screen needs defer screen commands without stopping work: '+cause)

# Exact event timestamps from the physical failure, with only nonprivate event categories.
header = '2026-09-29 '
power_log = header + "12:04:36 +0900 Sleep Entering DarkWake state due to 'Software Sleep'\n"
power_log += header + "12:04:43 +0900 Sleep Entering Sleep state due to 'Software Sleep'\n"
for at in ['12:05:40', '12:14:36', '12:15:14', '12:18:19', '12:18:39', '12:18:52', '12:19:09', '12:20:30']:
    power_log += header + at + ' +0900 DarkWake DarkWake from Deep Idle\n'
power_log += header + '12:21:13 +0900 Wake Wake from Deep Idle\n'
from datetime import datetime
start = datetime.fromisoformat('2026-09-29T12:04:36+09:00').timestamp() + .24
end = datetime.fromisoformat('2026-09-29T12:21:13+09:00').timestamp() + .52
legacy = dict(sleptAt=start, wokeAt=end, percentBefore=80, percentAfter=80,
              onBatteryBefore=False, onBatteryAfter=False, byTether=True, darkWakes=0)

for complete in [True, False]:
    events = power_log if complete else power_log.rsplit('\n', 2)[0] + '\n'
    with Fixture(powerEventLog=events) as f:
        f.stop()
        path = f.folder / 'usage.json'
        usage = json.loads(path.read_text())
        usage['sleepLog'] = {'recent': [legacy]}
        path.write_text(json.dumps(usage))
        f.start()
        if complete:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                row = json.loads(path.read_text())['sleepLog']['recent'][0]
                if row.get('darkWakeCountVerified'): break
                time.sleep(.02)
            assert row['darkWakes'] == 8 and row['darkWakeCountVerified'] is True
            assert row['sleptAt'] == start and row['wokeAt'] == end and row['percentBefore'] == 80
            assert 'sleep log reconciled' in f.logs()
            f.stop(); f.start()
            assert json.loads(path.read_text())['sleepLog']['recent'][0]['darkWakes'] == 8
            passed('startup repairs legacy 0 to OS-backed 8 and preserves the corrected record on restart')
        else:
            time.sleep(.2)
            row = json.loads(path.read_text())['sleepLog']['recent'][0]
            assert row['darkWakes'] == 0 and row.get('darkWakeCountVerified') is not True
            passed('incomplete OS interval never turns the old zero into a verified zero')
print('TOTAL', count, 'power-fix scenarios passed')
