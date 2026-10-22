#!/usr/bin/env python3
"""Real helper/IPC, with every power/display operation in the isolated dry-run fixture."""
import copy
import json
import uuid
from service_fixture import Fixture

count = 0


def passed(label):
    global count
    count += 1
    print('PASS', label, flush=True)


def lease(sequence=1, power='ac', expiry=130, reasons=None, session=None, execution=3, **configuration):
    result = {'version': 1, 'sessionID': session or str(uuid.uuid4()), 'sequence': sequence,
              'power': power, 'expiry': expiry, 'reasons': reasons if reasons is not None else ['automatic'],
              'configuration': {'enabled': True, 'automaticEnabled': True, 'condition': 'ac',
                                'automaticMinutes': 60, 'limits': {'batteryFloor': 30}} | configuration}
    if execution is not None:
        result['executionVersion'] = execution
    if result['reasons'] and execution == 3:
        result['lidPermit'] = {'powerScopes': [power], 'disconnectAction': 'sleepIfClosed',
                               'protectiveAction': 'sleepIfClosed'}
        if 'manual' in result['reasons']:
            result['manualRequestID'] = str(uuid.uuid4())
        if power == 'battery':
            result['lidPermit'].update(batteryPermitID=result.get('manualRequestID', str(uuid.uuid4())),
                                       batteryDuration=7200, batteryDeadline=7300, batteryMaximumDeadline=7300)
    return result


def empty_lease(packet, **changes):
    result = copy.deepcopy(packet)
    result.update(reasons=[], expiry=None, **changes)
    for key in ['manualDeadline', 'manualRequestID', 'manualExtensionID', 'lidPermit', 'powerTransition']:
        result.pop(key, None)
    return result


def attach_work(f, packet, *, expected_error=None):
    before = f.ok('snapshot')
    empty = empty_lease(packet)
    empty.pop('manualDeadline', None)
    prepared = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)
    receipt = prepared['workSessionPreparation']
    if expected_error is not None:
        denied = f.rpc('attachWorkSession', epoch=receipt['epoch'], revision=receipt['revision'], workSession=packet)
        assert not denied['ok'] and denied['error'] == expected_error, denied
        return denied
    return f.ok('attachWorkSession', epoch=receipt['epoch'], revision=receipt['revision'], workSession=packet)


def reject_legacy_then_upgrade(f, packet, *, expected_error='unsupportedVersion'):
    original = copy.deepcopy(packet)
    before = f.ok('snapshot')
    denied = attach_work(f, packet, expected_error=expected_error)
    assert packet == original and denied['control'] == before['control'], denied
    assert denied['status']['ownsOverride'] == before['status']['ownsOverride'], denied
    empty = empty_lease(packet, sequence=packet['sequence'] + 1)
    empty['executionVersion'] = 3
    empty['configuration'].update(condition='ac', automaticEnabled=False)
    empty['configuration'].pop('manualBatteryContinuationMinutes', None)
    upgraded = attach_work(f, empty)
    assert not upgraded['status']['ownsOverride'] and not upgraded['status']['sleepDisabled'], upgraded
    assert upgraded['workSessionBridge'].get('powerTransition') is None, upgraded
    return upgraded


# This is an injected registration failure, not an observed failure on the Mac.
# Empty preparation/attachment is still needed to transfer saved protection to
# the GUI before it can positively detach root support and keep ordinary work.
for unavailable in [False, None, 'unavailable']:
    with Fixture(manualClock=100, systemPowerObservationAvailable=unavailable) as f:
        initial = f.ok('markDiagnostic')
        assert initial['status']['systemPowerObservationAvailable'] is False, initial
        assert not initial['status']['ownsOverride'] and not initial['status']['sleepDisabled'], initial
        assert initial['control']['enabled'] and initial['protection'].get('blockReason') is None, initial
        assert 'disablesleep 1' not in f.logs(), f.logs()
        f.ok('attachApp')
        assert f.rpc('startManualSession', minutes=30)['error'] == 'powerObservationUnavailable'
        before_retired = f.ok('snapshot')
        assert f.rpc('startHold', minutes=30)['error'] == 'unsupportedVersion'
        assert f.ok('snapshot')['control'] == before_retired['control']
        f.ok('stop')
        resumed = f.ok('resume')
        assert resumed['control']['enabled'] and not resumed['status']['ownsOverride'], resumed
        detached = f.ok('detachApp')
        assert detached['status']['systemPowerObservationAvailable'] is False and not detached['status']['ownsOverride'], detached
        assert not (f.folder / 'power-ownership.json').exists() and 'disablesleep 1' not in f.logs(), f.logs()
        passed('injected sleep observer ' + repr(unavailable)
               + ': legacy acquisition/manual/hold denied; configuration, stop, resume and detach remain available')

with Fixture(control=dict(enabled=False), manualClock=100, systemPowerObservationAvailable=False) as f:
    packet = lease()
    before = f.ok('snapshot')
    empty = empty_lease(packet)
    empty['configuration'].update(enabled=False, automaticEnabled=False)
    prepared = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)
    proof = prepared['workSessionPreparation']
    assert prepared['status']['systemPowerObservationAvailable'] is False and prepared['status']['appConnected'], prepared
    assert not prepared['control']['enabled'] and prepared['workSessionBridge']['automaticBudget'] == before['workSessionBridge']['automaticBudget'], prepared
    denied = f.rpc('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'], workSession=packet)
    assert denied['error'] == 'powerObservationUnavailable' and denied['status']['systemPowerObservationAvailable'] is False, denied
    assert denied['control'] == prepared['control'] and not denied['status']['ownsOverride'], denied
    attached = f.ok('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'], workSession=empty)
    assert attached['workSessionBridge']['coordinated'] and attached['status']['workSession']['reasons'] == [], attached
    assert not attached['status']['ownsOverride'] and not attached['control']['enabled'], attached
    synced = f.ok('syncWorkSession', workSession=empty | dict(sequence=2))
    detached = f.ok('detachApp')
    assert not synced['status']['ownsOverride'] and not detached['status']['ownsOverride'], (synced, detached)
    assert 'disablesleep 1' not in f.logs(), f.logs()
    passed('failed observer allows protected empty preparation/attach/sync/detach but denies a nonempty first grant without changing off')

