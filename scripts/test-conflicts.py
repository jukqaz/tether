#!/usr/bin/env python3
"""Conflict transitions using the real helper and socket, with isolated OS writes."""
import time
import json
from service_fixture import Fixture

count = 0

def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)

def await_status(f, predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while True:
        reply = f.ok('snapshot')
        if predicate(reply['status']):
            return reply
        assert time.monotonic() < deadline, reply['status']
        time.sleep(0.03)

for readings, label in [({'thermal': 3}, 'critical heat'), ({'battery': None}, 'required battery reading failure')]:
    with Fixture(lid='closed', external=False) as f:
        f.step(**readings)
        mark = len(f.logs())
        f.step(lid='open', temperature=30, thermal=0, battery=80)
        assert 'IOPMSleepSystem' not in f.logs()[mark:], label + ': sleep repeated after opening lid'
        passed(label + ' stop cancels sleep requests when the lid opens')

# Failed sleep calls run through the same retry path as production.
for change, label in [({'lid': 'open'}, 'lid opens'),
                      ({'power': 'ac', 'external': True, 'nativeDisplayVerified': True}, 'verified native handoff'),
                      ({'fullWake': False}, 'Dark Wake'),
                      ({'power': 'unknown'}, 'unknown power'),
                      ({'externalOverride': True}, 'foreign override appears')]:
    with Fixture(lid='closed', sleepFailure=True) as f:
        f.step(power='battery')
        assert 'IOPMSleepSystem' in f.logs()
        f.step(**change)
        mark = len(f.logs())
        time.sleep(0.65)
        assert 'IOPMSleepSystem' not in f.logs()[mark:], label
        assert 'pmset sleepnow' not in f.logs()[mark:], label
        passed('failed-sleep retry cancels when ' + label)

with Fixture(lid='closed', external=False, sleepFailure=True) as f:
    heated = f.step(thermal=3)
    assert heated['status']['lastEvent'] == 'overheatSleep'
    stopped = f.ok('stop')
    assert not stopped['control']['enabled'] and not stopped['status']['ownsOverride']
    assert not stopped['status']['sleepDisabled']
    # Stop cancels the protection retry. R31 still retains responsibility for
    # ending the same owned, closed-lid session after its override was released.
    # A fresh closed-lid request must not be mistaken for an old protection retry.
    # snapshot is read-only; wait for the queued evaluation rather than assuming
    # that stop's synchronous reply already contains the new termination event.
    released = await_status(f, lambda status: status['lastEvent'] == 'lidSleep')
    assert not released['status']['ownsOverride'] and not released['status']['sleepDisabled']
    f.step(lid='open')
    mark = len(f.logs())
    time.sleep(0.65)
    assert 'IOPMSleepSystem' not in f.logs()[mark:]
    assert 'pmset sleepnow' not in f.logs()[mark:]
    passed('stop ends protection retry; own closed-lid release is revalidated and opening cancels it')

for blocker in ['foreignKeepAwake', 'sleepRequestsUnavailable']:
    with Fixture(lid='closed', external=False, sleepFailure=True) as f:
        f.step(thermal=3)
        f.patch(**{blocker: True})
        mark = len(f.logs())
        stopped = f.ok('stop')
        reason = 'otherRequests' if blocker == 'foreignKeepAwake' else 'observationUnavailable'
        deferred = await_status(f, lambda status: status.get('sleepDeferralReason') == reason)
        time.sleep(0.65)
        assert not stopped['control']['enabled'] and not deferred['status']['ownsOverride']
        assert not deferred['status']['sleepDisabled']
        assert deferred['status']['sleepDeferralReason'] == reason
        assert 'IOPMSleepSystem' not in f.logs()[mark:] and 'pmset sleepnow' not in f.logs()[mark:]
        passed('stopped protection cannot bypass closed-lid coexistence: ' + blocker)

with Fixture(external=True) as f:
    f.ok('sleep')
    assert 'IOPMSleepSystem' in f.logs()
    passed('explicit user sleep still works with an open lid and external display')

with Fixture(lid='closed', battery=73) as f:
    r = f.step(systemSleeping=True)
    record = json.loads((f.folder / 'usage.json').read_text())['sleepLog']['open']
    assert record['percentBefore'] == 73 and record['onBatteryBefore'] is False
    assert not r['status']['ownsOverride']
    mark = len(f.logs())
    for _ in range(25):
        f.config()
    assert 'pmset ' not in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:]
    assert f.rpc('startHold', minutes=15)['error'] == 'unsupportedVersion'
    assert f.rpc('startManualSession', minutes=15)['error'] == 'sessionUnavailable'
    r = f.step(systemSleeping=False, fullWake=False)
    assert not r['status']['ownsOverride']
    r = f.step(fullWake=True)
    assert r['status']['ownsOverride']
    passed('OS sleep announcement suppresses queued events until a full wake')

