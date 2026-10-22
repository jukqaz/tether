#!/usr/bin/env python3
"""Unresolved/corrupt writer state must block the real helper, with dry-run OS writes."""
import json
import os
from service_fixture import Fixture

def pending(f, kind):
    path = f.folder/'power-writer.json'
    value = dict(schema=1, transaction='99BD03DA-4082-4AD3-9AB2-5D1E9B278273', phase='writerUnresolved',
        boot='dry-run', owner=dict(pid=os.getpid(), uid=os.geteuid(), started=1, executable='/usr/bin/python3'),
        executable='/usr/bin/pmset', arguments=['-a','disablesleep','1'], deadline=1, inheritsRecoveryLock=True)
    if kind == 'old-boot': value['boot'] = 'previous-boot'
    if kind == 'future': value['schema'] = 99
    path.write_text('{' if kind == 'malformed' else json.dumps(value)); path.chmod(0o644 if kind == 'permissions' else 0o600)
    return path

count = 0
for kind in ['unresolved', 'malformed', 'future', 'permissions']:
    with Fixture(control={'enabled':False}) as f:
        f.ok('attachApp'); path = pending(f, kind); before = path.read_bytes()
        state = f.ok('snapshot')
        reply = f.rpc('configure', control=state['control'] | {'enabled':True}, epoch=state['epoch'], revision=state['revision'])
        assert not reply['ok'] and reply['error'] == 'powerWriterUnresolved', reply
        assert not reply['status']['sleepDisabled'] and not reply['status']['ownsOverride'], reply
        assert path.read_bytes() == before and 'command request: pmset -a disablesleep 1' not in f.logs()
        path.unlink(); state=f.step()['status']
        assert state['sleepDisabled'] and state['ownsOverride'], state
        print('PASS writer guard new acquisition', kind, flush=True); count += 1

with Fixture() as f:
    f.ok('attachApp'); assert f.ok('snapshot')['status']['ownsOverride']
    path=pending(f,'unresolved'); ownership=f.folder/'power-ownership.json'; saved=ownership.read_bytes()
    state=f.ok('snapshot'); reply=f.rpc('configure', control=state['control']|{'enabled':False}, epoch=state['epoch'], revision=state['revision'])
    assert not reply['ok'] and reply['error']=='powerWriterUnresolved', reply
    assert reply['status']['sleepDisabled'] and reply['status']['ownsOverride'], reply
    assert ownership.read_bytes()==saved and 'command request: pmset -a disablesleep 0' not in f.logs()
    path.unlink(); state=f.step()['status']; assert not state['sleepDisabled'] and not state['ownsOverride'],state
    print('PASS writer guard retains the owned lease until writer recovery', flush=True); count += 1

with Fixture(control={'enabled':False}) as f:
    f.ok('attachApp'); path=pending(f,'old-boot'); state=f.config(enabled=True)['status']
    assert not path.exists() and state['sleepDisabled'] and state['ownsOverride'], state
    print('PASS writer from a previous boot does not block the current transaction', flush=True); count += 1
print('TOTAL',count,'helper writer guard scenarios passed',flush=True)
