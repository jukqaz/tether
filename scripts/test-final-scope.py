#!/usr/bin/env python3
"""Final product contract through the real IPC/helper; all power writes and sensors are fixtures."""
import json
import uuid
from service_fixture import Fixture

count = 0
def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)

def no_energy_writes(f):
    commands = [line for line in f.logs().splitlines() if 'command request: pmset' in line]
    assert not any('powermode' in line for line in commands), commands


def work_packet(power='ac', *, lid_permit=True):
    request = str(uuid.uuid4())
    packet = dict(version=1, executionVersion=3, sessionID=str(uuid.uuid4()), sequence=1,
                  power=power, expiry=115, reasons=['manual'] if power == 'battery' else ['automatic'],
                  configuration=dict(enabled=True, automaticEnabled=power == 'ac', condition='ac',
                                     automaticMinutes=60, limits=dict(batteryFloor=30)))
    if lid_permit:
        packet['lidPermit'] = dict(powerScopes=[power], disconnectAction='sleepIfClosed', protectiveAction='sleepIfClosed')
    if power == 'battery':
        packet.update(manualRequestID=request, manualDeadline=280,
                      manualStartedOnBattery=True, manualBatteryMaximumDeadline=7300)
        packet['lidPermit'].update(batteryPermitID=request, batteryDuration=7200,
                                   batteryDeadline=280, batteryMaximumDeadline=7300)
    return packet


def attach_work(f, packet):
    empty = dict(packet, reasons=[], expiry=None)
    empty.pop('lidPermit', None)
    before = f.ok('snapshot')
    proof = f.ok('prepareWorkSession', workSession=empty, epoch=before['epoch'], revision=before['revision'])
    return f.ok('attachWorkSession', workSession=packet, epoch=proof['epoch'], revision=proof['revision'])


def observe(f, **values):
    f.patch(**values)
    return f.ok('markDiagnostic')

for source in ['ac', 'battery']:
    for lid in ['open', 'closed']:
        with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100,
                     power=source, lid=lid, temperature=None, batteryPowerMode=2, acPowerMode=2) as f:
            lease = work_packet(source)
            r = attach_work(f, lease)
            assert r['status']['ownsOverride'] and not r['protection'].get('blockReason'), r
            observe(f, temperature=90, thermal=1, manualClock=101)
            assert f.ok('snapshot')['status']['ownsOverride']
            r = observe(f, thermal=2, manualClock=102)
            assert r['protection']['blockReason'] == 'thermal' and not r['status']['ownsOverride'], r
            assert ('IOPMSleepSystem' in f.logs()) == (lid == 'closed')
            latch = r['workSessionBridge']['lidProtection']
            end = r['workSessionBridge']['lidEndReceipt']
            lease.update(sequence=2, endConsumptionID=end['id'], protectionResumeID=latch['id'])
            assert f.rpc('syncWorkSession', workSession=lease)['error'] == 'safetyBlocked'
            r = observe(f, temperature=None, thermal=0, manualClock=103)
            assert not r['status']['ownsOverride'], r
            lease['sequence'] = 3
            if source == 'battery':
                # Explicit new manual approval; cooling does not revive its old ID.
                request = str(uuid.uuid4())
                lease['manualRequestID'] = request
                lease['lidPermit']['batteryPermitID'] = request
            assert f.ok('syncWorkSession', workSession=lease)['status']['ownsOverride']
            no_energy_writes(f)
            passed(f'{source}/{lid}: optional sensor, OS serious stop, explicit resume, energy modes untouched')

for topology in ['externalUnverified', 'externalWithVirtual']:
    # Extra screens alone do not establish native clamshell. This case supplies
    # independent native-operation evidence; unverified layouts are tested separately.
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100,
                 lid='closed', external=True, displayTopology=topology, nativeDisplayVerified=True) as f:
        attach_work(f, work_packet(lid_permit=False))
        for thermal in [2, 3, -1]:
            r = observe(f, thermal=thermal, temperature=None, battery=None)
            assert not r['status']['ownsOverride'] and r['protection'].get('blockReason') == 'thermal', r
            assert r['status']['displayRecovery']['phase'] == 'inactive'
        assert 'command request: pmset' not in f.logs() and 'IOPMSleepSystem' not in f.logs()
        passed(topology + ': native route has no root lid grant; Tether protection metadata cannot change physical display or energy settings')

