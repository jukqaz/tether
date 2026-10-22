#!/usr/bin/env python3
"""Separate legacy screen recovery from v4 observation-only behavior; all OS writes are dry-run."""
import copy
import json
import os
from pathlib import Path
import uuid

from service_fixture import Fixture


evidence = []
passed = []
evidence_path = os.environ.get('TETHER_DISPLAY_TEST_EVIDENCE')


def record(fixture, label, reply):
    status = reply['status']
    evidence.append({'case': label, 'topology': status.get('displayTopology'),
                     'recovery': status.get('displayRecovery'),
                     'ownsOverride': status.get('ownsOverride'),
                     'sleepDisabled': status.get('sleepDisabled'),
                     'blockReason': reply.get('protection', {}).get('blockReason'),
                     'workSession': status.get('workSession'),
                     'displayRequests': fixture.logs().count('pmset displaysleepnow'),
                     'systemSleepRequested': 'IOPMSleepSystem' in fixture.logs()})
    if evidence_path:
        Path(evidence_path).write_text(json.dumps({'observations': evidence,
            'passed': passed, 'physicalBehaviorProven': False}, indent=2) + '\n')
    print(json.dumps(evidence[-1]), flush=True)


def attach_common(fixture, include_manual=False):
    before = fixture.ok('snapshot')
    power = fixture.readings['power']
    reasons = ['automatic'] if power == 'ac' else ['manual']
    if power == 'ac' and include_manual:
        reasons.append('manual')
    lease = {'version': 1, 'executionVersion': 3, 'sessionID': str(uuid.uuid4()), 'sequence': 1,
             # These cases isolate observation from the optional display writer.
             # Default-off execution is covered in test-work-session.py.
             'closedLidDisplayMode': 'unchanged',
             'power': power, 'expiry': 115, 'reasons': reasons,
             'configuration': {'enabled': True, 'automaticEnabled': 'automatic' in reasons,
                               'condition': 'ac', 'automaticMinutes': 60, 'limits': {'batteryFloor': 30}},
             'lidPermit': {'powerScopes': [power], 'disconnectAction': 'sleepIfClosed', 'protectiveAction': 'sleepIfClosed'}}
    if 'manual' in reasons:
        lease.update(manualDeadline=280, manualRequestID=str(uuid.uuid4()))
    if power == 'battery':
        lease.update(manualStartedOnBattery=True, manualBatteryMaximumDeadline=7300)
        lease['lidPermit'].update(batteryPermitID=lease['manualRequestID'], batteryDuration=180,
                                  batteryDeadline=280, batteryMaximumDeadline=7300)
    empty = copy.deepcopy(lease)
    empty['reasons'] = []
    empty['expiry'] = None
    for key in ['lidPermit', 'manualDeadline', 'manualRequestID', 'manualBatteryMaximumDeadline']:
        empty.pop(key, None)
    preparation = fixture.ok('prepareWorkSession', epoch=before['epoch'],
        revision=before['revision'], workSession=empty)['workSessionPreparation']
    fixture.ok('attachWorkSession', epoch=preparation['epoch'],
        revision=preparation['revision'], workSession=lease)
    return lease


def start_legacy_manual(fixture):
    # Legacy display-budget compatibility is intentionally not the v4 executor.
    # Its old startHold wire is retired; only an explicit finite manual is used.
    fixture.ok('attachApp')
    return fixture.ok('startManualSession', minutes=3)


def modern_fixture(**facts):
    return Fixture(control={'enabled': False}, legacy_state=False,
                   **(dict(manualClock=100, displayClock=0) | facts))


def work_is_unchanged(before, after):
    assert after['status']['ownsOverride'] and after['status']['sleepDisabled'], after
    assert not after['protection'].get('blockReason'), after
    assert after['status'].get('workSession') == before['status'].get('workSession'), after


def observe(fixture, **values):
    fixture.patch(**values)
    # The diagnostic command drives one evaluation without changing configuration;
    # unlike legacy configure, it is also accepted by the common coordinator.
    return fixture.ok('markDiagnostic')


def work_facts(fixture, reply):
    state_path = fixture.folder / 'helper-state.json'
    # An idle legacy AC helper need not persist an empty bookkeeping record.
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    protection = json.loads((fixture.folder / 'protection-state.json').read_text())
    return {'lease': reply['status'].get('workSession'),
            'deadline': reply['control'].get('batteryHoldUntil'),
            'holdStart': state.get('holdContinuousStart'),
            'holdDeadline': state.get('holdContinuousDeadline'),
            'manualBudget': state.get('manualBatteryBudget'),
            'permitReceipts': state.get('batteryPermitReceipts'),
            'manualActive': reply['status']['manualSession']['active'],
            'manualEndpointSeconds': round(reply['status']['manualSession']['until'] - reply['status']['updatedAt'])
                if reply['status']['manualSession'].get('until') is not None else None,
            'batteryBudget': protection.get('batteryBudgetStart'),
            'budgetBoot': protection.get('budgetBoot')}


