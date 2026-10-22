#!/usr/bin/env python3
"""Cross-feature v4 regressions through the real helper; every OS write is dry-run."""
import copy
import json
import time
import uuid
from service_fixture import Fixture

count = 0


def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)


def fixture(**facts):
    return Fixture(control=dict(enabled=False), legacy_state=False,
                   **(dict(manualClock=100) | facts))


def lease(power='ac', manual=False, session=None, sequence=1, request_id=None):
    request_id = request_id or str(uuid.uuid4())
    result = dict(version=1, executionVersion=3, sessionID=session or str(uuid.uuid4()), sequence=sequence,
                  power=power, expiry=115, reasons=['manual'] if manual else ['automatic'],
                  configuration=dict(enabled=True, automaticEnabled=not manual, condition='ac',
                                     automaticMinutes=60, limits=dict(batteryFloor=30)),
                  lidPermit=dict(powerScopes=[power], disconnectAction='sleepIfClosed', protectiveAction='sleepIfClosed'))
    if manual:
        result.update(manualRequestID=request_id, manualDeadline=1900, manualStartedOnBattery=power == 'battery')
    if power == 'battery':
        result['manualBatteryMaximumDeadline'] = 7300
        result['lidPermit'].update(batteryPermitID=request_id, batteryDuration=1800,
                                   batteryDeadline=1900, batteryMaximumDeadline=7300)
    return result


def empty(packet, **changes):
    result = copy.deepcopy(packet)
    result.update(reasons=[], expiry=None, **changes)
    for key in ['manualDeadline', 'manualRequestID', 'manualBatteryMaximumDeadline', 'lidPermit']:
        result.pop(key, None)
    return result


def attach(f, packet):
    before = f.ok('snapshot')
    prepared = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty(packet))
    return f.ok('attachWorkSession', epoch=prepared['epoch'], revision=prepared['revision'], workSession=packet)


def step(f, **facts):
    f.patch(**facts)
    return f.rpc('markDiagnostic')


def sleeps(f):
    return f.logs().count('IOPMSleepSystem [v3')


def receipt(f):
    return json.loads((f.folder / 'helper-state.json').read_text())['lidEndReceipt']


with fixture(lid='closed') as f:
    packet = lease()
    assert attach(f, packet)['status']['ownsOverride']
    mark = len(f.logs())
    for topology in ['virtualOnly', 'externalUnverified', 'externalWithVirtual', 'unknown']:
        reply = step(f, displayTopology=topology)
        assert reply['status']['ownsOverride'] and reply['status']['sleepDisabled'], reply
        assert reply['status']['workSession']['expiry'] == 115, reply
    assert 'disablesleep 0' not in f.logs()[mark:] and sleeps(f) == 0, f.logs()
    reply = f.ok('stop')
    assert not reply['status']['ownsOverride'] and not reply['status']['sleepDisabled'], reply
    passed('remote, unclassified and unavailable display observations preserve the finite work request until explicit stop')

with fixture(lid='closed') as f:
    attach(f, lease())
    step(f, displayTopology='unknown')
    reply = step(f, thermal=2, manualClock=101)
    assert not reply['status']['ownsOverride'] and reply['protection']['blockReason'] == 'thermal', reply
    assert sleeps(f) == 1 and receipt(f)['kind'] == 'protection', reply
    passed('a display observation gap never bypasses thermal protection or own restoration')

for observation in [dict(foreignKeepAwake=True), dict(sleepRequestsUnavailable=True),
                    dict(foreignDisplayRequest=True), dict(foreignNetworkRequest=True)]:
    for ending in [dict(power='battery'), dict(thermal=2)]:
        with fixture(lid='closed') as f:
            attach(f, lease())
            mark = len(f.logs())
            reply = step(f, manualClock=101, **observation, **ending)
            assert not reply['status']['ownsOverride'] and not reply['status']['sleepDisabled'], reply
            end = receipt(f)
            assert end['phase'] == 'consumed' and end['outcome'] == 'commandAccepted', end
            assert sleeps(f) == 1 and 'pmset sleepnow' not in f.logs()[mark:], f.logs()
            assert 'displaysleepnow' not in f.logs()[mark:], f.logs()
            assert all(f.readings[key] == value for key, value in observation.items())
            if 'thermal' in ending:
                assert reply['protection']['blockReason'] == 'thermal', reply
            passed(str(ending) + ': own release leaves independent diagnostic requests untouched and sends the selected one-shot Sleep / ' + str(observation))

