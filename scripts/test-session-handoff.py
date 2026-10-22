#!/usr/bin/env python3
"""Root handoff ordering/identity through real IPC; all OS power writes are dry-run."""
import copy
import json
import subprocess
import sys
import uuid
from service_fixture import Fixture

count = 0


def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)


def lease():
    return {'version': 1, 'executionVersion': 3, 'sessionID': str(uuid.uuid4()), 'sequence': 1, 'power': 'ac',
            'expiry': 130, 'reasons': ['automatic'],
            'lidPermit': {'powerScopes': ['ac'], 'disconnectAction': 'sleepIfClosed', 'protectiveAction': 'sleepIfClosed'},
            'configuration': {'enabled': True, 'automaticEnabled': True, 'condition': 'ac',
                              'automaticMinutes': 60, 'limits': {'batteryFloor': 20}}}


def prepare(f, packet):
    before = f.ok('snapshot')
    empty = copy.deepcopy(packet); empty['reasons'] = []; empty['expiry'] = None
    empty.pop('lidPermit', None)
    return f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)


def attach(f, packet, prepared):
    receipt = prepared['workSessionPreparation']
    return f.rpc('attachWorkSession', epoch=receipt['epoch'], revision=receipt['revision'], workSession=packet)


with Fixture(manualClock=100, lid='closed') as f:
    packet = lease()
    before = f.ok('snapshot'); mark = len(f.logs())
    prepared = prepare(f, packet)
    assert prepared['control'] == before['control'], prepared
    assert prepared['status']['ownsOverride'] == before['status']['ownsOverride'], prepared
    assert 'workSession' not in prepared['status'], prepared
    assert 'disablesleep 0' not in f.logs()[mark:] and 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    attached = attach(f, packet, prepared)
    assert attached['ok'] and attached['workSessionBridge']['coordinated'], attached
    assert attached['status']['ownsOverride'], attached
    changes = f.logs()[mark:]
    release = changes.index('command request: pmset -a disablesleep 0')
    acquire = changes.index('command request: pmset -a disablesleep 1')
    assert release < acquire and 'IOPMSleepSystem' not in changes, changes
    assert attached['status']['workSession']['executionVersion'] == 3, attached
    passed('preparation preserves existing closed AC execution; attachment restores the legacy writer before the finite v3 acquisition')

with Fixture(manualClock=100, lid='closed') as f:
    f.config(enabled=False)
    before = f.ok('snapshot'); mark = len(f.logs())
    packet = lease(); prepared = prepare(f, packet)
    assert not prepared['status']['ownsOverride'], prepared
    assert prepared['control'] == before['control'], prepared
    assert 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    passed('preparation cannot acquire a root override while legacy execution is off')