with Fixture(manualClock=100) as f:
    packet = lease(reasons=['automatic', 'manual']); packet['manualDeadline'] = 600
    before = f.ok('snapshot')
    empty = empty_lease(packet)
    proof = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'],
                 workSession=empty)['workSessionPreparation']
    attach_id = str(uuid.uuid4())
    f.ok('attachWorkSession', id=attach_id, epoch=proof['epoch'], revision=proof['revision'], workSession=packet)
    current = packet | dict(sequence=2)
    sync_id = str(uuid.uuid4())
    holding = f.ok('syncWorkSession', id=sync_id, workSession=current)
    assert holding['status']['systemPowerObservationAvailable'] is True and holding['status']['ownsOverride'], holding
    retained = {key: holding['workSessionBridge'].get(key) for key in ['automaticBudget', 'manualBudget', 'stopRequested']}
    mark = len(f.logs())
    f.patch(systemPowerObservationAvailable=False, manualClock=101)
    for action, values in [('syncWorkSession', dict(id=sync_id, workSession=current)),
                           ('attachWorkSession', dict(id=attach_id, epoch=proof['epoch'], revision=proof['revision'], workSession=packet))]:
        denied = f.rpc(action, **values)
        assert denied['error'] == 'powerObservationUnavailable' and denied['status']['systemPowerObservationAvailable'] is False, denied
        assert not denied['status']['ownsOverride'] and not denied['status']['sleepDisabled'], denied
        assert denied['status']['manualSession']['active'] and not denied['status']['manualSession']['holding'], denied
        assert denied['protection'].get('blockReason') is None, denied
    cleared = f.ok('syncWorkSession', workSession=empty | dict(sequence=3))
    assert cleared['control'] == holding['control'] and cleared['status']['workSession']['reasons'] == [], cleared
    for key, value in retained.items():
        assert cleared['workSessionBridge'].get(key) == value, (key, cleared)
    assert f.logs()[mark:].count('disablesleep 0') == 1 and 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    f.patch(systemPowerObservationAvailable=True, manualClock=104)
    recovered = f.ok('markDiagnostic')
    assert not recovered['status']['ownsOverride'] and recovered['status']['workSession']['reasons'] == [], recovered
    passed('failed observer defeats cached attach/sync holding ACKs; one own release and an empty sync preserve choices and budgets without reactivation')

with Fixture(manualClock=100, power='battery') as f:
    packet = lease(power='battery', reasons=['manual'], automaticEnabled=False)
    packet['manualDeadline'] = 600
    holding = attach_work(f, packet)
    retained = {key: holding['workSessionBridge'].get(key) for key in ['automaticBudget', 'manualBudget']}
    assert retained['automaticBudget'].get('batteryBudgetStart') is None, holding
    assert retained['manualBudget'] is None, holding
    battery_receipts = holding['workSessionBridge']['batteryPermitReceipts']
    assert battery_receipts[0]['observedAt'] == 100 and battery_receipts[0]['maximumDeadline'] == 7300, holding
    f.patch(systemPowerObservationAvailable=False, manualClock=101)
    empty = empty_lease(packet, sequence=2)
    cleared = f.ok('syncWorkSession', workSession=empty)
    detached = f.ok('detachApp')
    for response in [cleared, detached]:
        assert response['status']['systemPowerObservationAvailable'] is False and not response['status']['ownsOverride'], response
        for key, value in retained.items():
            assert response['workSessionBridge'].get(key) == value, (key, response)
    assert cleared['workSessionBridge']['batteryPermitReceipts'] == battery_receipts, cleared
    assert detached['workSessionBridge']['batteryPermitReceipts'] == [], detached
    assert json.loads((f.folder / 'helper-state.json').read_text())['batteryPermitReceipts'] == battery_receipts
    passed('empty sync and detach release with failed observer; durable manual receipts survive but detached bridge grants no scope or battery automatic budget')

with Fixture(manualClock=100) as f:
    holding = attach_work(f, lease())
    assert holding['status']['ownsOverride'], holding
    journal = (f.folder / 'power-ownership.json').read_bytes()
    mark = len(f.logs())
    f.patch(systemPowerObservationAvailable=False, sleepDisabled=None, manualClock=101)
    unresolved = f.rpc('detachApp')
    assert not unresolved['ok'] and unresolved['error'] == 'powerObservationUnavailable', unresolved
    assert unresolved['status']['systemPowerObservationAvailable'] is False and unresolved['status']['ownsOverride'], unresolved
    assert (f.folder / 'power-ownership.json').read_bytes() == journal and 'disablesleep 0' not in f.logs()[mark:], f.logs()[mark:]
    f.patch(sleepDisabled=True, manualClock=102)
    still_unresolved = f.rpc('markDiagnostic')
    assert still_unresolved['error'] == 'powerObservationUnavailable' and still_unresolved['status']['ownsOverride'], still_unresolved
    assert (f.folder / 'power-ownership.json').read_bytes() == journal
    f.patch(systemPowerObservationAvailable=True, manualClock=103)
    # Registration state belongs to the helper process. Restart rebuilds that
    # observer and recovers only the retained writer debt, never the old grant.
    f.stop()
    assert 'disablesleep 0' in f.logs()[mark:], f.logs()[mark:]
    # The fixture file is the next process's independent observation; mirror
    # the dry-run setter's confirmed restoration rather than a foreign true value.
    f.patch(sleepDisabled=False)
    f.start()
    recovered = f.ok('markDiagnostic')
    assert recovered['status']['systemPowerObservationAvailable'] is True and not recovered['status']['ownsOverride'], recovered
    assert not recovered['status']['sleepDisabled'] and 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    passed('observer failure does not forge successful release with an unknown setting; its own journal resolves after a fresh read')

