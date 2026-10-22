#!/usr/bin/env python3
"""Real private helper/IPC. Missing OS readings and every power write are dry-run."""
import copy
import json
import uuid
from service_fixture import Fixture


def attach(f, preparation_error=None, display_mode=None):
    packet = {'version': 1, 'executionVersion': 3, 'sessionID': str(uuid.uuid4()), 'sequence': 1,
              'power': 'ac', 'expiry': 115, 'reasons': ['automatic', 'manual'],
              'manualRequestID': str(uuid.uuid4()),
              'lidPermit': {'powerScopes': ['ac'], 'disconnectAction': 'sleepIfClosed', 'protectiveAction': 'sleepIfClosed'},
              'configuration': {'enabled': True, 'automaticEnabled': True, 'condition': 'ac',
                                'automaticMinutes': 60, 'limits': {'batteryFloor': 30}}}
    if display_mode is not None:
        packet['closedLidDisplayMode'] = display_mode
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
        assert r['ok'] and r['status']['ownsOverride'] and ownership.read_bytes() == journal, r
        assert 'command request:' not in f.logs()[mark:], f.logs()[mark:]
        assert r['status'].get(status_field) in [False, None], r
        assert r['status']['workSession'] == packet and r['protection'].get('blockReason') is None, r
        assert 'IOPMSleepSystem' not in f.logs()[mark:]
        passed(field + ': an observation gap creates no new permission and preserves only the original finite owned grant or unreadable recovery debt')
        r = step(f, **{field: {'lid': 'open', 'sleepDisabled': True, 'fullWake': True}[field]})
        assert r['status']['ownsOverride'] and r['status']['workSession'] == packet, r
        assert r['protection'].get('blockReason') is None, r
        passed(field + ': fresh observation restores verification without restarting the session')

with Fixture(manualClock=100) as f:
    packet, _ = attach(f)
    ownership = f.folder / 'power-ownership.json'; journal = ownership.read_bytes()
    mark = len(f.logs())
    held = step(f, sleepDisabled=None, manualClock=114)
    assert held['status']['ownsOverride'] and held['status']['sleepOverrideObservationAvailable'] is False, held
    assert held['status']['workSession'] == packet and ownership.read_bytes() == journal, held
    renewal = copy.deepcopy(packet); renewal.update(sequence=2, expiry=129)
    denied = f.rpc('syncWorkSession', workSession=renewal)
    assert denied['error'] == 'powerObservationUnavailable' and denied['status']['workSession'] == packet, denied
    assert 'command request:' not in f.logs()[mark:], f.logs()[mark:]
    f.patch(manualClock=115)
    expired = f.rpc('markDiagnostic')
    assert expired['error'] == 'powerObservationUnavailable' and expired['status']['ownsOverride'], expired
    assert expired['status']['sleepOverrideObservationAvailable'] is False and 'workSession' not in expired['status'], expired
    assert expired['workSessionBridge']['lidProtection']['reason'] == 'powerObservationUnavailable', expired
    assert ownership.read_bytes() == journal and 'command request:' not in f.logs()[mark:], f.logs()[mark:]
    f.patch(sleepDisabled=True, manualClock=116)
    pending = f.rpc('markDiagnostic')
    assert not pending['ok'] and pending['status']['ownsOverride'] and 'workSession' not in pending['status'], pending
    recovered = step(f, manualClock=145)
    assert not recovered['status']['ownsOverride'] and not recovered['status']['sleepDisabled'], recovered
    assert 'workSession' not in recovered['status'] and 'IOPMSleepSystem' not in f.logs()[mark:], recovered
    assert f.logs()[mark:].count('command request: pmset -a disablesleep 0') == 1, f.logs()[mark:]
    returned = step(f, manualClock=146)
    assert not returned['status']['ownsOverride'] and 'workSession' not in returned['status'], returned
    passed('unknown override readback grants no renewal, consumes at 115, retains unverified debt, and recovers only owned settings at 145')

wired = [{'id': 42, 'builtIn': False, 'vendor': 123, 'model': 456,
          'width': 2560, 'height': 1440, 'active': True, 'asleep': False}]
profile = {'SPDisplaysDataType': [{'spdisplays_ndrvs': [{'_name': 'Fixture monitor',
    '_spdisplays_displayID': '2a', '_spdisplays_display-vendor-id': '7b',
    '_spdisplays_display-product-id': '1c8', 'spdisplays_connection_type': 'spdisplays_hdmi'}]}]}