for mode in ['legacy']:
    for topology in ['virtualOnly', 'externalWithVirtual']:
        for power in ['ac', 'battery']:
            with Fixture(power=power, lid='closed', displaySleeping=False,
                         displayClock=0, manualClock=100) as f:
                if power == 'battery':
                    start_legacy_manual(f)
                for clock in [0, 10, 20, 30]:
                    stopped = observe(f, displayClock=clock)
                assert stopped['status']['displayRecovery'] == {
                    'phase': 'stopped', 'requests': 3, 'maximumRequests': 3}, stopped
                original = work_facts(f, stopped)
                if power == 'battery':
                    # The finite manual is process-local, not a saved hold budget.
                    assert original['manualActive'] and original['manualEndpointSeconds'] == 180, original
                    assert original['batteryBudget'] is None, original
                record(f, mode + '/' + power + '/' + topology + '/exhausted', stopped)
                for clock in [31, 33, 35]:
                    connected = observe(f, displayTopology=topology, displayClock=clock)
                    returned = observe(f, displayTopology='none', displayClock=clock + 1)
                    for reply in [connected, returned]:
                        assert reply['status']['displayRecovery'] == stopped['status']['displayRecovery'], reply
                        work_is_unchanged(stopped, reply)
                        assert work_facts(f, reply) == original, reply
                    record(f, mode + '/' + power + '/' + topology + '/reconnected', returned)
                    assert f.logs().count('pmset displaysleepnow') == 3, f.logs()
                    assert 'IOPMSleepSystem' not in f.logs(), f.logs()
                # A real lid opening ends this incident; a remote connection does not.
                opened = observe(f, lid='open', displayClock=40)
                assert opened['status']['displayRecovery']['phase'] == 'inactive', opened
                closed = observe(f, lid='closed', displayClock=41)
                assert closed['status']['displayRecovery']['requests'] == 1, closed
                assert f.logs().count('pmset displaysleepnow') == 4, f.logs()
                assert work_facts(f, closed) == original, closed
                passed.append(mode + '/' + power + '/' + topology + ': reconnect preserves exhausted budget and work')
            assert f.helper.poll() is not None and not f.folder.exists()

        with Fixture(lid='closed', displaySleeping=False, displayClock=0, manualClock=100) as f:
            initial = observe(f, displayClock=0)
            original = work_facts(f, initial)
            assert initial['status']['displayRecovery']['requests'] == 1, initial
            for connected_clock, returned_clock, retry_clock, requests in [(1, 2, 10, 2), (11, 12, 20, 3)]:
                connected = observe(f, displayTopology=topology, displayClock=connected_clock)
                returned = observe(f, displayTopology='none', displayClock=returned_clock)
                assert returned['status']['displayRecovery']['requests'] == requests - 1, returned
                assert f.logs().count('pmset displaysleepnow') == requests - 1, f.logs()
                retry = observe(f, displayClock=retry_clock)
                assert retry['status']['displayRecovery']['requests'] == requests, retry
                for reply in [connected, returned, retry]:
                    work_is_unchanged(initial, reply)
                    assert work_facts(f, reply) == original, reply
            stopped = observe(f, displayClock=30)
            assert stopped['status']['displayRecovery']['phase'] == 'stopped', stopped
            assert f.logs().count('pmset displaysleepnow') == 3, f.logs()
            passed.append(mode + '/' + topology + ': reconnect preserves partial budget and original retry spacing')
        assert f.helper.poll() is not None and not f.folder.exists()


