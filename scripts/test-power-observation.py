#!/usr/bin/env python3
"""Real private helper/IPC. Missing OS readings and every power write are dry-run."""
import copy
import json
import uuid
from service_fixture import Fixture


def attach(f, preparation_error=None):
    packet = {'version': 1, 'executionVersion': 3, 'sessionID': str(uuid.uuid4()), 'sequence': 1,
              'power': 'ac', 'expiry': 130, 'reasons': ['automatic', 'manual'],
              'manualRequestID': str(uuid.uuid4()),
              'lidPermit': {'powerScopes': ['ac'], 'disconnectAction': 'sleepIfClosed', 'protectiveAction': 'sleepIfClosed'},
              'configuration': {'enabled': True, 'automaticEnabled': True, 'condition': 'ac',
                                'automaticMinutes': 60, 'limits': {'batteryFloor': 30}}}
    if f.readings.get('lid') is None or f.readings.get('sleepDisabled') is None:
        packet.pop('lidPermit') # Only general work is requested while lid execution cannot be observed.
    before = f.ok('snapshot')
    empty = copy.deepcopy(packet); empty['reasons'] = []; empty['expiry'] = None
    empty.pop('lidPermit', None)
    prepared = f.rpc('prepareWorkSession', epoch=before['epoch'], revision=before['revision'],
                     workSession=empty)
    if preparation_error is not None:
        assert not prepared['ok'] and prepared['error'] == preparation_error, prepared
        return None, prepared
    assert prepared['ok'], prepared
    receipt = prepared['workSessionPreparation']
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


for field, status_field in [('lid', 'lidObservationAvailable'),
                            ('sleepDisabled', 'sleepOverrideObservationAvailable')]:
    with Fixture(manualClock=100, legacy_state=False, **{field: None}) as f:
        packet, r = attach(f)
        assert r['status']['ownsOverride'] is False, r
        assert r['status'].get(status_field) in [False, None], r
        assert r['status']['workSession'] == packet and r['status']['manualSession']['active'], r
        assert 'command request:' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
        passed(field + ': missing reading cannot acquire a global override or discard the common work grant')

with Fixture(manualClock=100, fullWake=None) as f:
    _, r = attach(f, preparation_error='sessionUnavailable')
    assert r['status']['ownsOverride'] is False, r
    assert not r['status'].get('workSession') and not r['status']['manualSession']['active'], r
    assert 'command request:' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
    passed('unknown initial FullWake refuses preparation rather than inventing a work grant')

for field, status_field in [('lid', 'lidObservationAvailable'),
                            ('sleepDisabled', 'sleepOverrideObservationAvailable'), ('fullWake', 'fullWake')]:
    with Fixture(manualClock=100) as f:
        packet, r = attach(f)
        assert r['status']['ownsOverride'], r
        ownership = f.folder / 'power-ownership.json'; journal = ownership.read_bytes()
        mark = len(f.logs())
        f.patch(**{field: None})
        r = f.rpc('markDiagnostic')
        if field == 'sleepDisabled':
            assert not r['ok'] and r['error'] == 'powerObservationUnavailable', r
            assert r['status']['ownsOverride'] and ownership.read_bytes() == journal, r
            assert 'command request:' not in f.logs()[mark:], f.logs()[mark:]
        else:
            assert r['ok'] and not r['status']['ownsOverride'] and not json.loads(ownership.read_bytes())['owned'], r
            assert f.logs()[mark:].count('disablesleep 0') == 1, f.logs()[mark:]
        assert r['status'].get(status_field) in [False, None], r
        assert r['status']['workSession'] == packet and r['protection'].get('blockReason') is None, r
        assert 'IOPMSleepSystem' not in f.logs()[mark:]
        passed(field + ': missing execution scope releases only verifiable own state; unreadable recovery debt and grant deadline remain intact')
        r = step(f, **{field: {'lid': 'open', 'sleepDisabled': True, 'fullWake': True}[field]})
        assert r['status']['ownsOverride'] and r['status']['workSession'] == packet, r
        assert r['protection'].get('blockReason') is None, r
        passed(field + ': fresh observation restores verification without restarting the session')

wired = [{'id': 42, 'builtIn': False, 'vendor': 123, 'model': 456,
          'width': 2560, 'height': 1440, 'active': True, 'asleep': False}]
profile = {'SPDisplaysDataType': [{'spdisplays_ndrvs': [{'_name': 'Fixture monitor',
    '_spdisplays_displayID': '2a', '_spdisplays_display-vendor-id': '7b',
    '_spdisplays_display-product-id': '1c8', 'spdisplays_connection_type': 'spdisplays_hdmi'}]}]}
