#!/usr/bin/env python3
"""Kernel-authenticated GUI ownership with fake console changes; never changes OS power/lock/user state."""
import json
import os
import select
import subprocess
import sys
import uuid
from service_fixture import Fixture

if os.geteuid() == 0:
    raise SystemExit('Run without root; all power execution stays dry-run')
# A headless runner must not report a native graphical session as a passed test.
probe = subprocess.run(['xcrun', 'swift', '-e',
    'import Darwin; import Security; var sid: SecuritySessionId = 0; var a = SessionAttributeBits(); '
    'var audit = auditinfo_addr(); let r = SessionGetInfo(callerSecuritySession, &sid, &a); '
    'let ar = getaudit_addr(&audit, Int32(MemoryLayout.size(ofValue: audit))); '
    'print(r == 0 && a.contains(.sessionHasGraphicAccess) && !a.contains(.sessionIsRoot) && '
    'ar == 0 && audit.ai_auid == getuid() && sid == UInt32(bitPattern: audit.ai_asid))'],
    capture_output=True, text=True, timeout=30)
if probe.returncode != 0:
    raise AssertionError(('Native GUI preflight failed', probe.stderr))
if probe.stdout.strip() != 'true':
    print('SKIP native GUI service scenarios: this runner has no graphical login; pure policy tests remain separate', flush=True)
    raise SystemExit(0)

UID = os.getuid()
COUNT = 0

def fixture(**values):
    return Fixture(**(dict(guiAuthority=True, guiConsoleUID=UID, guiClock=100, manualClock=100) | values))

def passed(message):
    global COUNT
    COUNT += 1
    print('PASS GUI session', message, flush=True)

def no_sleep(log):
    assert 'IOPMSleepSystem' not in log and 'pmset sleepnow' not in log, log


def work_packet(*, holding=False, manual=False, session=None):
    packet = {'version': 1, 'executionVersion': 3, 'sessionID': session or str(uuid.uuid4()), 'sequence': 1,
            'power': 'ac', 'expiry': 115 if holding else None,
            'reasons': (['automatic', 'manual'] if manual else ['automatic']) if holding else [],
            'configuration': {'enabled': True, 'automaticEnabled': True, 'condition': 'ac',
                              'automaticMinutes': 60, 'limits': {'batteryFloor': 30}}}
    if holding:
        packet['lidPermit'] = {'powerScopes': ['ac'], 'disconnectAction': 'sleepIfClosed', 'protectiveAction': 'sleepIfClosed'}
    if manual:
        packet.update(manualDeadline=280, manualRequestID=str(uuid.uuid4()))
    return packet


def prepare_work(f, packet, **values):
    before = f.ok('snapshot')
    return f.rpc('prepareWorkSession', epoch=before['epoch'], revision=before['revision'],
                 workSession=packet, **values)


def start_work(f, *, manual=True, session=None):
    current = work_packet(holding=True, manual=manual, session=session)
    empty = work_packet(session=current['sessionID'])
    prepared = prepare_work(f, empty)
    assert prepared['ok'], prepared
    proof = prepared['workSessionPreparation']
    result = f.ok('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'], workSession=current)
    assert result['status']['ownsOverride'] and result['workSessionBridge']['coordinated'], result
    return current


with fixture(control={'enabled': False}, manualClock=100) as f:
    initial = f.ok('snapshot')
    assert not initial['status']['appConnected'] and not initial['status']['ownsOverride'], initial
    empty = work_packet()
    prepared = prepare_work(f, empty, authenticatedPID=1,
                            authenticatedGUILogin={'uid': UID + 1, 'sessionID': 1})
    assert prepared['ok'], prepared
    proof = prepared['workSessionPreparation']
    assert prepared['status']['appConnected'] and prepared['status']['guiSessionAuthority'] == 'confirmed', prepared
    assert not prepared['control']['enabled'] and not prepared['status']['ownsOverride'], prepared
    saved = json.loads((f.folder/'helper-state.json').read_text())
    assert saved['guiOwner']['process']['pid'] == os.getpid() and saved['appPID'] == os.getpid(), saved
    assert saved['guiOwner']['login']['uid'] == UID and saved['controllerUID'] == UID, saved
    assert saved['guiOwner']['login']['sessionID'] not in [0, 1], saved
    current = work_packet(holding=True, session=empty['sessionID'])
    attached = f.ok('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'], workSession=current)
    assert attached['status']['ownsOverride'] and attached['workSessionBridge']['coordinated'], attached
    passed('cold coordinated preparation claims only the kernel current GUI; empty prepare preserves off and first attach grants work')