with fixture(lid='closed', sleepDisabled=True) as f:
    reply = attach(f, lease())
    assert not reply['status']['ownsOverride'] and reply['status']['sleepDisabled'], reply
    reply = step(f, power='battery', manualClock=101)
    assert not reply['status']['ownsOverride'] and reply['status']['sleepDisabled'], reply
    assert 'disablesleep 0' not in f.logs() and sleeps(f) == 0, f.logs()
    passed('a foreign global sleep override is never adopted, cleared or bypassed by a selected ending')

for observation in [dict(foreignKeepAwake=True), dict(sleepRequestsUnavailable=True)]:
    with fixture(lid='closed') as f:
        attach(f, lease())
        pending = step(f, power='battery', manualClock=101, commandFailure=True, **observation)
        assert pending['status']['ownsOverride'] and sleeps(f) == 0, pending
        end_id = receipt(f)['id']
        assert receipt(f)['phase'] == 'captured', pending
        step(f, manualClock=102, foreignKeepAwake=False, sleepRequestsUnavailable=False)
        assert sleeps(f) == 0 and receipt(f)['id'] == end_id
        recovered = step(f, commandFailure=False, manualClock=106)
        assert not recovered['status']['ownsOverride'] and not recovered['status']['sleepDisabled'], recovered
        assert sleeps(f) == 1 and receipt(f)['id'] == end_id and receipt(f)['phase'] == 'consumed', recovered
        step(f, manualClock=107)
        assert sleeps(f) == 1
        passed('diagnostic changes do not bypass own restoration; its fixed retry window ends the same incident once / ' + str(observation))

for change in [dict(lid='open'), dict(power='ac'), dict(manualClock=161), dict(systemSleeping=True)]:
    with fixture(lid='closed') as f:
        attach(f, lease())
        step(f, power='battery', manualClock=101, commandFailure=True)
        end_id = receipt(f)['id']
        assert receipt(f)['phase'] == 'captured' and sleeps(f) == 0
        step(f, **(dict(commandFailure=False, manualClock=102) | change))
        assert receipt(f)['id'] == end_id and receipt(f)['phase'] == 'consumed', receipt(f)
        # Cleanup may outlive terminal authority; later facts never replay Sleep.
        reply = step(f, lid='closed', power='battery', systemSleeping=False, manualClock=162)
        assert not reply['status']['ownsOverride'] and sleeps(f) == 0, reply
        passed('changed lid/power/expiry/actual Sleep consumes the pending ending; only own cleanup may finish later / ' + str(change))

for observation in [dict(foreignKeepAwake=True), dict(sleepRequestsUnavailable=True)]:
    with fixture(lid='closed', sleepFailure=True) as f:
        attach(f, lease())
        step(f, power='battery', manualClock=101)
        original = receipt(f)
        assert sleeps(f) == 1 and original['outcome'] == 'commandRejected', original
        step(f, manualClock=102, **observation)
        time.sleep(0.7)
        observed = f.ok('snapshot')
        assert sleeps(f) == 1 and 'pmset sleepnow' not in f.logs(), f.logs()
        assert receipt(f)['id'] == original['id'] and receipt(f)['outcome'] == 'commandRejected', observed
        passed('a rejected OS Sleep is already consumed; later diagnostic requests never rearm retries / ' + str(observation))

for observation in [dict(lid='open'), dict(power='unknown'), dict(fullWake=False),
                    dict(finalSnapshot=dict(sleepDisabled=True)), dict(finalOwnerUnavailable=True),
                    dict(manualClock=161)]:
    with fixture(lid='closed') as f:
        attach(f, lease())
        step(f, power='battery', manualClock=101, commandFailure=True)
        assert receipt(f)['phase'] == 'captured' and sleeps(f) == 0
        step(f, **(dict(commandFailure=False, manualClock=106) | observation))
        assert receipt(f)['phase'] == 'consumed' and sleeps(f) == 0, receipt(f)
        reply = step(f, lid='closed', power='battery', fullWake=True, finalSnapshot={},
                     finalOwnerUnavailable=False, manualClock=162)
        assert not reply['status']['ownsOverride'] and sleeps(f) == 0, reply
        assert 'pmset sleepnow' not in f.logs()
        passed('restore retry rechecks lid/power/wake/global ownership/GUI/expiry and cancellation stays final / ' + str(observation))

