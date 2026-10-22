#!/usr/bin/env python3
"""Remote-display regressions through the real helper; all OS writes are dry-run."""
from service_fixture import Fixture

# Dry-run simulations have an isolated boot identity. The live ownership guard
# still refuses an unavailable OS identity, tested below with an unknown fixture boot.

count = 0

def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)

def holding(reply):
    assert reply['status']['ownsOverride'] and reply['status']['sleepDisabled'], reply
    assert not reply['protection'].get('blockReason'), reply

with Fixture(bootID='unknown') as f:
    reply = f.ok('snapshot')
    assert not reply['status']['ownsOverride'] and reply['protection']['blockReason'] == 'bootSessionUnavailable'
    assert 'pmset ' not in f.logs() and 'IOPMSleepSystem' not in f.logs()
    passed('unavailable boot identity cannot authorize an override')

for lid in ['open', 'closed']:
    with Fixture(lid=lid) as f:
        holding(f.ok('snapshot'))
        mark = len(f.logs())
        for closed in ['closed', 'open', 'closed']:
            holding(f.step(lid=closed, displayTopology='virtualOnly', displaySleeping=False))
        tail = f.logs()[mark:]
        assert 'disablesleep 0' not in tail and 'IOPMSleepSystem' not in tail and 'displaysleepnow' not in tail, tail
        assert f.ok('snapshot')['status']['displayRecovery']['phase'] == 'inactive'
        passed(lid + ': attaching a virtual display and lid changes preserve the active session')

for condition in ['ac', 'battery', 'any']:
    for lid in ['open', 'closed']:
        with Fixture(control={'powerCondition': condition}, lid=lid,
                     displayTopology='virtualOnly', displaySleeping=False) as f:
            reply = f.ok('snapshot')
            if condition == 'battery':
                assert not reply['status']['ownsOverride'], reply
            else:
                holding(reply)
            assert 'displaysleepnow' not in f.logs()
            passed(condition + '/' + lid + ': remote output respects migrated AC/OFF choices without a battery automatic rule')

for topology in ['externalUnverified', 'externalWithVirtual']:
    with Fixture(lid='closed', displayTopology='virtualOnly', displaySleeping=False) as f:
        holding(f.ok('snapshot'))
        mark = len(f.logs())
        holding(f.step(displayTopology=topology))
        assert 'disablesleep 0' not in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:]
        holding(f.step(displayTopology='virtualOnly'))
        assert 'displaysleepnow' not in f.logs()
        passed(topology + ': unclassified output does not end work or claim a physical handoff')

for topology in ['virtualOnly', 'externalWithVirtual']:
    with Fixture(lid='closed', displayTopology=topology, displaySleeping=False, displayClock=0) as f:
        holding(f.ok('snapshot'))
        assert 'displaysleepnow' not in f.logs()
        holding(f.step(displayTopology='none', displayClock=0))
        for clock in [10, 20, 30]:
            exhausted = f.step(displayClock=clock)
            holding(exhausted)
        assert exhausted['status']['displayRecovery'] == {
            'phase': 'stopped', 'requests': 3, 'maximumRequests': 3}, exhausted
        for clock in [31, 33, 35]:
            connected = f.step(displayTopology=topology, displayClock=clock)
            returned = f.step(displayTopology='none', displayClock=clock + 1)
            for reply in [connected, returned]:
                holding(reply)
                assert reply['status']['displayRecovery'] == exhausted['status']['displayRecovery'], reply
            assert f.logs().count('pmset displaysleepnow') == 3, f.logs()
        # Ending the actual own hold clears the incident; reconnecting never does.
        released = f.ok('stop')
        assert not released['status']['ownsOverride']
        assert released['status']['displayRecovery']['phase'] == 'inactive', released
        assert f.logs().count('pmset displaysleepnow') == 3, f.logs()
        passed(topology + ': reconnect cannot rearm stopped display recovery; ending the hold clears it')
    assert f.helper.poll() is not None and not f.folder.exists()

for topology in ['externalUnverified', 'externalWithVirtual']:
    with Fixture(lid='closed', displayTopology='virtualOnly') as f:
        mark = len(f.logs())
        assert not f.step(displayTopology=topology, nativeDisplayVerified=True)['status']['ownsOverride']
        assert 'disablesleep 0' in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:]
        holding(f.step(displayTopology='virtualOnly', nativeDisplayVerified=False))
        passed(topology + ': verified handoff fixture releases only our override')

for topology in ['externalUnverified', 'externalWithVirtual']:
    with Fixture(lid='closed', displayTopology=topology) as f:
        holding(f.ok('snapshot'))
        reply = f.step(thermal=2)
        assert not reply['status']['ownsOverride'] and reply['protection']['blockReason'] == 'thermal'
        assert 'IOPMSleepSystem' not in f.logs() and 'displaysleepnow' not in f.logs()
        passed(topology + ': own protection remains active without forcing a possibly native setup asleep')

with Fixture(lid='closed', displayTopology='virtualOnly') as f:
    reply = f.step(power='battery')
    assert not reply['status']['ownsOverride'] and not reply['status']['sleepDisabled'], reply
    assert 'IOPMSleepSystem' in f.logs() and 'displaysleepnow' not in f.logs()
    passed('unplug without a battery allowance releases the remote hold and requests sleep')

with Fixture(power='battery', lid='closed', displayTopology='virtualOnly') as f:
    before=f.ok('snapshot')
    rejected=f.rpc('startHold', minutes=3)
    assert rejected['error']=='unsupportedVersion' and rejected['control']==before['control'],rejected
    f.ok('attachApp'); holding(f.ok('startManualSession', minutes=3))
    assert 'IOPMSleepSystem' not in f.logs() and 'displaysleepnow' not in f.logs()
    reply = f.ok('stop')
    assert not reply['status']['ownsOverride']
    assert 'IOPMSleepSystem' in f.logs()
    passed('retired root hold is rejected; explicit battery manual preserves remote work and stop releases it')

for change, reason in [(dict(thermal=2), 'thermal'), (dict(thermal=3), 'thermal'), (dict(battery=None), 'sensor')]:
    for lid in ['open', 'closed']:
        with Fixture(lid=lid, displayTopology='virtualOnly', displaySleeping=False) as f:
            holding(f.ok('snapshot'))
            reply = f.step(**change)
            assert not reply['status']['ownsOverride'] and reply['protection']['blockReason'] == reason, reply
            assert ('IOPMSleepSystem' in f.logs()) == (lid == 'closed')
            assert 'displaysleepnow' not in f.logs()
            passed(lid + '/' + str(change) + ': remote hold retains protection')

with Fixture(lid='closed', displayTopology='virtualOnly', sleepDisabled=True) as f:
    reply = f.ok('snapshot')
    assert not reply['status']['ownsOverride'] and reply['protection']['blockReason'] == 'powerConflict', reply
    assert 'pmset ' not in f.logs() and 'IOPMSleepSystem' not in f.logs()
    passed('a foreign override is neither acquired nor cleared for remote use')

with Fixture(lid='closed', displayTopology='virtualOnly', fullWake=False) as f:
    assert not f.ok('snapshot')['status']['ownsOverride']
    assert 'pmset ' not in f.logs() and 'IOPMSleepSystem' not in f.logs()
    holding(f.step(fullWake=True))
    assert 'displaysleepnow' not in f.logs()
    passed('remote output does not turn Dark Wake into a working session')

print('TOTAL', count, 'remote-display scenarios passed')