with Fixture(manualClock=100) as f:
    before = f.ok('snapshot'); packet = lease()
    empty = copy.deepcopy(packet); empty['reasons'] = []; empty['expiry'] = None
    empty.pop('lidPermit', None)
    for proof in [{}, {'epoch': 'wrong', 'revision': before['revision']},
                  {'epoch': before['epoch'], 'revision': before['revision'] + 1}]:
        assert f.rpc('prepareWorkSession', workSession=empty, **proof)['error'] == 'staleRevision'
    assert f.rpc('attachWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=packet)['error'] == 'invalidWorkLease'
    assert f.ok('snapshot')['control'] == before['control']
    passed('missing/wrong epoch or revision and unprepared attachment cannot change the root configuration')

with Fixture(manualClock=100, lid='closed') as f:
    packet = lease(); prepared = prepare(f, packet)
    stopped = f.ok('stop')
    assert stopped['workSessionBridge']['stopRequested'] and not stopped['status']['ownsOverride'], stopped
    denied = attach(f, packet, prepared)
    assert not denied['ok'] and denied['error'] == 'staleRevision', denied
    assert not denied['control']['enabled'] and not denied['status']['ownsOverride'], denied
    empty = copy.deepcopy(packet); empty['reasons'] = []; empty['expiry'] = None
    empty.pop('lidPermit', None)
    empty['configuration']['enabled'] = False
    empty['configuration']['automaticEnabled'] = False
    current = prepare(f, empty); acknowledged = attach(f, empty, current)
    assert acknowledged['ok'] and not acknowledged['status']['ownsOverride'], acknowledged
    assert not acknowledged['workSessionBridge']['stopRequested'], acknowledged
    passed('stop after preparation invalidates the old receipt and stays off until an empty disabled acknowledgement')

with Fixture(manualClock=100) as f:
    packet = lease(); prepared = prepare(f, packet)
    f.patch(manualClock=131)
    packet['expiry'] = 161
    denied = attach(f, packet, prepared)
    assert not denied['ok'] and denied['error'] == 'invalidWorkLease', denied
    wrong = copy.deepcopy(packet); wrong['sessionID'] = str(uuid.uuid4())
    current = prepare(f, packet)
    denied = attach(f, wrong, current)
    assert not denied['ok'] and denied['error'] == 'invalidWorkLease', denied
    passed('expired preparation and another common-session identity cannot acquire a grant')

with Fixture(manualClock=100) as f:
    packet = lease(); prepared = prepare(f, packet)
    receipt = prepared['workSessionPreparation']
    wire = {'version': 2, 'id': str(uuid.uuid4()), 'action': 'attachWorkSession',
            'epoch': receipt['epoch'], 'revision': receipt['revision'], 'workSession': packet}
    child = subprocess.run([sys.executable, '-c', '''import json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(5);s.connect(sys.argv[1]);s.sendall(sys.argv[2].encode()+b'\\n')
d=b''
while not d.endswith(b'\\n'): d+=s.recv(8192)
r=json.loads(d);print(json.dumps({'ok':r['ok'],'error':r.get('error')}))
''', f.sock, json.dumps(wire)], text=True, capture_output=True, timeout=10)
    assert child.returncode == 0, child.stderr
    reply = json.loads(child.stdout)
    assert not reply['ok'] and reply['error'] in ['invalidWorkLease', 'notOwner'], reply
    assert 'workSession' not in f.ok('snapshot')['status']
    passed('a different live process cannot use a preparation receipt from the same Unix user')

with Fixture(manualClock=100) as f:
    f.config(limits={'batteryFloor': 50, 'maxHoldHours': 0.5})
    packet = lease(); prepared = prepare(f, packet)
    attached = attach(f, packet, prepared)
    assert attached['ok'], attached
    assert attached['control']['limits']['batteryFloor'] == 50, attached
    assert attached['control']['limits']['maxHoldHours'] == 0.5, attached
    passed('root independently preserves stricter legacy battery limits at the first common handoff')

with Fixture(manualClock=100) as f:
    packet = lease(); prepared = prepare(f, packet)
    old_epoch = prepared['epoch']; f.stop(); f.start()
    assert f.ok('snapshot')['epoch'] != old_epoch
    denied = attach(f, packet, prepared)
    assert not denied['ok'] and denied['error'] == 'staleRevision', denied
    fresh = f.ok('snapshot'); denied = f.rpc('attachWorkSession', epoch=fresh['epoch'], revision=fresh['revision'], workSession=packet)
    assert not denied['ok'] and denied['error'] == 'invalidWorkLease', denied
    passed('helper restart clears preparation; rewriting its epoch cannot revive the old receipt')

with Fixture(control=dict(enabled=False), manualClock=100, lid='closed') as f:
    packet = lease()
    packet.pop('executionVersion'); packet.pop('lidPermit')
    packet['reasons'] = ['manual']; packet['manualDeadline'] = 600
    original = copy.deepcopy(packet)
    before = f.ok('snapshot')
    denied = attach(f, packet, prepare(f, packet))
    assert not denied['ok'] and denied['error'] == 'unsupportedVersion', denied
    assert denied['control'] == before['control'] and packet == original, denied
    assert not denied['status']['ownsOverride'], denied
    f.stop(); f.patch(manualClock=101); f.start()
    denied = attach(f, packet, prepare(f, packet))
    assert not denied['ok'] and denied['error'] == 'unsupportedVersion', denied
    empty = copy.deepcopy(packet); empty.update(sequence=2, reasons=[], expiry=None)
    empty.pop('manualDeadline')
    released = attach(f, empty, prepare(f, empty))
    assert released['ok'] and not released['status']['ownsOverride'], released
    packet['sequence'] = 3
    denied = f.rpc('syncWorkSession', workSession=packet)
    assert denied['error'] == 'unsupportedVersion' and not denied['status']['ownsOverride'], denied
    assert 'disablesleep 1' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
    passed('legacy active handoff is rejected across restart and empty release without rewriting its original payload or reviving work')

print(json.dumps({'passed': count, 'failed': 0,
                  'scope': 'real isolated helper and kernel-peer IPC; dry-run OS writes',
                  'native_root_execution_proven': False, 'physical_behavior_proven': False}), flush=True)