with fixture(control={'enabled': False}, manualClock=100) as f:
    empty = work_packet()
    prepared = prepare_work(f, empty)
    assert prepared['ok'], prepared
    proof = prepared['workSessionPreparation']
    empty['configuration'].update(enabled=False, automaticEnabled=False)
    f.ok('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'], workSession=empty)
    f.ok('detachApp'); f.stop(); f.start()
    before = f.ok('snapshot')
    assert before['workSessionBridge']['coordinated'] and not before['status']['appConnected'], before
    assert not before['status']['ownsOverride'] and not before['control']['enabled'], before
    saved = json.loads((f.folder/'helper-state.json').read_text())
    assert saved['controllerUID'] == UID and saved.get('guiOwner') is None, saved
    fresh = work_packet(); fresh['configuration'].update(enabled=False, automaticEnabled=False)
    prepared = prepare_work(f, fresh)
    assert prepared['ok'] and prepared['status']['guiSessionAuthority'] == 'confirmed', prepared
    proof = prepared['workSessionPreparation']
    attached = f.ok('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'], workSession=fresh)
    assert attached['status']['appConnected'] and not attached['status']['ownsOverride'], attached
    assert not attached['control']['enabled'] and not attached['status']['manualSession']['active'], attached
    no_sleep(f.logs())
    passed('ownerless coordinated helper restart accepts a fresh current-GUI preparation while preserving explicit off')

with fixture(control={'enabled': False}, manualClock=100) as f:
    before = f.ok('snapshot')
    empty = work_packet()
    invalid = [dict(epoch='stale-epoch'), dict(revision=before['revision'] + 1),
               dict(workSession=work_packet(holding=True)), dict(workSession=empty | dict(expiry=115)),
               dict(workSession=empty | dict(version=99)), dict(workSession=None)]
    for index, change in enumerate(invalid):
        request = dict(epoch=before['epoch'], revision=before['revision'], workSession=empty) | change
        denied = f.rpc('prepareWorkSession', **request)
        expected = 'staleRevision' if index < 2 else 'invalidWorkLease'
        assert denied['error'] == expected, (index, denied)
        assert not denied['status']['appConnected'] and not denied['status']['ownsOverride'], denied
        assert denied.get('workSessionPreparation') is None and denied['control'] == before['control'], denied
    saved_path = f.folder/'helper-state.json'
    saved = json.loads(saved_path.read_text()) if saved_path.exists() else {}
    assert saved.get('guiOwner') is None and saved.get('appPID') is None, saved
    assert 'disablesleep 1' not in f.logs(), f.logs()
    passed('valid current GUI alone cannot bind an owner through stale epoch/revision, nonempty or invalid preparation')

with fixture(control={'enabled': False}, manualClock=100) as f:
    # The JSON login is ignored. Even a kernel graphical peer is ineligible
    # when its native UID is not the observed active console.
    f.patch(guiConsoleUID=UID + 1)
    denied = prepare_work(f, work_packet(), authenticatedGUILogin={'uid': UID + 1, 'sessionID': 1})
    assert denied['error'] == 'guiSessionUnavailable', denied
    assert not denied['status']['appConnected'] and not denied['status']['ownsOverride'], denied
    assert denied.get('workSessionPreparation') is None and 'disablesleep 1' not in f.logs(), f.logs()
    passed('cold preparation rejects a kernel login that differs from the current console; forged JSON cannot replace it')