with Fixture(manualClock=100) as f:
    packet, _ = attach(f); mark = len(f.logs())
    r = step(f, lid=None, displayObservations=wired, displayProfile=profile, clamshellCausesSleep=False)
    assert r['status']['ownsOverride'] and not r['status']['nativeDisplayVerified'], r
    assert 'disablesleep 0' not in f.logs()[mark:], f.logs()[mark:]
    r = step(f, lid='open')
    assert r['status']['nativeDisplayVerified'] and not r['status']['ownsOverride'], r
    assert r['status']['workSession'] == packet, r
    assert f.logs()[mark:].count('disablesleep 0') == 1, f.logs()[mark:]
    passed('missing lid preserves only the existing finite override without claiming native handoff; a fresh lid completes handoff with one own release')

for missing in ['lid', 'fullWake']:
    with Fixture(manualClock=100) as f:
        _, initial = attach(f)
        mark = len(f.logs())
        held = step(f, manualClock=114, **{missing: None})
        assert held['status']['ownsOverride'] and held['status']['sleepDisabled'], held
        assert held['status']['workSession']['expiry'] == 115, held
        assert 'command request:' not in f.logs()[mark:], f.logs()[mark:]
        expired = step(f, manualClock=115)
        assert not expired['status']['ownsOverride'] and not expired['status']['sleepDisabled'], expired
        assert 'workSession' not in expired['status'], expired
        assert 'IOPMSleepSystem' not in f.logs()[mark:], f.logs()[mark:]
        returned = step(f, manualClock=116, **{missing: 'open' if missing == 'lid' else True})
        assert not returned['status']['ownsOverride'] and 'workSession' not in returned['status'], returned
        passed(missing + ': exact 15-second expiry releases only own resources and a normal sample cannot revive the consumed grant')

with Fixture(manualClock=100) as f:
    _, _ = attach(f); mark = len(f.logs())
    step(f, lid=None, fullWake=None)
    r = f.ok('stop')
    assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
    assert 'workSession' not in r['status'] and r['workSessionBridge']['stopRequested'], r
    assert 'disablesleep 0' in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:]
    passed('explicit stop releases a confirmed own override even when lid/wake are unreadable; no guessed Sleep')

with Fixture(manualClock=100) as f:
    _, _ = attach(f); mark = len(f.logs())
    ownership = f.folder / 'power-ownership.json'; journal = ownership.read_bytes()
    step(f, sleepDisabled=None)
    stopped = f.rpc('stop')
    assert stopped['error'] == 'powerObservationUnavailable' and stopped['status']['ownsOverride'], stopped
    assert 'workSession' not in stopped['status'] and stopped['workSessionBridge']['stopRequested'], stopped
    assert stopped['status']['sleepOverrideObservationAvailable'] is False and ownership.read_bytes() == journal, stopped
    assert 'command request:' not in f.logs()[mark:] and 'IOPMSleepSystem' not in f.logs()[mark:], f.logs()[mark:]
    recovered = step(f, sleepDisabled=True, manualClock=131)
    assert not recovered['status']['ownsOverride'] and not recovered['status']['sleepDisabled'], recovered
    assert 'workSession' not in recovered['status'] and recovered['workSessionBridge']['stopRequested'], recovered
    assert 'IOPMSleepSystem' not in f.logs()[mark:], f.logs()[mark:]
    passed('accepted stop consumes work immediately during unknown readback, while unverified restoration remains debt until confirmed')

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
    _, r = attach(f, display_mode='unchanged')
    assert r['status']['displayRecovery']['requests'] == 0, r
    mark = len(f.logs())
    r = step(f, lid=None, displayClock=105)
    assert r['status']['displayRecovery']['requests'] == 0, r
    assert 'displaysleepnow' not in f.logs()[mark:], f.logs()[mark:]
    r = step(f, lid='closed', displayClock=111)
    assert r['status']['displayRecovery']['requests'] == 0, r
    assert 'displaysleepnow' not in f.logs()[mark:], f.logs()[mark:]
    passed('a power-reading gap cannot activate a display writer when the saved choice is unchanged')

print(json.dumps({'cases': count, 'powerWrites': 'dry-run only', 'physicalSleep': 'not tested'}))
