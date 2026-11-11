#!/usr/bin/env python3
"""Real helper/IPC; display evidence and every power write use isolated dry-run data."""
import copy
import json
import uuid
from service_fixture import Fixture


def screen(id=42, vendor=123, model=456, active=True):
    return dict(id=id, builtIn=False, vendor=vendor, model=model, width=2560,
                height=1440, active=active, asleep=False)


def profile(displays, transport='spdisplays_hdmi'):
    return {'SPDisplaysDataType': [{'spdisplays_ndrvs': [
        {'_name': 'Fixture monitor', '_spdisplays_displayID': format(d['id'], 'x'),
         '_spdisplays_display-vendor-id': format(d['vendor'], 'x'),
         '_spdisplays_display-product-id': format(d['model'], 'x'),
         'spdisplays_connection_type': transport} for d in displays]}]}


def attach_work(f):
    packet = {'version': 1, 'executionVersion': 3, 'sessionID': str(uuid.uuid4()), 'sequence': 1,
              'power': 'ac', 'expiry': 115, 'reasons': ['automatic', 'manual'],
              'manualRequestID': str(uuid.uuid4()),
              'lidPermit': {'powerScopes': ['ac'], 'disconnectAction': 'sleepIfClosed', 'protectiveAction': 'sleepIfClosed'},
              'configuration': {'enabled': True, 'automaticEnabled': True, 'condition': 'ac',
                                'automaticMinutes': 60, 'limits': {'batteryFloor': 30}}}
    before = f.ok('snapshot')
    empty = copy.deepcopy(packet); empty['reasons'] = []; empty['expiry'] = None
    empty.pop('lidPermit', None)
    r = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)
    receipt = r['workSessionPreparation']
    reply = f.ok('attachWorkSession', epoch=receipt['epoch'], revision=receipt['revision'], workSession=packet)
    return reply['status']['workSession'], reply


def step(f, **values):
    f.patch(**values)
    return f.ok('markDiagnostic')


count = 0
def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)


wired = [screen()]
with Fixture(legacy_state=False, manualClock=100) as f:
    packet, r = attach_work(f)
    assert r['status']['ownsOverride'], r
    r = step(f, displayObservations=wired, displayProfile=profile(wired), clamshellCausesSleep=False)
    assert r['status'].get('nativeDisplayVerified') and not r['status']['ownsOverride'], r
    step(f, lid='closed')
    mark = len(f.logs())
    r = step(f, power='battery')
    assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
    assert 'IOPMSleepSystem' in f.logs()[mark:] and 'disablesleep 0' not in f.logs()[mark:], f.logs()
    passed('native handoff retains the managed session release on closed-lid AC departure without writing a foreign flag')

with Fixture(legacy_state=False, manualClock=100, displayObservations=wired,
             displayProfile=profile(wired), clamshellCausesSleep=False) as f:
    _, r = attach_work(f)
    assert r['status'].get('nativeDisplayVerified') and not r['status']['ownsOverride'], r
    step(f, lid='closed')
    mark = len(f.logs())
    step(f, power='battery')
    assert 'IOPMSleepSystem' not in f.logs()[mark:], f.logs()
    passed('a setup that only used native clamshell never inherits Tether release responsibility')

with Fixture(legacy_state=False, manualClock=100) as f:
    packet, r = attach_work(f)
    assert r['status']['ownsOverride'], r
    mark = len(f.logs())
    r = step(f, displayObservations=wired, displayProfile=profile(wired), clamshellCausesSleep=False)
    assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
    assert r['status'].get('nativeDisplayVerified') is True, r
    assert r['status']['workSession'] == packet, r
    assert r['status']['manualSession']['active'], r
    assert 'IOPMSleepSystem' not in f.logs()[mark:] and 'displaysleepnow' not in f.logs()[mark:]
    passed('matched wired display and observed OS policy release only root lid support; common grant remains unchanged')
    r = step(f, lid='closed')
    assert r['status'].get('nativeDisplayVerified') and not r['status']['ownsOverride'], r
    r = step(f, displayObservations=[screen(vendor=0xeee0, model=0xeee1)])
    assert not r['status'].get('nativeDisplayVerified') and r['status']['ownsOverride'], r
    assert r['status']['workSession'] == packet, r
    passed('closed native setup is retained; replacing it with a virtual display restores the same work grant')
    r = step(f, power='battery')
    assert not r['status']['ownsOverride'] and not r['status'].get('nativeDisplayVerified'), r
    passed('power-condition mismatch releases lid support without claiming simulated actual Sleep')

