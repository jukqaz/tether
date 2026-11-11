#!/usr/bin/env python3
"""Legacy RPC/recovery compatibility with the v4 manual policy.
All OS writes are dry-run. This is not the finite-lease/physical acceptance suite.
"""
import json
import uuid
from service_fixture import Fixture

count = 0

def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)

def manual(reply):
    return reply['status']['manualSession']

def attached(**sensor):
    f = Fixture(control={'enabled': False}, manualClock=100, **sensor)
    f.ok('attachApp')
    return f

with attached() as f:
    before = f.ok('snapshot')['control']
    r = f.ok('startManualSession')
    assert manual(r)['active'] and manual(r)['holding'] and manual(r).get('until') is None, r
    assert r['control'] == before and not r['control']['enabled'], r
    r = f.ok('endManualSession')
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    assert r['control'] == before, r
    passed('manual AC unlimited start/end preserves the disabled automatic trigger and saved settings')

for lid in ['open', 'closed']:
    for minutes in [None, 60]:
        with attached(lid=lid) as f:
            before = f.ok('snapshot')['control']
            f.ok('startManualSession', **(dict(minutes=minutes) if minutes else {}))
            mark = len(f.logs())
            r = f.step(power='battery', manualClock=101)
            assert not manual(r)['active'] and not manual(r)['holding'] and not r['status']['ownsOverride'], r
            assert manual(r)['endReason'] == 'powerDisconnected' and manual(r)['batteryRemaining'] == 7200, r
            assert r['control'] == before, r
            if lid == 'closed':
                assert 'IOPMSleepSystem' in f.logs()[mark:], f.logs()[mark:]
            else:
                assert 'IOPMSleepSystem' not in f.logs()[mark:], f.logs()[mark:]
            r = f.step(power='ac', manualClock=102)
            assert not manual(r)['active'] and not r['status']['ownsOverride'], r
            passed(f'{lid}-lid AC manual {minutes or "unlimited"} ends on unplug by default without consuming a battery budget or reviving')

with attached(lid='closed') as f:
    for invalid in [0, -1, 121]:
        assert f.rpc('startManualSession', manualBatteryContinuationMinutes=invalid)['error'] == 'invalidRequest'
    r = f.ok('startManualSession', manualBatteryContinuationMinutes=15)
    before = r['control']
    assert manual(r)['holding'] and manual(r).get('until') is None, r
    mark = len(f.logs())
    r = f.step(power='battery', manualClock=101)
    assert not manual(r)['active'] and not manual(r)['holding'] and not r['status']['ownsOverride'], r
    assert manual(r)['endReason'] == 'powerDisconnected' and manual(r).get('until') is None, r
    assert manual(r)['batteryRemaining'] == 7200 and r['control'] == before, r
    assert 'disablesleep 0' in f.logs()[mark:] and 'IOPMSleepSystem' in f.logs()[mark:], f.logs()[mark:]
    r = f.step(power='ac', manualClock=500)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    r = f.step(power='battery', manualClock=510)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    r = f.step(manualClock=1001)
    assert not manual(r)['active'] and manual(r)['endReason'] == 'powerDisconnected', r
    passed('a valid legacy continuation field grants no battery carryover and cannot revive consumed work')

with attached(lid='closed') as f:
    f.config(limits={'batteryFloor': 30, 'maxHoldHours': 1})
    f.ok('startManualSession', manualBatteryContinuationMinutes=120)
    r = f.step(power='battery', manualClock=101)
    assert not manual(r)['active'] and manual(r)['endReason'] == 'powerDisconnected', r
    assert not r['status']['ownsOverride'] and not r['control'].get('batteryHoldUntil'), r
    r = f.ok('startManualSession', minutes=120)
    assert manual(r)['holding'] and manual(r)['batteryRemaining'] == 7200, r
    assert 7199 <= manual(r)['until'] - r['status']['updatedAt'] <= 7201, r
    assert r['control']['limits']['maxHoldHours'] == 1, r
    f.stop(); f.start()
    r = f.ok('attachApp')
    assert not manual(r)['active'] and manual(r)['batteryRemaining'] == 7200, r
    passed('legacy limits are preserved; only a new explicit battery request can start and restart never restores it')