with Fixture(manualClock=100) as f:
    assert f.ok('markDiagnostic')['status']['ownsOverride']
    # Crash only the isolated dry-run process, retaining its own recovery record.
    f.helper.kill(); f.helper.wait(timeout=5)
    mark = len(f.logs())
    f.patch(systemPowerObservationAvailable=False, sleepDisabled=True, manualClock=101)
    f.start()
    recovered = f.ok('markDiagnostic')
    assert recovered['status']['systemPowerObservationAvailable'] is False and not recovered['status']['ownsOverride'], recovered
    assert not recovered['status']['sleepDisabled'] and recovered['control']['enabled'], recovered
    assert (f.folder / 'power-ownership.json').exists(), recovered
    assert 'disablesleep 0' in f.logs()[mark:] and 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    passed('failed registration after an isolated helper crash still restores its own override and never reacquires legacy support')

with Fixture(manualClock=100, sleepDisabled=True, systemPowerObservationAvailable=False) as f:
    initial = f.ok('markDiagnostic')
    assert initial['status']['systemPowerObservationAvailable'] is False and not initial['status']['ownsOverride'], initial
    stopped = f.ok('stop')
    assert stopped['status']['sleepDisabled'] and not stopped['status']['ownsOverride'], stopped
    assert 'disablesleep 0' not in f.logs() and 'disablesleep 1' not in f.logs(), f.logs()
    passed('failed registration leaves an unowned foreign override unchanged during stop')


with Fixture(manualClock=100, lid='closed') as f:
    original = lease(reasons=['manual'], automaticEnabled=False)
    original['manualDeadline'] = 600
    attached = attach_work(f, original)
    foreign = lease(reasons=[], expiry=None)
    denied = f.rpc('prepareWorkSession', epoch=attached['epoch'], revision=attached['revision'], workSession=foreign)
    assert denied['error'] == 'invalidWorkLease' and denied.get('workSessionPreparation') is None, denied
    current = f.ok('snapshot')
    assert current['status']['ownsOverride'] and current['status']['workSession'] == attached['status']['workSession'], current
    f.patch(systemSleeping=True, manualClock=101)
    sleeping = f.ok('markDiagnostic')
    consumption = sleeping['workSessionBridge']['sleepConsumption']
    assert uuid.UUID(consumption['sessionID']) == uuid.UUID(original['sessionID']), sleeping
    assert consumption['sequence'] == original['sequence'] and not sleeping['status']['ownsOverride'], sleeping
    passed('foreign preparation cannot replace the live controller or redirect its sleep consumption')

with Fixture(manualClock=100, lid='closed') as f:
    original = lease(reasons=['manual'], automaticEnabled=False)
    original['manualDeadline'] = 600
    attach_work(f, original)
    f.stop(); f.start()
    # The persisted lease is old recovery evidence. After restart, preparation
    # for the current controller has priority over that saved session identity.
    current = lease(sequence=2, reasons=['manual'], automaticEnabled=False)
    current['manualDeadline'] = 600
    empty = empty_lease(current)
    empty.pop('manualDeadline', None)
    before = f.ok('snapshot')
    prepared = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)
    old_proof = prepared['workSessionPreparation']
    f.patch(systemSleeping=True, manualClock=101)
    sleeping = f.ok('markDiagnostic')
    consumption = sleeping['workSessionBridge']['sleepConsumption']
    assert uuid.UUID(consumption['sessionID']) == uuid.UUID(current['sessionID']), sleeping
    assert consumption['sequence'] == 0 and consumption['observedAt'] == 101, sleeping
    assert sleeping.get('workSessionPreparation') is None and not sleeping['status']['ownsOverride'], sleeping
    f.patch(systemSleeping=False, manualClock=104)
    awake = f.ok('markDiagnostic')
    assert f.rpc('attachWorkSession', epoch=old_proof['epoch'], revision=old_proof['revision'],
                 workSession=current)['error'] == 'staleRevision'
    fresh = f.ok('prepareWorkSession', epoch=awake['epoch'], revision=awake['revision'], workSession=empty)
    proof = fresh['workSessionPreparation']
    mark = len(f.logs())
    unaware = current | dict(sequence=3)
    assert f.rpc('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'],
                 workSession=unaware)['error'] == 'invalidWorkLease'
    assert not f.ok('snapshot')['status']['ownsOverride'] and 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    acknowledged = empty | dict(sequence=4, sleepConsumptionID=consumption['id'])
    resumed = attach_work(f, acknowledged)
    assert not resumed['status']['ownsOverride'] and resumed['status']['workSession']['reasons'] == [], resumed
    passed('sleep consumes current preparation before an old saved lease after helper restart; unaware manual cannot revive')