for topology in ['externalUnverified', 'externalWithVirtual']:
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100,
                 lid='closed', external=True, displayTopology=topology, nativeDisplayVerified=False) as f:
        assert attach_work(f, work_packet())['status']['ownsOverride']
        r = observe(f, thermal=2, temperature=None)
        assert r['protection']['blockReason'] == 'thermal' and not r['status']['ownsOverride'], r
        assert 'pmset -a disablesleep 0' in f.logs()
        # Screens alone cannot establish the native route. The explicitly
        # approved lid grant keeps its v4 one-shot protective end action.
        assert f.logs().count('IOPMSleepSystem') == 1 and 'pmset sleepnow' not in f.logs()
        no_energy_writes(f)
        passed(topology + ': extra screens without native evidence retain Tether thermal protection')

with Fixture() as f:
    for change in [dict(holdLowPower=True), dict(holdLowPower=False),
                   dict(heatGuard=dict(enabled=True, level=1)),
                   dict(limits=dict(closedLidMaxTemperature=40)),
                   dict(limits=dict(openLidMaxTemperature=42))]:
        before = f.ok('snapshot')
        r = f.rpc('configure', control=before['control'] | change, epoch=before['epoch'], revision=before['revision'])
        assert r['error'] == 'invalidRequest' and f.ok('snapshot')['control'] == before['control'], r
    no_energy_writes(f)
    passed('retired options rejected at helper boundary, with no settings change')

with Fixture(control=dict(schemaVersion=2, powerCondition='any', automaticHoldMinutes=30,
                          limits=dict(batteryFloor=40, maxHoldHours=1, closedLidMaxTemperature=38),
                          heatGuard=dict(enabled=True, level=1), holdLowPower=True)) as f:
    r = f.ok('snapshot')
    assert r['control']['schemaVersion'] == 4 and not r['control']['enabled']
    assert r['protection']['blockReason'] == 'settingsChanged' and not r['status']['ownsOverride']
    assert r['control']['powerCondition'] == 'ac' and r['control']['automaticHoldMinutes'] == 30
    assert r['control']['limits'] == dict(batteryFloor=40, maxHoldHours=1)
    report = json.loads((f.folder/'migration-report.json').read_text())
    original = json.loads((f.folder/'migrations'/report['backupName']).read_text())
    assert original['limits']['closedLidMaxTemperature'] == 38 and original['holdLowPower'] is True
    f.ok('resume'); f.stop(); f.start()
    assert f.ok('snapshot')['control']['enabled']
    assert f.ok('snapshot')['protection'].get('blockReason') is None
    no_energy_writes(f)
    passed('schema 2 custom policy backs up exactly, migrates to AC-only schema 4, pauses once and preserves resume on restart')

for scope in ['Battery', 'AC']:
    for saved, current, restored in [(0, 1, True), (2, 1, True), (0, 2, False), (1, 1, False)]:
        with Fixture(control={'enabled': False}) as f:
            f.stop()
            path = f.folder/'helper-state.json'
            state = json.loads(path.read_text()) if path.exists() else {}
            key = 'saved'+scope+'LowPower'
            state[key] = saved
            path.write_text(json.dumps(state))
            mark = len(f.logs())
            f.patch(**{scope.lower()+'PowerMode': current})
            f.start()
            assert key not in json.loads(path.read_text())
            writes = [line for line in f.logs()[mark:].splitlines() if 'command request: pmset' in line]
            assert any('powermode '+str(saved) in line for line in writes) == restored, writes
            passed(f'legacy {scope}: saved={saved}, current={current}, restore={restored}; foreign changes retained')

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100,
             lid='closed', displaySleeping=False, displayClock=0) as f:
    packet = work_packet()
    packet['closedLidDisplayMode'] = 'unchanged'
    assert attach_work(f, packet)['status']['ownsOverride']
    r = observe(f, displayClock=1)
    assert r['status']['displayRecovery'] == dict(phase='inactive', requests=0, maximumRequests=3), r
    assert 'pmset displaysleepnow' not in f.logs(), f.logs()
    for incident in range(4):
        base = incident * 3600
        for offset in range(1, 62, 3):
            r = observe(f, displaySleeping=True, displayClock=base+offset)
        assert r['status']['displayRecovery'] == dict(phase='inactive', requests=0, maximumRequests=3), r
        observe(f, displaySleeping=False, displayClock=base+3590)
        r = observe(f, displayClock=base+3600)
        assert r['status']['ownsOverride'] and not r['protection'].get('blockReason')
        assert r['status']['displayRecovery']['phase'] == 'inactive'
    assert 'pmset displaysleepnow' not in f.logs(), f.logs()
    assert 'IOPMSleepSystem' not in f.logs()
    passed('the unchanged display choice never enables a display writer or changes the approved finite lid grant')

print('TOTAL', count, 'final-scope scenarios passed')