for mode in ['legacy']:
    with Fixture(lid='closed', displaySleeping=False, displayClock=0, manualClock=100) as f:
        observe(f, displayClock=0)
        for clock in [10, 20, 30]:
            stopped = observe(f, displayClock=clock)
        assert stopped['status']['displayRecovery'] == {
            'phase': 'stopped', 'requests': 3, 'maximumRequests': 3}, stopped
        record(f, mode + '/exhausted', stopped)
        for clock in [31, 33]:
            unknown = observe(f, displayTopology='unknown', displayClock=clock)
            record(f, mode + '/unknown-after-exhaustion', unknown)
            work_is_unchanged(stopped, unknown)
            recovered = observe(f, displayTopology='none', displayClock=clock + 1)
            record(f, mode + '/known-after-exhaustion', recovered)
            work_is_unchanged(stopped, recovered)
            assert unknown['status']['displayRecovery'] == stopped['status']['displayRecovery'], unknown
            assert recovered['status']['displayRecovery'] == stopped['status']['displayRecovery'], recovered
            assert f.logs().count('pmset displaysleepnow') == 3, f.logs()
            assert 'IOPMSleepSystem' not in f.logs(), f.logs()
        # A verified open lid is an actual end of the screen incident, unlike a failed query.
        opened = observe(f, lid='open', displayClock=40)
        assert opened['status']['displayRecovery']['phase'] == 'inactive', opened
        assert opened['status']['displayRecovery']['requests'] == 0, opened
        closed = observe(f, lid='closed', displayClock=41)
        record(f, mode + '/new-lid-incident', closed)
        assert closed['status']['displayRecovery']['requests'] == 1, closed
        assert f.logs().count('pmset displaysleepnow') == 4, f.logs()
        work_is_unchanged(stopped, closed)
        passed.append(mode + ': unknown topology cannot rearm exhausted recovery; an open lid can')

    with Fixture(lid='closed', displaySleeping=False, displayClock=0, manualClock=100) as f:
        observe(f, displayClock=0)
        initial = f.ok('snapshot')
        assert initial['status']['displayRecovery']['requests'] == 1, initial
        unknown = observe(f, displayTopology='unknown', displayClock=1)
        record(f, mode + '/unknown-after-first-request', unknown)
        work_is_unchanged(initial, unknown)
        assert unknown['status']['displayRecovery'] == initial['status']['displayRecovery'], unknown
        known = observe(f, displayTopology='none', displayClock=2)
        record(f, mode + '/known-with-partial-budget', known)
        assert known['status']['displayRecovery']['requests'] == 1, known
        assert f.logs().count('pmset displaysleepnow') == 1, f.logs()
        retry = observe(f, displayClock=10)
        assert retry['status']['displayRecovery']['requests'] == 2, retry
        assert f.logs().count('pmset displaysleepnow') == 2, f.logs()
        work_is_unchanged(initial, retry)
        passed.append(mode + ': unknown topology preserves the partial budget and retry spacing')

with Fixture(lid='closed', displayTopology='unknown', displaySleeping=False, displayClock=0) as f:
    unknown = f.ok('snapshot')
    record(f, 'initially-unknown', unknown)
    assert not unknown['status']['ownsOverride'] and 'pmset ' not in f.logs(), f.logs()
    known = observe(f, displayTopology='none', displayClock=1)
    known = observe(f, displayClock=1)
    record(f, 'initially-unknown-then-confirmed', known)
    assert known['status']['ownsOverride'], known
    assert known['status']['displayRecovery']['requests'] == 1, known
    passed.append('a first confirmed screen observation permits a fresh bounded incident')

for power in ['ac', 'battery']:
    for topology in ['virtualOnly', 'externalWithVirtual']:
        with modern_fixture(power=power, lid='closed', displaySleeping=False) as f:
            packet = attach_common(f, include_manual=True)
            initial = observe(f)
            original = work_facts(f, initial)
            assert original['lease']['executionVersion'] == 3 and original['lease']['expiry'] == 115, original
            if power == 'battery':
                assert original['lease']['reasons'] == ['manual'], original
                assert initial['workSessionBridge']['batteryPermitReceipt']['deadline'] == 280, initial
            for clock, observed_topology in [(0, 'none'), (10, 'none'), (20, topology), (30, 'none'),
                                             (31, 'unknown'), (33, topology), (35, 'none')]:
                result = observe(f, displayTopology=observed_topology, displayClock=clock)
                work_is_unchanged(initial, result)
                assert work_facts(f, result) == original, result
                assert result['status']['displayRecovery'] == {'phase': 'inactive', 'requests': 0, 'maximumRequests': 3}, result
                assert 'displaysleepnow' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
            opened = observe(f, lid='open', displayClock=40)
            closed = observe(f, lid='closed', displayClock=41)
            for result in [opened, closed]:
                work_is_unchanged(initial, result)
                assert work_facts(f, result) == original, result
                assert result['status']['displayRecovery']['requests'] == 0, result
            record(f, 'v4/' + power + '/' + topology + '/no-display-writer', closed)
            assert 'displaysleepnow' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
            passed.append('v4/' + power + '/' + topology + ': unknown/reconnect/lid cycles preserve the exact request and create zero display writes')
        assert f.helper.poll() is not None and not f.folder.exists()

    with modern_fixture(power=power, lid='closed', displayTopology='unknown', displaySleeping=None) as f:
        attach_common(f, include_manual=True)
        initial = observe(f)
        assert initial['status']['ownsOverride'], initial
        original = work_facts(f, initial)
        for topology, sleeping in [('none', False), ('unknown', None), ('virtualOnly', True), ('none', None)]:
            result = observe(f, displayTopology=topology, displaySleeping=sleeping)
            work_is_unchanged(initial, result)
            assert work_facts(f, result) == original, result
            assert result['status']['displayRecovery']['requests'] == 0, result
        record(f, 'v4/' + power + '/unknown-display-is-not-work-failure', result)
        expired = observe(f, manualClock=115, displayTopology='unknown', displaySleeping=None)
        assert not expired['status']['ownsOverride'] and not expired['status']['sleepDisabled'], expired
        assert 'displaysleepnow' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
        passed.append('v4/' + power + ': display read failures neither shorten nor renew work; the original health deadline restores only own state')
    assert f.helper.poll() is not None and not f.folder.exists()