for condition in ['ac', 'battery', 'any']:
    for topology in ['externalUnverified', 'externalWithVirtual', 'unknown']:
        for lid in ['open', 'closed']:
            with Fixture(control={'powerCondition': condition}, displayTopology=topology, lid=lid,
                         nativeDisplayVerified=topology != 'unknown') as f:
                for _ in range(4):
                    f.config()
                f.ok('stop'); f.ok('resume')
                assert 'pmset ' not in f.logs() and 'IOPMSleepSystem' not in f.logs()
                passed('AC display coexistence ' + '/'.join([condition, topology, lid]))

# Power-mode preservation covers low-power-only and high-power-capable pmset formats.
for key, originals in [('lowpowermode', [0, 1]), ('powermode', [0, 1, 2])]:
    for original in originals:
        for power in ['battery', 'ac']:
            readings = dict(power=power, lid='closed', powerModeKey=key,
                            batteryPowerMode=original, acPowerMode=original)
            with Fixture(**readings) as f:
                if power == 'battery':
                    f.ok('attachApp'); f.ok('startManualSession', minutes=15)
                else: f.step(thermal=2)
                mark = len(f.logs())
                f.ok('stop')
                assert not any('powermode' in line for line in f.logs().splitlines() if 'command request: pmset' in line)
                passed('original power mode left unchanged ' + '/'.join([key, str(original), power]))

for power in ['battery', 'ac']:
    for foreign in [0, 2]:
        with Fixture(power=power, lid='closed') as f:
            if power == 'battery':
                f.ok('attachApp'); f.ok('startManualSession', minutes=15)
            else: f.step(thermal=2)
            f.step(**{('externalBatteryPowerMode' if power == 'battery' else 'externalACPowerMode'): foreign})
            mark = len(f.logs())
            f.ok('stop')
            assert 'powermode' not in f.logs()[mark:]
            passed('external power mode preserved ' + power + '/' + str(foreign))

# Seeded transition sequences reproduce docks flapping and overlapping sources of events.
import random
for seed in [40, 1040, 2040]:
    rng = random.Random(seed)
    with Fixture() as f:
        for index in range(200):
            change = dict(power=rng.choice(['ac', 'battery', 'unknown']),
                          lid=rng.choice(['open', 'closed']), fullWake=rng.choice([True, False]),
                          displayTopology=rng.choice(['none', 'externalUnverified', 'virtualOnly', 'externalWithVirtual', 'unknown']),
                          powerClock=100 + index * 2)
            change['nativeDisplayVerified'] = change['displayTopology'] in ['externalUnverified', 'externalWithVirtual'] and rng.choice([True, False])
            mark = len(f.logs()); r = f.step(**change); tail = f.logs()[mark:]
            assert r['ok']
            if not change['fullWake'] or change['power'] == 'unknown':
                assert 'disablesleep 1' not in tail and 'IOPMSleepSystem' not in tail
            if change['power'] == 'ac' and (change['nativeDisplayVerified'] or change['displayTopology'] == 'unknown'):
                assert 'disablesleep 1' not in tail and 'displaysleepnow' not in tail and 'IOPMSleepSystem' not in tail
            if change['displayTopology'] != 'none':
                assert 'displaysleepnow' not in tail
            if change['lid'] == 'open':
                assert 'displaysleepnow' not in tail and 'IOPMSleepSystem' not in tail
        passed('seed ' + str(seed) + ': 200 dock/power/lid/wake transitions')


with Fixture(external=True, sleepFailure=True) as f:
    f.ok('sleep')
    deadline = time.monotonic() + 12
    while 'pmset sleepnow' not in f.logs() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert f.logs().count('[dry-run] IOPMSleepSystem') == 20
    assert f.logs().count('command request: pmset sleepnow') == 1
    mark = len(f.logs()); f.config(); time.sleep(0.6)
    assert 'IOPMSleepSystem' not in f.logs()[mark:]
    passed('failed explicit sleep has 20 bounded attempts and one fallback')

import concurrent.futures
with Fixture(external=True, nativeDisplayVerified=True) as f:
    before = f.ok('snapshot')
    def configure(index):
        return f.rpc('configure', control=before['control'] | {'automaticHoldMinutes': 30 + index},
                     epoch=before['epoch'], revision=before['revision'])
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        replies = list(pool.map(configure, range(1, 33)))
    assert sum(r['ok'] for r in replies) == 1
    assert all(r['ok'] or r['error'] == 'staleRevision' for r in replies)
    assert 'pmset ' not in f.logs()
    passed('32 concurrent settings requests preserve revision ownership without OS writes')


with Fixture(sleepFailure=True) as f:
    f.ok('sleep')
    assert 'IOPMSleepSystem' in f.logs()
    r = f.ok('resume')
    assert r['status']['ownsOverride']
    mark = len(f.logs()); time.sleep(0.65)
    assert 'IOPMSleepSystem' not in f.logs()[mark:]
    passed('explicit resume cancels the previous user sleep retry')

with Fixture(sleepDisabled=True) as f:
    assert f.rpc('sleep')['error'] == 'powerConflict'
    assert 'IOPMSleepSystem' not in f.logs() and 'pmset ' not in f.logs()
    passed('explicit sleep reports a foreign override without altering it')

print('TOTAL', count, 'conflict scenarios passed')