with Fixture(manualClock=100) as f:
    packet, _ = attach(f); mark = len(f.logs())
    r = step(f, lid=None, displayObservations=wired, displayProfile=profile, clamshellCausesSleep=False)
    assert not r['status']['ownsOverride'] and not r['status']['nativeDisplayVerified'], r
    assert f.logs()[mark:].count('disablesleep 0') == 1, f.logs()[mark:]
    r = step(f, lid='open')
    assert r['status']['nativeDisplayVerified'] and not r['status']['ownsOverride'], r
    assert r['status']['workSession'] == packet, r
    assert f.logs()[mark:].count('disablesleep 0') == 1, f.logs()[mark:]
    passed('missing lid releases own execution without claiming native handoff; a confirmed lid completes native evidence without another write')

with Fixture(manualClock=100) as f:
    _, _ = attach(f); mark = len(f.logs())
    step(f, lid=None, fullWake=None)
    r = f.ok('stop')
    assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
    assert 'disablesleep 0' in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:]
    passed('explicit stop releases a confirmed own override even when lid/wake are unreadable; no guessed Sleep')

with Fixture(manualClock=100) as f:
    _, _ = attach(f); mark = len(f.logs())
    f.patch(sleepDisabled=None)
    r = f.rpc('detachApp')
    assert not r['ok'] and r['error'] == 'powerObservationUnavailable', r
    assert r['status']['ownsOverride'] and (f.folder / 'power-ownership.json').exists(), r
    assert 'disablesleep 0' not in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:]
    r = step(f, sleepDisabled=True, manualClock=131)
    assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
    passed('unreadable own release is not acknowledged as complete; recovery remains and resolves after a fresh read')

with Fixture(manualClock=100, legacy_state=False, sleepDisabled=None) as f:
    _, _ = attach(f); mark = len(f.logs())
    r = f.ok('detachApp')
    assert not r['status']['ownsOverride'], r
    assert 'command request:' not in f.logs()[mark:], f.logs()[mark:]
    passed('an unowned unknown setting is never cleared during quit')

with Fixture(manualClock=100) as f:
    packet, _ = attach(f); mark = len(f.logs())
    f.patch(displayObservations=wired, displayProfile=profile, clamshellCausesSleep=False,
            sleepDisabledUnreadableAfterWrite=False)
    r = f.rpc('markDiagnostic')
    assert not r['ok'] and r['error'] == 'powerObservationUnavailable', r
    assert r['status']['ownsOverride'] and not r['status']['nativeDisplayVerified'], r
    assert r['status']['sleepOverrideObservationAvailable'] is False, r
    assert (f.folder / 'power-ownership.json').exists()
    r = step(f, sleepDisabledUnreadableAfterWrite=None)
    assert not r['status']['ownsOverride'] and r['status']['nativeDisplayVerified'], r
    assert r['protection'].get('blockReason') is None and r['status']['workSession'] == packet, r
    assert f.logs()[mark:].count('disablesleep 0') == 1, f.logs()[mark:]
    passed('accepted release with unreadable effect retains its exact record; later confirmation does not invent a foreign conflict')

for field in ['sleepDisabled', 'fullWake']:
    with Fixture(manualClock=100, legacy_state=field != 'sleepDisabled', lid='closed', **({'sleepDisabled': None} if field == 'sleepDisabled' else {})) as f:
        _, _ = attach(f); mark = len(f.logs())
        if field == 'fullWake':
            # First attach during confirmed FullWake, then lose that observation.
            step(f, fullWake=None)
        r = f.rpc('sleep')
        if field == 'sleepDisabled':
            assert not r['ok'] and r['error'] == 'powerObservationUnavailable', r
        assert 'IOPMSleepSystem' not in f.logs()[mark:] and 'displaysleepnow' not in f.logs()[mark:]
        passed(field + ': neither explicit Sleep nor all-display sleep is sent from an unverified reading')

with Fixture(legacy_state=False, manualClock=100, lid='closed', displayClock=100, displaySleeping=False) as f:
    _, r = attach(f)
    assert r['status']['displayRecovery']['requests'] == 0, r
    mark = len(f.logs())
    r = step(f, lid=None, displayClock=105)
    assert r['status']['displayRecovery']['requests'] == 0, r
    assert 'displaysleepnow' not in f.logs()[mark:], f.logs()[mark:]
    r = step(f, lid='closed', displayClock=111)
    assert r['status']['displayRecovery']['requests'] == 0, r
    assert 'displaysleepnow' not in f.logs()[mark:], f.logs()[mark:]
    passed('a power-reading gap cannot activate the retired automatic display writer')

print(json.dumps({'cases': count, 'powerWrites': 'dry-run only', 'physicalSleep': 'not tested'}))