for modern in [False, True]:
    mode = 'v4' if modern else 'legacy'
    for observation in [dict(foreignDisplayRequest=True), dict(displayRequestsUnavailable=True)]:
        factory = modern_fixture if modern else Fixture
        with factory(lid='closed', displaySleeping=False, displayClock=0, manualClock=100, **observation) as f:
            if modern:
                attach_common(f, include_manual=True)
            initial = observe(f)
            original = work_facts(f, initial)
            assert initial['status']['ownsOverride'] and 'displaysleepnow' not in f.logs(), initial
            assert initial['status']['displayRecovery']['phase'] == ('inactive' if modern else 'deferred'), initial
            for topology in ['unknown', 'virtualOnly', 'none']:
                result = observe(f, displayTopology=topology, displayClock=1)
                work_is_unchanged(initial, result)
                assert work_facts(f, result) == original, result
                assert 'displaysleepnow' not in f.logs(), f.logs()
            cleared = observe(f, foreignDisplayRequest=False, displayRequestsUnavailable=False, displayClock=10)
            work_is_unchanged(initial, cleared)
            assert work_facts(f, cleared) == original, cleared
            assert f.logs().count('pmset displaysleepnow') == (0 if modern else 1), f.logs()
            assert 'IOPMSleepSystem' not in f.logs(), f.logs()
            record(f, mode + '/foreign-or-unavailable-display-request', cleared)
            passed.append(mode + ': foreign display requests/query gaps defer only the legacy screen writer without changing work')
        assert f.helper.poll() is not None and not f.folder.exists()

    with (modern_fixture if modern else Fixture)(lid='closed', sleepDisabled=True,
                                                displaySleeping=False, manualClock=100) as f:
        if modern:
            attach_common(f)
        for topology in ['unknown', 'virtualOnly', 'none']:
            result = observe(f, displayTopology=topology)
            assert not result['status']['ownsOverride'] and result['status']['sleepDisabled'], result
        assert 'disablesleep 0' not in f.logs() and 'displaysleepnow' not in f.logs(), f.logs()
        assert 'IOPMSleepSystem' not in f.logs(), f.logs()
        record(f, mode + '/foreign-global-override-preserved', result)
        passed.append(mode + ': screen observations never adopt or restore a foreign global override')

for power in ['ac', 'battery']:
    with Fixture(control={'enabled': False}, power=power, lid='closed', manualClock=100) as f:
        f.ok('attachApp')
        before = f.ok('snapshot')
        denied = f.rpc('startHold', minutes=3)
        assert denied['error'] == 'unsupportedVersion' and denied['control'] == before['control'], denied
        assert not denied['status']['ownsOverride'] and not denied['status']['sleepDisabled'], denied
        assert not denied['control'].get('batteryHoldUntil') and not denied['control'].get('pendingHoldMinutes'), denied
        assert 'displaysleepnow' not in f.logs() and 'IOPMSleepSystem' not in f.logs(), f.logs()
        passed.append('legacy/' + power + ': retired startHold is explicitly rejected without a timer, reservation or screen write')

if evidence_path:
    Path(evidence_path).write_text(json.dumps({'observations': evidence, 'passed': passed,
        'failed': 0, 'physicalBehaviorProven': False,
        'scope': 'real private helper and Unix IPC; mocked sensors and dry-run OS writes'}, indent=2) + '\n')
print(json.dumps({'passed': len(passed), 'failed': 0, 'physicalBehaviorProven': False}), flush=True)