# An OS sleep message consumes the finite decision even when ordinary wake facts
# still say Full Wake. A quick wake must not reuse a queued frame or cached ACK.
for power, reasons in [('ac', ['manual']), ('ac', ['automatic']),
                       ('battery', ['manual']), ('battery', ['automatic']),
                       ('battery', ['automatic', 'manual'])]:
    with Fixture(manualClock=100, power=power, lid='closed') as f:
        packet = lease(power=power, reasons=reasons, automaticEnabled='automatic' in reasons,
                       condition='any' if power == 'battery' else 'ac')
        if 'manual' in reasons:
            packet['manualDeadline'] = 600
        if power == 'battery' and 'automatic' in reasons:
            denied = attach_work(f, packet, expected_error='invalidWorkLease')
            assert not denied['status']['ownsOverride'] and not denied['status']['sleepDisabled'], denied
            empty = empty_lease(packet)
            empty.update(sequence=2, reasons=[], expiry=None, executionVersion=3)
            empty.pop('manualDeadline', None)
            empty['configuration']['condition'] = 'ac'
            upgraded = attach_work(f, empty)
            assert not upgraded['status']['ownsOverride'], upgraded
            f.patch(systemSleeping=True, manualClock=101)
            f.ok('markDiagnostic')
            f.patch(systemSleeping=False, power='ac', manualClock=104)
            awake = f.ok('markDiagnostic')
            assert not awake['status']['ownsOverride'], awake
            denied = f.rpc('syncWorkSession', workSession=packet | dict(sequence=3))
            assert denied['error'] == 'invalidWorkLease' and not denied['status']['ownsOverride'], denied
            passed('battery ' + '+'.join(reasons) + ' is rejected; empty upgrade and sleep/wake never revive retired authority')
            continue
        before = f.ok('snapshot')
        empty = empty_lease(packet)
        empty.pop('manualDeadline', None)
        prepared = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)
        proof = prepared['workSessionPreparation']
        attach_id = str(uuid.uuid4())
        attached = f.ok('attachWorkSession', id=attach_id, epoch=proof['epoch'], revision=proof['revision'], workSession=packet)
        assert attached['status']['ownsOverride'], attached
        queued = copy.deepcopy(packet); queued['sequence'] = 2
        sync_id = str(uuid.uuid4())
        before_sleep = f.ok('syncWorkSession', id=sync_id, workSession=queued)
        saved_control = before_sleep['control']
        retained = {key: before_sleep['workSessionBridge'].get(key)
                    for key in ['automaticBudget', 'manualBudget', 'stopRequested']}
        bound = json.loads((f.folder / 'helper-state.json').read_text())
        mark = len(f.logs())
        f.patch(systemSleeping=True, manualClock=101, fullWake=True)
        sleeping = f.ok('markDiagnostic')
        assert sleeping['revision'] > before_sleep['revision'], sleeping
        assert not sleeping['status']['ownsOverride'] and not sleeping['status']['sleepDisabled'], sleeping
        assert not sleeping['status']['manualSession']['active'], sleeping
        assert sleeping['status'].get('workSession') is None and sleeping.get('workSessionPreparation') is None, sleeping
        assert sleeping['workSessionBridge'].get('powerTransition') is None, sleeping
        consumption = sleeping['workSessionBridge']['sleepConsumption']
        assert uuid.UUID(consumption['sessionID']) == uuid.UUID(packet['sessionID']) and consumption['sequence'] == queued['sequence'], sleeping
        assert consumption['bootID'] == 'dry-run' and consumption['observedAt'] == 101, sleeping
        consumed = json.loads((f.folder / 'helper-state.json').read_text())
        assert consumed.get('workSessionLease') is None, consumed
        assert consumed['workSleepConsumption'] == consumption, consumed
        for key in ['appPID', 'appStarted', 'appUID', 'guiOwner', 'controllerUID']:
            assert consumed.get(key) == bound.get(key), (key, consumed, bound)
        assert sleeping['control'] == saved_control, sleeping
        for key, value in retained.items():
            assert sleeping['workSessionBridge'].get(key) == value, (key, sleeping)
        assert f.rpc('syncWorkSession', id=sync_id, workSession=queued)['error'] == 'sessionUnavailable'
        assert f.rpc('prepareWorkSession', epoch=sleeping['epoch'], revision=sleeping['revision'],
                     workSession=empty)['error'] == 'sessionUnavailable'

        f.patch(systemSleeping=False, manualClock=104, fullWake=True)
        awake = f.ok('markDiagnostic')
        assert not awake['status']['ownsOverride'] and awake['status'].get('workSession') is None, awake
        assert f.rpc('syncWorkSession', id=sync_id, workSession=queued)['error'] == 'invalidWorkLease'
        assert f.rpc('syncWorkSession', workSession=queued | dict(sequence=3))['error'] == 'invalidWorkLease'
        assert f.rpc('attachWorkSession', id=attach_id, epoch=proof['epoch'], revision=proof['revision'],
                     workSession=packet)['error'] == 'staleRevision'
        assert f.rpc('attachWorkSession', epoch=awake['epoch'], revision=awake['revision'],
                     workSession=queued)['error'] == 'invalidWorkLease'
        assert 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]

        # The GUI may not have handled Workspace willSleep yet and can generate a
        # higher sequence through a fresh epoch/revision handshake. Preparation
        # alone is not proof that its old temporary policy was consumed.
        prepared = f.ok('prepareWorkSession', epoch=awake['epoch'], revision=awake['revision'], workSession=empty)
        assert prepared['workSessionBridge']['sleepConsumption'] == consumption, prepared
        fresh_proof = prepared['workSessionPreparation']
        unaware = queued | dict(sequence=3)
        assert f.rpc('attachWorkSession', epoch=fresh_proof['epoch'], revision=fresh_proof['revision'],
                     workSession=unaware)['error'] == 'invalidWorkLease'
        unaware['sleepConsumptionID'] = str(uuid.uuid4())
        assert f.rpc('attachWorkSession', epoch=fresh_proof['epoch'], revision=fresh_proof['revision'],
                     workSession=unaware)['error'] == 'invalidWorkLease'
        old_frame = queued | dict(sleepConsumptionID=consumption['id'])
        assert f.rpc('attachWorkSession', epoch=fresh_proof['epoch'], revision=fresh_proof['revision'],
                     workSession=old_frame)['error'] == 'invalidWorkLease'
        assert not f.ok('snapshot')['status']['ownsOverride'], f.logs()[mark:]

        # A current AC decision resumes only the saved automatic trigger. Manual-
        # only settings stay off; the handshake never invents an automatic choice.
        f.patch(power='ac', manualClock=105)
        automatic = 'automatic' in reasons
        current = lease(sequence=4, session=packet['sessionID'], expiry=135 if automatic else None,
                        reasons=['automatic'] if automatic else [], automaticEnabled=automatic,
                        condition=packet['configuration']['condition'])
        current['sleepConsumptionID'] = consumption['id']
        resumed = attach_work(f, current)
        assert resumed['status']['ownsOverride'] == automatic and not resumed['status']['manualSession']['active'], resumed
        assert resumed['status']['workSession']['reasons'] == current['reasons'], resumed
        assert resumed['control']['enabled'] == automatic, resumed
        for key in ['automaticBudget', 'manualBudget']:
            assert resumed['workSessionBridge'].get(key) == retained[key], (key, resumed)
        passed('system sleep consumes ' + power + '/' + '+'.join(reasons)
               + '; quick wake and delayed/cached IPC cannot revive work, fresh AC handshake preserves budgets')