with fixture(foreignKeepAwake=True, sleepRequestsUnavailable=True) as f:
    attach(f, lease())
    reply = f.ok('sleep')
    assert sleeps(f) == 1 and not reply['status']['ownsOverride'], reply
    assert receipt(f)['kind'] == 'user' and receipt(f)['outcome'] == 'commandAccepted', receipt(f)
    passed('explicit user Sleep has independent intent even on open AC and does not remove foreign diagnostic requests')

for observation in [dict(foreignDisplayRequest=True), dict(displayRequestsUnavailable=True)]:
    with fixture(power='battery', lid='closed', displaySleeping=False) as f:
        packet = lease(power='battery', manual=True)
        before = attach(f, packet)
        mark = len(f.logs())
        after = step(f, **observation)
        assert after['status']['ownsOverride'] and after['status']['sleepDisabled'], after
        assert after['status']['workSession']['manualRequestID'] == before['status']['workSession']['manualRequestID'], after
        assert after['status']['workSession']['manualDeadline'] == before['status']['workSession']['manualDeadline'] == 1900, after
        assert not after['protection'].get('blockReason'), after
        assert 'displaysleepnow' not in f.logs()[mark:] and sleeps(f) == 0, f.logs()
        passed('screen observation/deferral leaves the captured finite battery manual untouched and sends no all-display command / ' + str(observation))

with fixture(sleepFailure=True) as f:
    packet = lease()
    attach(f, packet)
    command_id = str(uuid.uuid4())
    first = f.ok('sleep', id=command_id)
    previous = receipt(f)
    repeated = f.ok('sleep', id=command_id)
    assert sleeps(f) == 1 and receipt(f)['id'] == previous['id'], repeated
    # A new supported request owns a new ending; it cannot replay the old one.
    acknowledged = empty(packet, sequence=2, endConsumptionID=previous['id'])
    acknowledged['configuration'].update(enabled=False, automaticEnabled=False)
    f.ok('syncWorkSession', workSession=acknowledged)
    replacement = lease(session=packet['sessionID'], sequence=3)
    replacement['endConsumptionID'] = previous['id']
    assert attach(f, replacement)['status']['ownsOverride']
    second = f.ok('sleep')
    assert sleeps(f) == 2 and receipt(f)['id'] != previous['id'], second
    assert receipt(f)['kind'] == 'user' and receipt(f)['outcome'] == 'commandRejected', receipt(f)
    time.sleep(0.7)
    assert sleeps(f) == 2 and 'pmset sleepnow' not in f.logs(), f.logs()
    passed('replacement user Sleep belongs to the new confirmed grant; replay and old retry generations cannot add calls or a fallback')

with fixture(lid='closed') as f:
    old = lease(); old.pop('executionVersion'); old.pop('lidPermit')
    original = copy.deepcopy(old)
    before = f.ok('snapshot')
    prepared = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty(old))
    denied = f.rpc('attachWorkSession', epoch=prepared['epoch'], revision=prepared['revision'], workSession=old)
    assert denied['error'] == 'unsupportedVersion' and not denied['status']['ownsOverride'], denied
    assert old == original and denied['control'] == before['control'], denied
    attached = attach(f, empty(old, sequence=2))
    assert not attached['status']['ownsOverride'] and sleeps(f) == 0, attached
    for power in ['battery', 'ac']:
        step(f, power=power)
        assert not f.ok('snapshot')['status']['ownsOverride'] and sleeps(f) == 0
    passed('legacy active input is explicitly rejected; compatible empty release and cable observations never start it')

for power in ['ac', 'battery']:
    with Fixture(control=dict(enabled=False), manualClock=100, power=power, lid='closed') as f:
        f.ok('attachApp')
        before = f.ok('snapshot'); mark = len(f.logs())
        denied = f.rpc('startHold', minutes=3)
        assert not denied['ok'] and denied['error'] == 'unsupportedVersion', denied
        assert denied['control'] == before['control'], denied
        assert not denied['status']['ownsOverride'] and not denied['status']['sleepDisabled'], denied
        assert not denied['control'].get('batteryHoldUntil') and not denied['control'].get('pendingHoldMinutes'), denied
        assert 'disablesleep 1' not in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:], f.logs()
        passed('retired root startHold is explicitly rejected on ' + power + ' without saving an AC reservation or battery hold')

print(json.dumps(dict(passed=count, failed=0, scope='execution3 finite leases and real isolated IPC; dry-run OS writes',
                      native_root_execution_proven=False, physical_behavior_proven=False)), flush=True)