with attached(power='battery') as f:
    f.ok('startManualSession', minutes=60)
    r = f.step(power='ac', manualClock=110)
    assert manual(r)['holding'] and manual(r)['startedOnBattery'], r
    assert 3589 <= manual(r)['until'] - r['status']['updatedAt'] <= 3591, r
    r = f.step(power='battery', manualClock=111)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    assert manual(r)['endReason'] == 'powerDisconnected' and manual(r).get('until') is None, r
    r = f.ok('startManualSession', minutes=15)
    assert manual(r)['holding'] and manual(r)['startedOnBattery'], r
    assert 899 <= manual(r)['until'] - r['status']['updatedAt'] <= 901, r
    r = f.step(manualClock=1011)
    assert not manual(r)['active'] and manual(r)['endReason'] == 'time', r
    passed('battery-origin work keeps its deadline on AC but a second unplug consumes it; only an explicit new start grants work')

with attached(lid='closed') as f:
    f.ok('startManualSession', manualBatteryContinuationMinutes=120)
    r = f.step(manualClock=1_000_000)
    assert manual(r)['holding'] and manual(r).get('until') is None, r
    mark = len(f.logs())
    r = f.step(power='battery', manualClock=1_000_001)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    assert manual(r)['endReason'] == 'powerDisconnected' and manual(r)['batteryRemaining'] == 7200, r
    assert 'IOPMSleepSystem' in f.logs()[mark:], f.logs()[mark:]
    r = f.ok('startManualSession', minutes=120)
    assert manual(r)['holding'] and manual(r)['startedOnBattery'], r
    assert 7199 <= manual(r)['until'] - r['status']['updatedAt'] <= 7201, r
    mark = len(f.logs())
    r = f.step(manualClock=1_007_201)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    assert manual(r)['endReason'] == 'time', r
    assert 'IOPMSleepSystem' in f.logs()[mark:], f.logs()[mark:]
    r = f.step(power='ac', manualClock=1_007_202)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    passed('long unlimited AC work ends on unplug; a separately started 120-minute battery request expires and never revives')

with attached() as f:
    f.config(enabled=True)
    before = f.ok('snapshot')['control']
    f.ok('startManualSession', minutes=1)
    mark = len(f.logs())
    r = f.step(manualClock=160)
    assert not manual(r)['active'] and r['status']['ownsOverride'], r
    assert r['control'] == before and 'disablesleep 0' not in f.logs()[mark:], r
    passed('manual expiry removes only its reason while the default AC trigger continues')

with attached() as f:
    f.config(enabled=True)
    f.ok('startManualSession')
    r = f.config(enabled=False)
    assert manual(r)['holding'] and not r['control']['enabled'], r
    r = f.ok('endManualSession')
    assert not r['status']['ownsOverride'], r
    passed('turning off the automatic trigger leaves the manual option running')

with attached(lid='closed') as f:
    f.config(enabled=True)
    f.ok('startManualSession', manualBatteryContinuationMinutes=120)
    before = f.ok('snapshot')['control']
    mark = len(f.logs())
    r = f.step(power='battery', manualClock=101)
    assert not manual(r)['active'] and not manual(r)['holding'] and not r['status']['ownsOverride'], r
    assert manual(r)['endReason'] == 'powerDisconnected' and not r['control'].get('batteryHoldUntil'), r
    assert r['control'] == before and 'IOPMSleepSystem' in f.logs()[mark:], r
    r = f.step(power='ac', manualClock=102)
    assert r['status']['ownsOverride'] and not manual(r)['active'], r
    passed('unplug consumes manual and automatic work together; reconnect restores only the saved AC automatic trigger')

with attached() as f:
    f.config(enabled=True)
    f.ok('startManualSession')
    r = f.ok('endManualSession')
    assert not manual(r)['active'] and r['status']['ownsOverride'] and r['control']['enabled'], r
    passed('ending the manual option preserves the default trigger')

with attached(power='battery') as f:
    assert f.rpc('startManualSession')['error'] == 'acRequired'
    for minutes in [0, -1]:
        assert f.rpc('startManualSession', minutes=minutes)['error'] == 'invalidRequest'
    assert f.rpc('startManualSession', minutes=240)['error'] == 'safetyBlocked'
    r = f.ok('startManualSession', minutes=120)
    assert manual(r)['holding'] and manual(r)['batteryRemaining'] == 7200, r
    r = f.step(manualClock=7300)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    passed('battery rejects unlimited and longer requests rather than silently clipping; explicit 120-minute request expires')

