#!/usr/bin/env python3
"""Same-process lid detach/reprepare via real helper IPC; all OS writes are dry-run.

App capability observations are covered by CommonSessionRoutingTests. This checks
the real helper boundary they invoke, without claiming physical sensor/OS evidence.
"""
import copy
import json
import uuid
from service_fixture import Fixture


def prepare(f, packet):
    current = f.ok('snapshot')
    empty = copy.deepcopy(packet)
    empty['reasons'] = []; empty['expiry'] = None
    empty.pop('manualDeadline', None)
    empty.pop('lidPermit', None)
    return f.ok('prepareWorkSession', epoch=current['epoch'], revision=current['revision'], workSession=empty)


def attach(f, packet, acknowledgement):
    receipt = acknowledgement['workSessionPreparation']
    return f.rpc('attachWorkSession', epoch=receipt['epoch'], revision=receipt['revision'], workSession=packet)


def lease(power):
    manual_id = str(uuid.uuid4())
    packet = dict(version=1, executionVersion=3, sessionID=str(uuid.uuid4()), sequence=1, power=power,
                  expiry=115, reasons=['automatic', 'manual'] if power == 'ac' else ['manual'],
                  manualRequestID=manual_id, manualDeadline=180, manualStartedOnBattery=power == 'battery',
                  configuration=dict(enabled=True, automaticEnabled=True, condition='ac',
                                     automaticMinutes=60, limits=dict(batteryFloor=30)))
    packet['lidPermit'] = dict(powerScopes=[power], disconnectAction='sleepIfClosed', protectiveAction='sleepIfClosed')
    if power == 'battery':
        packet['lidPermit'].update(batteryPermitID=manual_id, batteryDuration=1800, batteryDeadline=180)
    return packet


passed = 0
for power in ('ac', 'battery'):
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100,
                 power=power, lid='closed', lowPowerWarning=False) as f:
        assert not f.ok('snapshot')['status']['ownsOverride']
        packet = lease(power)
        prepared = prepare(f, packet)
        started = attach(f, packet, prepared)
        assert started['ok'] and started['status']['ownsOverride'], started
        f.patch(manualClock=110)
        detached = f.ok('detachApp')
        assert detached['status']['appConnected'] is False, detached
        assert detached['status']['ownsOverride'] is False and detached['status']['sleepDisabled'] is False, detached
        assert 'workSession' not in detached['status'], detached
        assert detached['workSessionBridge']['coordinated'], detached
        assert detached['control']['enabled'] and detached['control']['powerCondition'] == 'ac', detached
        for budget in ('automaticBudget', 'manualBudget'):
            assert detached['workSessionBridge'].get(budget) == started['workSessionBridge'].get(budget), detached
        packet['sequence'] = 2
        assert f.rpc('syncWorkSession', workSession=packet)['error'] == 'notOwner'
        assert not attach(f, packet, prepared)['ok'], 'Old prepared attachment revived after detach'
        # Reprepare within the original 15-second grant; this must not extend
        # either its parent expiry or the user's original manual deadline.
        f.patch(manualClock=112)
        fresh = prepare(f, packet)
        resumed = attach(f, packet, fresh)
        assert resumed['ok'] and resumed['status']['ownsOverride'], resumed
        assert uuid.UUID(resumed['status']['workSession']['sessionID']) == uuid.UUID(packet['sessionID']), resumed
        assert resumed['status']['workSession']['manualDeadline'] == 180, resumed
        assert resumed['status']['workSession']['expiry'] == 115, resumed
        assert uuid.UUID(resumed['status']['workSession']['manualRequestID']) == uuid.UUID(packet['manualRequestID']), resumed
        for budget in ('automaticBudget', 'manualBudget'):
            assert resumed['workSessionBridge'].get(budget) == started['workSessionBridge'].get(budget), resumed
        if power == 'battery':
            receipt = started['workSessionBridge']['batteryPermitReceipt']
            assert receipt['observedAt'] == 100 and receipt['deadline'] == 180, started
            assert resumed['workSessionBridge']['batteryPermitReceipt'] == receipt, resumed
            assert resumed['workSessionBridge']['batteryPermitReceipts'] == [receipt], resumed
            assert resumed['status']['workSession']['reasons'] == ['manual'], resumed
        f.patch(manualClock=115)
        expired = f.ok('markDiagnostic')
        assert expired['status']['ownsOverride'] is False and expired['status']['sleepDisabled'] is False, expired
        assert expired['workSessionBridge']['coordinated'] and expired['control']['enabled'], expired
        assert 'IOPMSleepSystem' not in f.logs(), f.logs()
        print(f'PASS {power}: own detach, stale denial, same-session reprepare, original deadline/budgets, finite expiry', flush=True)
        passed += 1


for power in ('ac', 'battery'):
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100,
                 power=power, lid='closed', lowPowerWarning=False) as f:
        packet = lease(power)
        packet.pop('executionVersion')
        packet.pop('lidPermit')
        prepared = prepare(f, packet)
        rejected = attach(f, packet, prepared)
        assert rejected['error'] == 'unsupportedVersion' and not rejected['ok'], rejected
        assert not rejected['status']['ownsOverride'] and not rejected['status']['sleepDisabled'], rejected
        assert 'workSession' not in rejected['status'], rejected
        assert 'disablesleep 1' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
        print(f'PASS {power}: legacy empty preparation remains compatible but unversioned active work is unsupported', flush=True)
        passed += 1


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100,
             power='battery', lid='closed', lowPowerWarning=False) as f:
    packet = lease('battery')
    packet['reasons'] = ['automatic', 'manual']
    prepared = prepare(f, packet)
    rejected = attach(f, packet, prepared)
    assert rejected['error'] == 'invalidWorkLease' and not rejected['ok'], rejected
    assert not rejected['status']['ownsOverride'] and not rejected['status']['sleepDisabled'], rejected
    assert 'workSession' not in rejected['status'], rejected
    assert 'disablesleep 1' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
    print('PASS battery: an AC automatic preference cannot authorize battery automatic work', flush=True)
    passed += 1

print(json.dumps(dict(passed=passed, failed=0, scope='real isolated helper/IPC with dry-run OS writes',
                     physical_behavior_proven=False, native_root_execution_proven=False)), flush=True)