with fixture(control={'enabled': False}, manualClock=100) as f:
    f.stop()
    (f.folder/'helper-state.json').write_text(json.dumps({'controllerUID': UID + 1}))
    f.start()
    denied = prepare_work(f, work_packet())
    assert denied['error'] == 'notOwner' and not denied['status']['appConnected'], denied
    saved = json.loads((f.folder/'helper-state.json').read_text())
    assert saved['controllerUID'] == UID + 1 and saved.get('guiOwner') is None, saved
    assert denied.get('workSessionPreparation') is None and 'disablesleep 1' not in f.logs(), f.logs()
    passed('cold preparation cannot replace an approved controller UID belonging to another account')

with fixture(control={'enabled': False}, manualClock=100) as f:
    empty = work_packet(); before = f.ok('snapshot'); request_id = str(uuid.uuid4())
    prepared = f.ok('prepareWorkSession', id=request_id, epoch=before['epoch'], revision=before['revision'], workSession=empty)
    f.patch(guiConsoleUID=UID + 1, guiClock=101)
    denied = f.rpc('prepareWorkSession', id=request_id, epoch=before['epoch'], revision=before['revision'], workSession=empty)
    assert denied['error'] == 'guiSessionUnavailable', denied
    assert not denied['status']['appConnected'] and not denied['status']['ownsOverride'], denied
    assert denied.get('workSessionPreparation') is None, denied
    saved = json.loads((f.folder/'helper-state.json').read_text())
    assert saved['controllerUID'] == UID and saved.get('guiOwner') is None, saved
    no_sleep(f.logs())
    passed('a console switch rejects a cached successful preparation before its ACK can reclaim the old GUI login')

with fixture(control={'enabled': False}, manualClock=100) as f:
    # A second real kernel socket peer owns this test helper. Its process is
    # created and stopped only inside this isolated dry-run test fixture.
    child_code = '''
import json, os, socket, sys, uuid
request = dict(version=2, id=str(uuid.uuid4()), action='attachApp', authenticatedPID=os.getppid(),
               authenticatedGUILogin=dict(uid=0, sessionID=1))
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
    connection.settimeout(5); connection.connect(sys.argv[1])
    connection.sendall(json.dumps(request).encode() + b'\\n')
    data = b''
    while not data.endswith(b'\\n'):
        part = connection.recv(8192)
        assert part, 'missing child response'
        data += part
print(data.decode().strip(), flush=True)
sys.stdin.readline()
'''
    child = subprocess.Popen([sys.executable, '-c', child_code, f.sock], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([child.stdout], [], [], 5)
        assert ready, 'test-owned GUI peer did not receive its attach response'
        attached = json.loads(child.stdout.readline())
        assert attached['ok'] and attached['status']['appPID'] == child.pid, attached
        assert child.poll() is None, attached
        denied = prepare_work(f, work_packet(), authenticatedPID=child.pid,
                              authenticatedGUILogin={'uid': UID, 'sessionID': 1})
        assert denied['error'] == 'notOwner', denied
        saved = json.loads((f.folder/'helper-state.json').read_text())
        assert saved['guiOwner']['process']['pid'] == child.pid and saved['appPID'] == child.pid, saved
        assert denied.get('workSessionPreparation') is None and not denied['status']['ownsOverride'], denied
        passed('preparation cannot steal another live kernel peer owner using its PID or forged GUI JSON')
    finally:
        if child.poll() is None:
            try:
                child.stdin.write('done\n'); child.stdin.flush()
            except BrokenPipeError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=5)
        child.stdin.close(); child.stdout.close(); child.stderr.close()

with fixture() as f:
    initial = f.ok('snapshot')['status']
    assert not initial['appConnected'] and not initial['ownsOverride']
    assert f.rpc('startManualSession')['error'] == 'notOwner'
    assert 'disablesleep 1' not in f.logs()
    passed('startup has no GUI approval invented from the console UID')