with attached(power='battery') as f:
    f.ok('startManualSession', minutes=120)
    f.step(manualClock=200)
    f.ok('endManualSession')
    r = f.ok('startManualSession', minutes=120)
    assert manual(r)['batteryRemaining'] == 7200, r
    original = manual(r)['until']
    assert f.rpc('startManualSession', minutes=120)['error'] == 'holdAlreadyRunning'
    assert manual(f.ok('snapshot'))['until'] == original
    r = f.step(manualClock=7300)
    assert manual(r)['active'] and manual(r)['batteryRemaining'] == 100, r
    r = f.step(manualClock=7400)
    assert not manual(r)['active'], r
    assert manual(f.ok('startManualSession', minutes=15))['active']
    passed('explicit end/new start creates a new bounded request; duplicate start cannot renew the existing deadline')

with attached(power='battery') as f:
    request_id = str(uuid.uuid4())
    f.ok('startManualSession', minutes=120, id=request_id)
    f.step(manualClock=200)
    f.ok('startManualSession', minutes=120, id=request_id)
    assert manual(f.ok('snapshot'))['batteryRemaining'] == 7100
    assert f.rpc('startManualSession', minutes=30, id=request_id)['error'] == 'requestIDConflict'
    passed('idempotent IPC retry cannot reset the session or reuse an ID with another duration')

with attached() as f:
    f.ok('startManualSession', manualBatteryContinuationMinutes=120)
    r = f.step(power='battery', manualClock=101)
    assert not manual(r)['active'] and manual(r)['endReason'] == 'powerDisconnected', r
    r = f.step(power='ac', manualClock=200)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    r = f.step(power='battery', manualClock=210)
    assert not manual(r)['active'] and manual(r)['batteryRemaining'] == 7200, r
    f.step(power='unknown', manualClock=220)
    r = f.step(power='battery', manualClock=230)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    assert manual(r).get('until') is None and manual(r)['endReason'] == 'powerDisconnected', r
    r = f.ok('startManualSession', minutes=15)
    assert manual(r)['holding'] and manual(r)['batteryRemaining'] == 7200, r
    passed('AC pulses and unknown power never revive a consumed request; only a new explicit battery start grants a fresh ceiling')

with attached(power='battery') as f:
    f.ok('startManualSession', minutes=120)
    f.step(manualClock=7300)
    f.step(power='ac', manualClock=7301)
    r = f.step(manualClock=7331)
    assert not manual(r)['active'] and manual(r)['batteryRemaining'] == 7200, r
    r = f.step(power='battery', manualClock=7332)
    assert not manual(r)['active'], r
    r = f.ok('startManualSession', minutes=15)
    assert manual(r)['holding'], r
    passed('AC never revives an expired request; a new explicit battery request can start')

with attached(power='battery') as f:
    f.ok('startManualSession', minutes=120)
    f.step(manualClock=200)
    f.stop(); f.start()
    r = f.ok('attachApp')
    assert not manual(r)['active'] and manual(r)['batteryRemaining'] == 7200, r
    r = f.ok('startManualSession', minutes=120)
    assert manual(r)['batteryRemaining'] == 7200, r
    passed('helper restart cannot resume old work; a new explicit request gets its own bounded deadline')

with attached(power='battery') as f:
    f.config(limits={'batteryFloor': 30, 'maxHoldHours': 1})
    r = f.ok('startManualSession', minutes=120)
    assert manual(r)['batteryRemaining'] == 7200, r
    r = f.step(manualClock=3700)
    assert manual(r)['active'] and manual(r)['batteryRemaining'] == 3600, r
    r = f.step(manualClock=7300)
    assert not manual(r)['active'], r
    passed('obsolete cumulative-hour settings do not alter the explicitly selected current request; its two-hour deadline still ends')

for observation in [dict(thermal=2), dict(power='battery', battery=30)]:
    # Start directly on the source under test so protection is independent of
    # the earlier AC-departure consumption rule.
    on_battery = observation.get('power') == 'battery'
    with attached(lid='closed', power='battery' if on_battery else 'ac') as f:
        f.ok('startManualSession', **(dict(minutes=120) if on_battery else {}))
        r = f.step(manualClock=101, **observation)
        assert not manual(r)['active'] and not r['status']['ownsOverride'], r
        assert manual(r)['endReason'] == 'protection' and r['protection']['blockReason'], r
        passed('manual option with the basic trigger off obeys protection: ' + str(observation))

for topology in ['virtualOnly', 'externalUnverified', 'externalWithVirtual', 'unknown']:
    with attached(lid='closed') as f:
        f.ok('startManualSession')
        r = f.step(displayTopology=topology, manualClock=101)
        assert manual(r)['holding'] and r['status']['ownsOverride'], r
        passed('remote/display changes preserve an already owned manual session: ' + topology)