with Fixture(manualClock=100, lid='closed') as f:
    packet = lease(reasons=['manual'], automaticEnabled=False)
    packet['manualDeadline'] = 600
    attach_work(f, packet)
    f.patch(systemSleeping=True, manualClock=101)
    consumption = f.ok('markDiagnostic')['workSessionBridge']['sleepConsumption']
    f.patch(systemSleeping=False, manualClock=104)
    f.ok('markDiagnostic')
    f.stop(); f.start()
    restarted = f.ok('snapshot')
    assert restarted['workSessionBridge']['sleepConsumption'] == consumption, restarted
    assert restarted['status'].get('workSession') is None and not restarted['status']['ownsOverride'], restarted
    empty = empty_lease(packet, sequence=2)
    empty.pop('manualDeadline', None)
    prepared = f.ok('prepareWorkSession', epoch=restarted['epoch'], revision=restarted['revision'], workSession=empty)
    proof = prepared['workSessionPreparation']
    assert f.rpc('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'],
                 workSession=packet | dict(sequence=3))['error'] == 'invalidWorkLease'
    empty['sequence'] = 3; empty['sleepConsumptionID'] = consumption['id']
    accepted = attach_work(f, empty)
    assert not accepted['status']['ownsOverride'] and accepted['status']['workSession']['reasons'] == [], accepted
    passed('same-boot OS consumption survives helper restart; fresh preparation cannot restore unacknowledged old manual intent')