with fixture() as f:
    result = f.ok('attachApp', authenticatedPID=1,
                  authenticatedGUILogin={'uid': UID + 1, 'sessionID': 1})
    saved = json.loads((f.folder/'helper-state.json').read_text())
    assert result['status']['appPID'] == os.getpid()
    assert saved['guiOwner']['process']['pid'] == os.getpid()
    assert saved['guiOwner']['login']['uid'] == UID and saved['guiOwner']['login']['sessionID'] not in [0, 1]
    assert saved['controllerUID'] == UID and result['status']['guiSessionAuthority'] == 'confirmed'
    passed('kernel peer PID/login wins over forged JSON credentials')

with fixture(lid='closed') as f:
    start_work(f)
    f.patch(guiLocked=True, guiRemote=True, guiClock=110)
    result = f.ok('snapshot')
    assert result['status']['ownsOverride'] and result['status']['appConnected']
    assert result['status']['manualSession']['active'] and result['status']['guiSessionAuthority'] == 'confirmed'
    no_sleep(f.logs())
    passed('same-login lock/remote sensor labels neither end work nor change security settings')

with fixture(lid='closed') as f:
    current = start_work(f)
    assert f.rpc('startHold', minutes=3)['error'] == 'coordinatorRequired'
    request_id = str(uuid.uuid4())
    current['sequence'] = 2
    f.ok('syncWorkSession', id=request_id, workSession=current)
    mark = len(f.logs())
    f.patch(guiConsoleUID=UID + 1, guiClock=101)
    result = f.ok('snapshot')
    assert not result['status']['ownsOverride'] and not result['status']['appConnected']
    assert not result['status']['manualSession']['active']
    assert result['control'].get('pendingHoldMinutes') is None and result['control'].get('batteryHoldUntil') is None
    assert f.rpc('syncWorkSession', id=request_id, workSession=current)['error'] == 'notOwner'
    assert f.rpc('attachApp', authenticatedGUILogin={'uid': UID + 1, 'sessionID': 1})['error'] == 'guiSessionUnavailable'
    saved = json.loads((f.folder/'helper-state.json').read_text())
    assert saved['controllerUID'] == UID and saved.get('guiOwner') is None
    assert 'pmset -a disablesleep 0' in f.logs()[mark:]
    no_sleep(f.logs()[mark:])
    passed('switch consumes coordinated manual work, rejects a legacy reservation and cached success without forcing sleep')

with fixture() as f:
    current = start_work(f)
    mark = len(f.logs())
    f.patch(guiUnavailable=True, guiClock=101)
    result = f.ok('snapshot')
    assert result['status']['ownsOverride'] and result['status']['appConnected'], (result, f.logs().splitlines()[-12:])
    assert result['status']['guiSessionAuthority'] == 'unavailable'
    assert f.rpc('startHold', minutes=3)['error'] == 'guiSessionUnavailable'
    renewal = current | dict(sequence=2)
    assert f.rpc('syncWorkSession', workSession=renewal)['error'] == 'guiSessionUnavailable'
    assert f.rpc('attachApp')['error'] == 'guiSessionUnavailable'
    f.patch(guiClock=129)
    assert f.ok('snapshot')['status']['ownsOverride']
    f.patch(guiClock=130)
    result = f.ok('snapshot')
    assert not result['status']['ownsOverride'] and not result['status']['manualSession']['active']
    assert 'disablesleep 1' not in f.logs()[mark:]
    no_sleep(f.logs()[mark:])
    passed('observation gap preserves only the original 30-second deadline and grants no renewal')