with attached(power='battery', lid='closed') as f:
    f.ok('startManualSession', minutes=1)
    mark = len(f.logs())
    r = f.step(manualClock=160, foreignKeepAwake=True)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    assert r['status']['sleepDeferralReason'] == 'otherRequests' and 'IOPMSleepSystem' not in f.logs()[mark:], r
    passed('manual expiry releases only Tether while another application still requests work')

with attached() as f:
    f.ok('startManualSession')
    r = f.ok('detachApp')
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    f.ok('attachApp')
    assert not manual(f.ok('snapshot'))['active']
    passed('app detach terminates the manual option and reconnect does not revive it')

with attached() as f:
    f.ok('startManualSession')
    r = f.step(systemSleeping=True)
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    r = f.step(systemSleeping=False, manualClock=101)
    assert not manual(r)['active'], r
    passed('explicit macOS sleep ends manual work; wake does not revive it')

with attached() as f:
    f.ok('startManualSession')
    r = f.ok('stop')
    assert not manual(r)['active'] and not r['status']['ownsOverride'] and not r['control']['enabled'], r
    passed('the master stop still ends every Tether reason')

with attached(power='battery') as f:
    # The discarded v2 battery ledger is not the writer's durable authority.
    # An unreadable writer journal must still prevent every manual acquisition.
    state = f.folder / 'power-writer.json'
    assert not state.exists(), list(f.folder.iterdir())
    state.mkdir()
    mark = len(f.logs())
    for expected_error in ['powerWriterUnresolved', 'holdAlreadyRunning']:
        r = f.rpc('startManualSession', minutes=30)
        assert not r['ok'] and r['error'] == expected_error, r
        assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
        assert manual(r)['active'] and not manual(r)['holding'], r
        assert 1799 <= manual(r)['until'] - r['status']['updatedAt'] <= 1801, r
    assert 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    observed = f.ok('snapshot')
    assert not observed['status']['ownsOverride'] and not manual(observed)['holding'], observed
    assert observed['protection']['lastError'] == 'powerWriterUnresolved', observed
    assert state.is_dir(), 'The unresolved writer journal must be preserved'
    state.rmdir()
    passed('unreadable durable writer journal blocks manual acquisition and subsequent starts')

with Fixture(control={'enabled': False}, manualClock=100) as f:
    assert f.rpc('startManualSession')['error'] == 'sessionUnavailable'
    assert not manual(f.ok('snapshot'))['active']
    passed('manual start requires an attached controlling app')

with attached(sleepDisabled=True) as f:
    mark = len(f.logs())
    r = f.rpc('startManualSession')
    observed = f.ok('snapshot')
    assert not observed['status']['ownsOverride'] and observed['status']['sleepDisabled'], observed
    assert not manual(observed)['active'] and observed['protection']['blockReason'] == 'powerConflict', observed
    assert 'disablesleep ' not in f.logs()[mark:], f.logs()[mark:]
    passed('manual start cannot claim or clear another owner\'s global sleep setting')

with Fixture(control={'enabled': True, 'powerCondition': 'battery', 'automaticHoldMinutes': 240},
             manualClock=100) as f:
    report = json.loads((f.folder / 'migration-report.json').read_text())
    original = f.folder / 'migrations' / report['backupName']
    original_bytes = original.read_bytes()
    assert json.loads(original_bytes) == {'enabled': True, 'limits': {'batteryFloor': 30},
                                        'powerCondition': 'battery', 'automaticHoldMinutes': 240}
    assert 'batteryAutomaticRetired' in report['cleared'], report
    r = f.step(power='battery', manualClock=101)
    assert r['control']['automaticHoldMinutes'] == 240 and r['control']['powerCondition'] == 'ac', r
    assert not r['control']['enabled'], r
    assert not r['control'].get('batteryHoldUntil'), r
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    f.stop(); f.start()
    r = f.ok('snapshot')
    assert not r['control']['enabled'] and not r['control'].get('batteryHoldUntil'), r
    assert not manual(r)['active'] and not r['status']['ownsOverride'], r
    assert original.read_bytes() == original_bytes
    passed('legacy battery automatic migrates to AC/OFF without restoring work; original settings remain unchanged in the migration backup')

print(f'{count} helper manual-session checks passed (OS writes simulated)', flush=True)