for transport in ['spdisplays_usb', 'spdisplays_airplay', 'unknown']:
    with Fixture(legacy_state=False, manualClock=100, displayObservations=wired,
                 displayProfile=profile(wired, transport), clamshellCausesSleep=False) as f:
        _, r = attach_work(f)
        assert r['status']['ownsOverride'] and not r['status'].get('nativeDisplayVerified'), r
        assert 'disablesleep 0' not in f.logs(), f.logs()
        passed(transport + ' is not upgraded into native wired clamshell evidence')

with Fixture(legacy_state=False, manualClock=100, lid='closed') as f:
    packet, _ = attach_work(f)
    mark = len(f.logs())
    r = step(f, displayObservations=wired, displayProfile=profile(wired), clamshellCausesSleep=False)
    assert r['status']['ownsOverride'] and not r['status'].get('nativeDisplayVerified'), r
    assert 'disablesleep 0' not in f.logs()[mark:], f.logs()[mark:]
    r = step(f, lid='open')
    assert not r['status']['ownsOverride'] and r['status'].get('nativeDisplayVerified'), r
    assert r['status']['workSession'] == packet, r
    passed('an owned closed-lid hold is never trial-released; opening permits policy-confirmed handoff')

for unavailable in [True, None]:
    with Fixture(legacy_state=False, manualClock=100) as f:
        _, _ = attach_work(f)
        mark = len(f.logs())
        r = step(f, displayObservations=wired, displayProfile=profile(wired), clamshellCausesSleep=unavailable)
        assert r['status']['ownsOverride'] and not r['status'].get('nativeDisplayVerified'), r
        first = f.logs()[mark:]
        assert first.count('disablesleep 0') == 1 and first.count('disablesleep 1') == 1, first
        r = step(f)
        assert f.logs()[mark:].count('disablesleep 0') == 1, f.logs()[mark:]
        passed('missing or sleep-enabled OS policy restores the own hold once and cannot create a retry loop')

for failure in ['commandFailure', 'commandNoEffect']:
    with Fixture(legacy_state=False, manualClock=100) as f:
        packet, _ = attach_work(f)
        f.patch(displayObservations=wired, displayProfile=profile(wired), clamshellCausesSleep=False, **{failure: True})
        r = f.rpc('markDiagnostic')
        assert not r['ok'] and r['error'] in ['pmsetFailed', 'powerVerificationFailed'], r
        assert r['status']['ownsOverride'] and r['status']['sleepDisabled'], r
        assert not r['status'].get('nativeDisplayVerified') and r['status']['workSession'] == packet, r
        assert r['protection'].get('blockReason') is None, r
        passed(failure + ' cannot report native handoff, discard ownership, or end common work')

with Fixture(legacy_state=False, manualClock=100, sleepDisabled=True, displayObservations=wired,
             displayProfile=profile(wired), clamshellCausesSleep=False) as f:
    _, r = attach_work(f)
    assert not r['status']['ownsOverride'] and r['status']['sleepDisabled'], r
    assert not r['status'].get('nativeDisplayVerified') and 'disablesleep 0' not in f.logs(), r
    passed('a foreign override is not released or used as native-policy evidence')

with Fixture(legacy_state=False, manualClock=100, nativeDisplayProbePending=True) as f:
    packet, r = attach_work(f)
    assert not r['status']['ownsOverride'] and 'disablesleep 1' not in f.logs(), r
    assert r['status']['workSession'] == packet, r
    r = step(f, nativeDisplayProbePending=False)
    assert r['status']['ownsOverride'] and r['status']['workSession'] == packet, r
    passed('pending native evidence defers a new global write without changing the finite work grant')

with Fixture(legacy_state=False, manualClock=100) as f:
    packet, _ = attach_work(f)
    mark = len(f.logs())
    r = step(f, manualClock=115, displayObservations=wired, displayProfile=profile(wired), clamshellCausesSleep=True)
    assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
    assert 'disablesleep 1' not in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:], f.logs()[mark:]
    passed('expired work cannot trial-release and reacquire at a native topology transition')

print(json.dumps({'cases': count, 'powerWrites': 'dry-run only', 'physicalSleep': 'not tested'}))