with fixture(lid='closed') as f:
    start_work(f)
    mark = len(f.logs())
    # GUI proof and the work lease have independent clocks. A remaining GUI
    # grace period cannot extend the original execution lease or authorize Sleep.
    f.patch(guiUnavailable=True, guiClock=101, manualClock=114)
    assert f.ok('markDiagnostic')['status']['ownsOverride']
    f.patch(manualClock=115)
    result = f.ok('markDiagnostic')
    assert not result['status']['ownsOverride'], result
    assert 'pmset -a disablesleep 0' in f.logs()[mark:]
    assert 'disablesleep 1' not in f.logs()[mark:]
    no_sleep(f.logs()[mark:])
    passed('an earlier work-lease deadline releases during GUI grace without Sleep or reacquisition')

with fixture() as f:
    start_work(f)
    f.patch(guiUnavailable=True, guiClock=101); f.ok('snapshot')
    f.patch(guiUnavailable=False, guiClock=129)
    result = f.ok('snapshot')
    assert result['status']['appConnected'] and result['status']['manualSession']['active']
    assert result['status']['guiSessionAuthority'] == 'confirmed'
    passed('a verified matching login recovers during the bounded observation gap')

with fixture() as f:
    start_work(f)
    f.patch(guiConsoleUID=UID + 1, guiClock=101); f.ok('snapshot')
    f.patch(guiConsoleUID=UID, guiClock=102)
    assert not f.ok('snapshot')['status']['manualSession']['active']
    start_work(f, manual=False)
    result = f.ok('snapshot')
    assert result['status']['ownsOverride'] and not result['status']['manualSession']['active']
    assert result['control'].get('pendingHoldMinutes') is None
    passed('fresh current-GUI AC evaluation restores automatic work without resurrecting the consumed manual timer')

with fixture(sleepDisabled=True) as f:
    f.ok('attachApp')
    mark = len(f.logs())
    f.patch(guiConsoleUID=UID + 1); result = f.ok('snapshot')
    assert result['status']['sleepDisabled'] and not result['status']['ownsOverride']
    assert 'disablesleep 0' not in f.logs()[mark:]; no_sleep(f.logs()[mark:])
    passed('user switch does not release an unowned global override')

with fixture() as f:
    f.stop()
    (f.folder/'helper-state.json').write_text(json.dumps({'controllerUID': UID + 1}))
    f.start()
    assert f.rpc('attachApp')['error'] == 'notOwner'
    assert 'disablesleep 1' not in f.logs()
    passed('a new console user cannot silently replace the approved controller UID')

with fixture() as f:
    start_work(f)
    assert f.rpc('startHold', minutes=3)['error'] == 'coordinatorRequired'
    f.stop(); f.start()
    result = f.ok('snapshot')
    assert result['status']['appConnected'] and not result['status']['manualSession']['active']
    assert not result['status']['ownsOverride'] and result['workSessionBridge']['coordinated'], result
    assert result['control'].get('pendingHoldMinutes') is None
    assert json.loads((f.folder/'helper-state.json').read_text())['controllerUID'] == UID
    passed('helper restart revalidates native process/boot/login without restoring a grant or a rejected legacy reservation')

with fixture(control={'enabled': False}) as f:
    f.ok('attachApp')
    f.stop()
    path = f.folder/'helper-state.json'
    legacy = json.loads(path.read_text())
    legacy.pop('guiOwner'); legacy.pop('controllerUID')
    path.write_text(json.dumps(legacy))
    f.start()
    result = f.ok('snapshot')
    assert not result['status']['appConnected'] and not result['status']['ownsOverride']
    migrated = json.loads(path.read_text())
    # Loading an unchanged legacy file does not rewrite it just to materialize
    # an optional field. Its saved app UID remains the approved-owner fallback.
    assert migrated['appUID'] == UID and migrated.get('guiOwner') is None
    result = f.ok('attachApp')
    assert result['status']['appConnected'] and result['status']['guiSessionAuthority'] == 'confirmed'
    assert not result['control']['enabled'] and not result['status']['ownsOverride']
    assert json.loads(path.read_text())['controllerUID'] == UID
    no_sleep(f.logs())
    passed('legacy UID/start state requires a new kernel GUI handshake and preserves explicit off')

print(f'TOTAL {COUNT} native GUI service scenarios passed', flush=True)