for wake in [False, None]:
    with Fixture(manualClock=100) as f:
        packet = lease()
        before = f.ok('snapshot')
        empty = empty_lease(packet)
        f.patch(fullWake=wake)
        denied = f.rpc('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)
        assert denied['error'] == 'sessionUnavailable' and denied.get('workSessionPreparation') is None, denied
        passed('non-full or unavailable wake observation cannot issue fresh work preparation: ' + str(wake))

with Fixture(manualClock=100, control={'enabled': False}) as f:
    packet = lease()
    before = f.ok('snapshot')
    empty = empty_lease(packet)
    prepared = f.ok('prepareWorkSession', epoch=before['epoch'], revision=before['revision'], workSession=empty)
    proof = prepared['workSessionPreparation']
    f.patch(systemSleeping=True, manualClock=101)
    sleeping = f.ok('markDiagnostic')
    assert sleeping.get('workSessionPreparation') is None and sleeping['revision'] > proof['revision'], sleeping
    f.patch(systemSleeping=False, manualClock=104)
    f.ok('markDiagnostic')
    assert f.rpc('attachWorkSession', epoch=proof['epoch'], revision=proof['revision'], workSession=packet)['error'] == 'staleRevision'
    assert not f.ok('snapshot')['status']['ownsOverride']
    passed('sleep consumes preparation-only evidence before any work grant has been attached')

for block in ['stop', 'thermal']:
    with Fixture(manualClock=100) as f:
        packet = lease(); attach_work(f, packet)
        if block == 'stop':
            halted = f.ok('stop')
        else:
            f.patch(thermal=2)
            halted = f.ok('markDiagnostic')
        retained_control = halted['control']
        retained_protection = halted['protection'].get('blockReason')
        retained_stop = halted['workSessionBridge']['stopRequested']
        f.patch(systemSleeping=True, manualClock=101)
        f.ok('markDiagnostic')
        f.patch(systemSleeping=False, manualClock=104, thermal=0)
        awake = f.ok('markDiagnostic')
        assert awake['control'] == retained_control and not awake['status']['ownsOverride'], awake
        assert awake['protection'].get('blockReason') == retained_protection, awake
        assert awake['workSessionBridge']['stopRequested'] == retained_stop, awake
        passed('sleep and quick wake preserve the existing ' + block + ' latch and saved trigger choice')


with Fixture(manualClock=100, lid='closed') as f:
    packet = lease(execution=None)
    token = str(uuid.uuid4())
    packet['continuationToken'] = token
    packet['powerTransition'] = dict(token=token, issuedAt=100, power='battery', expiry=130,
        reasons=['automatic'], batteryDeadline=280, automaticBudgetStart=100)
    reject_legacy_then_upgrade(f, packet)
    f.patch(power='battery', manualClock=101)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
    assert r['workSessionBridge']['automaticBudget'].get('batteryBudgetStart') is None, r
    passed('retired transition tokens are rejected; empty upgrade never creates battery automatic work or a transition receipt')


with Fixture(control={'enabled': False}, manualClock=100, lid='closed') as f:
    packet = lease(reasons=['manual'], automaticEnabled=False)
    packet['manualDeadline'] = 600
    attach_work(f, packet)
    mark = len(f.logs())
    f.patch(power='battery', manualClock=101)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('manualBudget') is None, r
    assert r['workSessionBridge'].get('powerTransition') is None, r
    assert 'IOPMSleepSystem' in f.logs()[mark:], f.logs()[mark:]
    passed('helper-first unplug ends the default AC manual reason without a battery grant or allowance consumption')

with Fixture(control={'enabled': False}, manualClock=100, lid='closed') as f:
    packet = lease(execution=None, reasons=['manual'], automaticEnabled=False)
    packet['manualDeadline'] = 600
    packet['powerTransition'] = dict(token=str(uuid.uuid4()), issuedAt=100, power='battery', expiry=130,
                                   reasons=['manual'], manualDeadline=600, manualBudgetStart=100)
    r = attach_work(f, packet, expected_error='invalidWorkLease')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('manualBudget') is None, r
    passed('a malformed legacy manual projection lacking an explicit choice is rejected before execution')

with Fixture(manualClock=100, lid='closed') as f:
    packet = lease(execution=None, reasons=['manual'], automaticEnabled=False, manualBatteryContinuationMinutes=15)
    packet['manualDeadline'] = 600
    packet['powerTransition'] = dict(token=str(uuid.uuid4()), issuedAt=100, power='battery', expiry=130,
                                   reasons=['manual'], manualDeadline=600, manualBudgetStart=100)
    reject_legacy_then_upgrade(f, packet)
    f.patch(power='battery', manualClock=101)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('manualBudget') is None, r
    assert r['workSessionBridge'].get('powerTransition') is None, r
    f.patch(power='ac', manualClock=102)
    assert not f.ok('markDiagnostic')['status']['ownsOverride']
    f.stop(); f.start()
    restarted = f.ok('snapshot')
    assert not restarted['status']['ownsOverride'] and restarted['status'].get('workSession') is None, restarted
    retired = copy.deepcopy(packet); retired['sequence'] = 3
    denied = attach_work(f, retired, expected_error='unsupportedVersion')
    assert not denied['status']['ownsOverride'] and not denied['status']['sleepDisabled'], denied
    passed('a legacy manual continuation cannot revive before its old expiry through empty upgrade, cable changes or restart preparation')

with Fixture(manualClock=100, power='battery', lid='closed') as f:
    packet = lease(power='battery', reasons=['manual'], automaticEnabled=False)
    packet['manualDeadline'] = 600; packet['manualStartedOnBattery'] = True
    attach_work(f, packet)
    f.patch(power='ac', manualClock=101)
    ac = copy.deepcopy(packet); ac.update(sequence=2, power='ac', expiry=131)
    ac['lidPermit'] = dict(powerScopes=['ac'], disconnectAction='sleepIfClosed', protectiveAction='sleepIfClosed')
    f.ok('syncWorkSession', workSession=ac)
    mark = len(f.logs())
    f.patch(power='battery', manualClock=102)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and not r['status']['sleepDisabled'], r
    assert r['workSessionBridge']['batteryPermitReceipts'][0]['observedAt'] == 100, r
    assert r['workSessionBridge'].get('powerTransition') is None, r
    assert 'disablesleep 0' in f.logs()[mark:] and 'IOPMSleepSystem' in f.logs()[mark:], f.logs()[mark:]
    passed('a battery-origin manual request preserves its old budget on AC but the next unplug consumes its authority')

for reasons in [['automatic'], ['automatic', 'manual']]:
    with Fixture(manualClock=100, lid='closed') as f:
        packet = lease(execution=None, reasons=reasons, condition='any')
        if 'manual' in reasons:
            packet['manualDeadline'] = 600
            packet['configuration']['manualBatteryContinuationMinutes'] = 15
        packet['powerTransition'] = dict(token=str(uuid.uuid4()), issuedAt=100, power='battery', expiry=130,
            reasons=reasons, batteryDeadline=280, automaticBudgetStart=100,
            **(dict(manualDeadline=600, manualBudgetStart=100) if 'manual' in reasons else {}))
        reject_legacy_then_upgrade(f, packet)
        f.patch(power='battery', manualClock=103)
        r = f.ok('markDiagnostic')
        assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
        assert r['workSessionBridge']['automaticBudget'].get('batteryBudgetStart') is None, r
        f.patch(power='ac', manualClock=110)
        assert not f.ok('markDiagnostic')['status']['ownsOverride']
        passed('legacy any-power ' + '+'.join(reasons) + ' is rejected and an empty upgrade never revives its old grant')

with Fixture(manualClock=100, power='battery', lid='closed') as f:
    packet = lease(execution=None, power='battery', reasons=['manual'], automaticEnabled=False)
    packet['manualDeadline'] = 7300
    packet['powerTransition'] = dict(token=str(uuid.uuid4()), issuedAt=100, power='ac', expiry=130, reasons=['manual'])
    reject_legacy_then_upgrade(f, packet)
    f.patch(power='ac', manualClock=101)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
    current_ac = lease(sequence=3, session=packet['sessionID'], reasons=['manual'], expiry=131, automaticEnabled=False)
    current_ac['manualDeadline'] = 7300
    r = f.ok('syncWorkSession', workSession=current_ac)
    assert r['status']['ownsOverride'] and r['status']['workSession']['manualDeadline'] == 7300, r
    passed('legacy battery-to-AC projection is rejected; only a new supported current-AC decision grants work')

with Fixture(manualClock=100, power='battery', lid='closed') as f:
    packet = lease(power='battery', reasons=['automatic', 'manual'], condition='any')
    packet['manualDeadline'] = 600
    packet['powerTransition'] = dict(token=str(uuid.uuid4()), issuedAt=100, power='ac', expiry=130,
        reasons=['automatic', 'manual'], manualDeadline=600, batteryDeadline=110,
        manualBudgetStart=100, automaticBudgetStart=100)
    denied = attach_work(f, packet, expected_error='invalidWorkLease')
    assert not denied['status']['ownsOverride'], denied
    empty = empty_lease(packet)
    empty.update(sequence=2, reasons=[], expiry=None, executionVersion=3)
    empty.pop('manualDeadline', None); empty.pop('powerTransition', None)
    empty['configuration']['condition'] = 'ac'
    upgraded = attach_work(f, empty)
    assert not upgraded['status']['ownsOverride'], upgraded
    f.patch(power='ac', manualClock=111)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
    assert r['workSessionBridge']['automaticBudget'].get('batteryBudgetStart') is None, r
    passed('rejected battery automatic work has no surviving AC reason after an empty upgrade and AC return')

with Fixture(manualClock=100, lid='closed', external=True, nativeDisplayVerified=True) as f:
    packet = lease(execution=None, reasons=['manual'], automaticEnabled=False, manualBatteryContinuationMinutes=15)
    packet['manualDeadline'] = 600
    packet['powerTransition'] = dict(token=str(uuid.uuid4()), issuedAt=100, power='battery', expiry=130,
        reasons=['manual'], manualDeadline=600, manualBudgetStart=100)
    reject_legacy_then_upgrade(f, packet)
    mark = len(f.logs())
    f.patch(power='battery', manualClock=101)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
    assert 'disablesleep 1' not in f.logs()[mark:], f.logs()[mark:]
    passed('a rejected opposite-power legacy grant cannot acquire an override after native-display delegation')

with Fixture(manualClock=100, lid='closed') as f:
    attach_work(f, lease())
    f.patch(power='battery', manualClock=101)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
    passed('AC-only work without an approved continuation releases immediately on unplug')

for unsafe in [dict(power='unknown'), dict(fullWake=None), dict(battery=None), dict(battery=29), dict(thermal=2)]:
    with Fixture(manualClock=100, lid='closed') as f:
        packet = lease(reasons=['manual'], automaticEnabled=False)
        packet['manualDeadline'] = 600
        attach_work(f, packet)
        f.patch(**(dict(power='battery', manualClock=101) | unsafe))
        r = f.ok('markDiagnostic')
        assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
    passed('current work never bridges unavailable power/wake/charge or unsafe charge/thermal facts: ' + str(unsafe))

with Fixture(manualClock=100, lid='closed') as f:
    packet = lease(reasons=['manual'], automaticEnabled=False, expiry=125)
    packet['manualDeadline'] = 125
    attach_work(f, packet)
    f.patch(power='battery', manualClock=101)
    assert not f.ok('markDiagnostic')['status']['ownsOverride']
    f.patch(manualClock=125)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'], r
    f.patch(power='ac', manualClock=126)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'], r
    passed('unplug consumes the current manual grant before its deadline; expiry and AC return never renew it')

with Fixture(manualClock=100, lid='closed') as f:
    packet = lease(execution=None, reasons=['manual'], automaticEnabled=False, manualBatteryContinuationMinutes=15)
    packet['manualDeadline'] = 600
    packet['powerTransition'] = dict(token=str(uuid.uuid4()), issuedAt=100, power='battery', expiry=130,
        reasons=['manual'], manualDeadline=600, manualBudgetStart=100)
    reject_legacy_then_upgrade(f, packet)
    f.ok('stop')
    denied = f.rpc('syncWorkSession', workSession=packet | dict(sequence=3))
    assert denied['error'] == 'unsupportedVersion' and not denied['status']['ownsOverride'], denied
    empty = empty_lease(packet, sequence=3)
    empty['executionVersion'] = 3; empty['configuration']['enabled'] = False
    r = f.ok('syncWorkSession', workSession=empty)
    assert not r['status']['ownsOverride'] and r['workSessionBridge'].get('powerTransition') is None, r
    passed('explicit stop and its empty acknowledgement never admit a retired transition grant')


with Fixture(manualClock=100, lid='closed') as f:
    packet = lease()
    before = f.ok('snapshot')
    assert before['status']['workSessionCoordinatorVersion'] == 8
    r = attach_work(f, packet)
    assert r['workSessionBridge']['coordinated'] and r['status']['ownsOverride'], r
    mark = len(f.logs())
    packet['sequence'] += 1
    f.patch(manualClock=101)
    r = f.ok('syncWorkSession', workSession=packet)
    assert r['status']['ownsOverride'], r
    assert 'disablesleep 0' not in f.logs()[mark:], f.logs()[mark:]
    passed('authenticated attached app negotiates common mode without releasing a valid closed AC hold')
    for changed in [dict(sequence=1), dict(sessionID=str(uuid.uuid4())), dict(expiry=999)]:
        invalid = packet | changed
        assert f.rpc('syncWorkSession', workSession=invalid)['error'] == 'invalidWorkLease'
    assert f.ok('snapshot')['status']['workSession']['sequence'] == 2
    passed('replayed sequence, wrong session and unbounded deadline cannot replace the last grant')
    f.patch(manualClock=129)
    assert f.ok('markDiagnostic')['status']['ownsOverride']
    f.patch(manualClock=130)
    r = f.ok('markDiagnostic')
    assert not r['status']['ownsOverride'], r
    passed('the 30-second lease boundary removes root-owned lid support while the attached controller process is still alive')

with Fixture(manualClock=100, sleepDisabled=True) as f:
    packet = lease()
    r = attach_work(f, packet)
    assert not r['status']['ownsOverride'] and r['status']['sleepDisabled'], r
    assert r['protection']['blockReason'] == 'powerConflict', r
    assert 'disablesleep 0' not in f.logs(), f.logs()
    passed('a pre-existing foreign override is never claimed or cleared by common-session attachment')

with Fixture(manualClock=100, lid='closed') as f:
    packet = lease()
    attach_work(f, packet)
    f.patch(thermal=2, manualClock=101)
    packet['sequence'] = 2
    r = f.ok('syncWorkSession', workSession=packet)
    assert not r['status']['ownsOverride'] and r['protection']['blockReason'] == 'thermal', r
    f.patch(thermal=0, manualClock=102)
    packet['sequence'] = 3
    r = f.rpc('syncWorkSession', workSession=packet)
    assert r['error'] == 'lidLeaseRevoked', r
    assert not r['status']['ownsOverride'] and r['protection']['blockReason'] == 'thermal', r
    passed('serious thermal protection releases own lid support and renewed app requests cannot silently clear it')

with Fixture(manualClock=100) as f:
    packet = lease(reasons=['automatic', 'manual'])
    attach_work(f, packet)
    packet['sequence'] = 2; packet['reasons'] = ['automatic']
    r = f.ok('syncWorkSession', workSession=packet)
    assert r['status']['ownsOverride'] and not r['status']['manualSession']['active'], r
    packet = empty_lease(packet, sequence=3)
    r = f.ok('syncWorkSession', workSession=packet)
    assert not r['status']['ownsOverride'], r
    assert f.rpc('startManualSession')['error'] == 'coordinatorRequired'
    assert f.rpc('startHold', minutes=30)['error'] == 'coordinatorRequired'
    passed('manual reason removal preserves automatic support; an empty lease releases and legacy activation cannot create a second policy')

with Fixture(manualClock=100, power='battery') as f:
    packet = lease(power='battery', expiry=130, reasons=['manual'], automaticEnabled=False)
    packet['manualDeadline'] = 7300
    r = attach_work(f, packet)
    assert r['status']['ownsOverride'] and not r['control']['enabled'], r
    budget = r['workSessionBridge']['batteryPermitReceipt']
    assert budget['observedAt'] == 100 and budget['maximumDeadline'] == 7300, budget
    f.patch(manualClock=200)
    packet['sequence'] = 2; packet['expiry'] = 230
    r = f.ok('syncWorkSession', workSession=packet)
    assert r['workSessionBridge']['batteryPermitReceipts'][0]['observedAt'] == 100, r
    f.patch(manualClock=7300)
    packet['sequence'] = 3; packet['expiry'] = 7330; packet['manualDeadline'] = 15000
    r = f.rpc('syncWorkSession', workSession=packet)
    assert r['error'] == 'batteryPermitExpired' and not r['status']['ownsOverride'], r
    assert r['workSessionBridge']['batteryPermitReceipts'][0]['observedAt'] == 100, r
    passed('helper retains the original fixed 2-hour permit ceiling and rejects a deadline increase after that permit expires')

with Fixture(manualClock=100, power='battery') as f:
    packet = lease(execution=None, power='battery', condition='battery', automaticMinutes=120)
    reject_legacy_then_upgrade(f, packet, expected_error='invalidWorkLease')
    f.stop(); f.start()
    r = f.ok('snapshot')
    assert not r['status']['ownsOverride'] and r['status'].get('workSession') is None, r
    f.patch(manualClock=101)
    retired = copy.deepcopy(packet); retired['sequence'] = 3; retired['expiry'] = 131
    r = attach_work(f, retired, expected_error='invalidWorkLease')
    assert not r['status']['ownsOverride'], r
    assert r['workSessionBridge']['automaticBudget'].get('batteryBudgetStart') is None, r
    passed('legacy battery automatic remains rejected after an empty upgrade and helper restart, without a shared budget')

with Fixture(manualClock=100) as f:
    packet = lease()
    attach_work(f, packet)
    r = f.ok('stop')
    assert r['workSessionBridge']['stopRequested'] and not r['status']['ownsOverride'], r
    packet['sequence'] = 2
    assert f.rpc('syncWorkSession', workSession=packet)['error'] == 'coordinatorRequired'
    packet = empty_lease(packet, sequence=3)
    packet['configuration']['enabled'] = False
    r = f.ok('syncWorkSession', workSession=packet)
    assert not r['workSessionBridge']['stopRequested'] and not r['status']['ownsOverride'], r
    passed('external stop rejects in-flight renewal until the app acknowledges an empty disabled session')

with Fixture(manualClock=100) as f:
    packet = lease(); attach_work(f, packet)
    f.ok('detachApp'); f.stop(); f.start()
    r = f.ok('snapshot')
    assert r['workSessionBridge']['coordinated'] and not r['status']['ownsOverride'], r
    assert f.rpc('attachApp')['error'] == 'coordinatorRequired'
    fresh = lease(automaticEnabled=False, reasons=[], expiry=None)
    r = attach_work(f, fresh)
    assert r['status']['appConnected'] and not r['status']['ownsOverride'], r
    passed('restart retains coordinated mode but never restores a temporary lease or silently returns to the legacy trigger')

print(json.dumps({'passed': count, 'failed': 0, 'scope': 'real isolated helper and IPC, dry-run OS writes',
                  'physical_behavior_proven': False, 'native_root_execution_proven': False}), flush=True)
