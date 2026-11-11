#!/usr/bin/env python3
"""Replay manual QA through a real helper, isolated sensors and dry-run OS writes.

Timers run at wall-clock speed. A dry-run sleep request is never physical sleep proof.
Each independent case retains requests, snapshots and helper logs, including failures.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import threading
import time
import traceback

from service_fixture import Fixture, BIN


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def host_baseline():
    support = Path('/Library/Application Support/Tether')
    result = {}
    for name in ['control.json']:
        p = support / name
        result[name] = hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None
    # The private root ownership journal is intentionally unreadable to this test.
    # Compare the helper's published ownership and applied state instead.
    status_path = support / 'status.json'
    if status_path.exists():
        status = json.loads(status_path.read_text())
        result['publishedState'] = {key: status.get(key) for key in
                                    ['build', 'power', 'lidClosed', 'sleepDisabled', 'ownsOverride', 'appConnected', 'appPID']}
    p = subprocess.run(['/usr/bin/pmset', '-g', 'custom'], capture_output=True, text=True, timeout=10)
    require(p.returncode == 0, 'Cannot capture live pmset baseline')
    result['pmsetCustom'] = p.stdout
    return result


class Case:
    def __init__(self, name, folder, helper, control=None, **sensors):
        self.name = name
        self.folder = folder / name
        self.folder.mkdir()
        self.started = time.time()
        self.checks = 0
        self.trace = (self.folder / 'trace.jsonl').open('w', buffering=1)
        self.f = None
        try:
            self.f = Fixture(helper_binary=helper, control={'debugLog': True, 'powerCondition': 'ac'} | (control or {}), **sensors)
            self.capture('ready', self.f.ok('snapshot'))
        except BaseException:
            self.trace.close()
            raise

    def capture(self, event, reply, inputs=None):
        require(reply['protection']['dryRun'] is True, 'Refuse non-dry-run helper')
        self.trace.write(json.dumps({'at': time.time(), 'elapsed': time.time() - self.started,
                                    'event': event, 'inputs': inputs, 'reply': reply}) + '\n')
        return reply

    def rpc(self, action, **values):
        return self.capture(action, self.f.rpc(action, **values), values)

    def ok(self, action, **values):
        r = self.rpc(action, **values)
        require(r['ok'], f'{action}: {r.get("error")}')
        return r

    def step(self, **values):
        return self.capture('sensors', self.f.step(**values), values)

    def config(self, **values):
        return self.capture('configure', self.f.config(**values), values)

    def check(self, condition, message):
        require(condition, message)
        self.checks += 1

    def hold(self, reply, expected):
        s = reply['status']
        self.check(s['sleepDisabled'] is expected and s['ownsOverride'] is expected,
                   f'Expected owned override={expected}: {s}')

    def wait(self, seconds, invariant=None):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            time.sleep(min(1, max(0, until - time.monotonic())))
            r = self.ok('snapshot')
            if invariant:
                invariant(r)
        return r

    def close_lid(self):
        self.step(lid='closed', displaySleeping=False)
        r = self.step(displaySleeping=True)
        self.check(r['protection'].get('blockReason') is None, 'Display acknowledgement rejected')
        return r

    def finish(self):
        if self.f:
            self.capture('final', self.f.ok('snapshot'))
            self.f.stop()
            for name in ['helper.log', 'control.json', 'helper-state.json', 'protection-state.json', 'usage.json', 'status.json']:
                p = self.f.folder / name
                if p.exists():
                    shutil.copyfile(p, self.folder / name)
            self.f.temp.cleanup()
        self.trace.close()


def s1(c):
    c.hold(c.ok('snapshot'), True)
    c.hold(c.step(power='battery'), False)
    c.wait(20, lambda r: c.hold(r, False))
    c.hold(c.step(power='ac'), True)
    c.wait(35, lambda r: c.hold(r, True))
    c.check('IOPMSleepSystem' not in c.f.logs(), 'Open-lid transition requested sleep')


def s2(c):
    c.close_lid()
    c.wait(60, lambda r: c.hold(r, True))
    mark = len(c.f.logs())
    c.hold(c.step(power='battery'), False)
    c.check('IOPMSleepSystem' in c.f.logs()[mark:], 'Closed unplug did not request sleep')
    c.step(systemSleeping=True, fullWake=False)
    c.wait(60, lambda r: c.hold(r, False))
    c.hold(c.step(lid='open', displaySleeping=False, systemSleeping=False, fullWake=True), False)


def s3(c):
    c.step(power='battery')
    r = c.ok('startHold', minutes=3)
    deadline = r['status']['batteryHoldUntil']
    c.check(178 < deadline - time.time() <= 181, '3-minute hold deadline is wrong')
    c.hold(c.close_lid(), True)
    c.wait(20, lambda r: c.hold(r, True))
    c.hold(c.step(power='ac', powerClock=200), True)
    mark = len(c.f.logs())
    r = c.wait(210, lambda r: c.hold(r, True))
    c.check(time.time() > deadline and r['status'].get('batteryHoldUntil') is None, 'Timer did not expire on AC')
    c.check(r['status'].get('lastHoldEnd') == 'time', 'Timer end reason not preserved')
    c.check('IOPMSleepSystem' not in c.f.logs()[mark:], 'Timer expiry on AC requested sleep')
    mark = len(c.f.logs())
    c.hold(c.step(power='battery'), False)
    c.check('IOPMSleepSystem' in c.f.logs()[mark:], 'Final closed unplug did not request sleep')
    c.step(systemSleeping=True, fullWake=False)
    c.wait(60, lambda r: c.hold(r, False))
    r = c.step(lid='open', displaySleeping=False, systemSleeping=False, fullWake=True)
    c.hold(r, False)
    c.check(r['status'].get('batteryHoldUntil') is None, 'Expired hold revived on wake')


def s4(c):
    c.step(power='battery')
    r = c.ok('startHold', minutes=1)
    c.check(58 < r['status']['batteryHoldUntil'] - time.time() <= 61, '1-minute hold deadline is wrong')
    c.close_lid()
    mark = len(c.f.logs())
    r = c.wait(90)
    c.hold(r, False)
    c.check(r['status'].get('lastHoldEnd') == 'time', 'Battery timer did not expire')
    c.check('IOPMSleepSystem' in c.f.logs()[mark:], 'Expiry did not request sleep')
    c.step(systemSleeping=True, fullWake=False)
    r = c.step(lid='open', displaySleeping=False, systemSleeping=False, fullWake=True)
    c.hold(r, False)
    c.check(r['status'].get('batteryHoldUntil') is None, 'Expired timer revived')


def s5(c):
    c.config(powerCondition='battery', automaticHoldMinutes=2)
    c.wait(20, lambda r: c.hold(r, False))
    r = c.step(power='battery')
    c.hold(r, True)
    c.check(118 < r['status']['batteryHoldUntil'] - time.time() <= 121, 'Automatic 2-minute hold did not start')
    c.wait(20, lambda r: c.hold(r, True))
    r = c.step(power='ac', powerClock=200)
    c.hold(r, False)
    c.check(r['status'].get('batteryHoldUntil') is None, 'Battery-only automatic timer survived AC return')
    c.wait(35, lambda r: c.hold(r, False))
    c.hold(c.config(powerCondition='ac'), True)
    c.check('IOPMSleepSystem' not in c.f.logs(), 'Open-lid condition change requested sleep')


def s6(c):
    c.ok('attachApp')
    c.ok('stop')
    c.step(power='battery')
    c.wait(20, lambda r: c.hold(r, False))
    c.step(power='ac')
    c.wait(20, lambda r: c.hold(r, False))
    c.check(c.ok('snapshot')['control']['enabled'] is False, 'Manual off lost on power return')
    c.ok('resume')
    c.ok('startHold', minutes=3)
    c.hold(c.ok('detachApp'), False)
    c.f.stop()
    c.f.start()
    c.hold(c.ok('snapshot'), False)
    r = c.ok('attachApp')
    c.hold(r, True)
    c.check(r['control']['enabled'] and r['control'].get('powerCondition', 'ac') == 'ac', 'Preference lost after reconnect')
    c.check(not r['control'].get('pendingHoldMinutes') and not r['status'].get('batteryHoldUntil'), 'Temporary reservation revived')


def display_loss(c, value):
    c.step(displayClock=0)
    c.close_lid()
    mark = len(c.f.logs())
    if value is None:
        r = c.step(displaySleeping=None, displayClock=100)
        c.hold(r, True)
        c.check(r['protection'].get('blockReason') is None, 'Transient missing observation stopped the hold')
        c.step(displaySleeping=True, displayClock=101)
        c.check('IOPMSleepSystem' not in c.f.logs()[mark:], 'Transient display query loss requested sleep')
        c.step(displaySleeping=None, displayClock=200)
        c.hold(c.step(displayClock=209), True)
        r = c.step(displayClock=210)
    else:
        for clock in [300, 310, 320, 330, 340]:
            r = c.step(displaySleeping=value, displayClock=clock)
    c.check(r['protection'].get('blockReason') is None, 'Screen failure latched system protection')
    c.hold(r, True)
    c.check(r['status']['displayRecovery']['phase'] == 'stopped', 'Screen recovery did not stop')
    c.check('IOPMSleepSystem' not in c.f.logs()[mark:], 'Screen failure requested system sleep')
    c.check(c.f.logs()[mark:].count('pmset displaysleepnow') <= 3, 'Display recovery exceeded request budget')
    mark = len(c.f.logs())
    c.config()
    c.check('displaysleepnow' not in c.f.logs()[mark:], 'Screen-off request repeated after conflict')
    r = c.step(displaySleeping=True)
    c.check(r['status']['displayRecovery']['phase'] == 'stopped', 'Stopped screen recovery silently restarted')
    c.hold(r, True)
    c.ok('startHold', minutes=3)
    c.check(c.ok('snapshot')['control'].get('pendingHoldMinutes') == 3, 'Screen failure rejected valid work reservation')
    c.step(lid='open', displaySleeping=False)
    c.step(power='battery')
    c.hold(c.ok('snapshot'), True)


def protection(c):
    # Build 49 uses public OS pressure. Optional Celsius readings are diagnostic only.
    c.step(power='battery', lid='open', temperature=None, thermal=1, battery=80)
    c.ok('startHold', minutes=3)
    c.hold(c.close_lid(), True)
    for temperature in [43, 90, None]:
        r = c.step(temperature=temperature)
        c.check(r['protection'].get('blockReason') is None, 'Optional Celsius reading blocked OS-fair hold')
        c.hold(r, True)

    for field, value, reason in [('thermal', 2, 'thermal'), ('thermal', 3, 'thermal'),
                                 ('battery', 30, 'battery'), ('battery', None, 'sensor'),
                                 ('thermal', -1, 'sensor')]:
        c.step(power='battery', lid='open', temperature=None, thermal=0, battery=80)
        c.ok('resume')
        c.ok('startHold', minutes=3)
        c.close_lid()
        mark = len(c.f.logs())
        r = c.step(**{field: value})
        c.check(r['protection'].get('blockReason') == reason, f'{reason} protection failed')
        c.hold(r, False)
        c.check('IOPMSleepSystem' in c.f.logs()[mark:], f'{reason} did not request closed-lid sleep')
        c.check(c.rpc('resume').get('error') == 'safetyBlocked', f'{reason} resumed under unsafe readings')


def darkwake(c, notifications):
    c.step(lid='closed', displaySleeping=True, systemSleeping=True, fullWake=False)
    for _ in range(8):
        if notifications:
            c.step(systemSleeping=False, fullWake=False)
        else:
            c.step(fullWake=False)
        c.step(systemSleeping=True, fullWake=False)
    usage = json.loads((c.f.folder / 'usage.json').read_text())
    count = usage['sleepLog']['open']['darkWakes']
    c.check(count == (8 if notifications else 0), f'Unexpected DarkWake count: {count}')
    write_json(c.folder / 'observation.json', {'injectedWakeNotifications': notifications, 'injectedCycles': 8,
               'recordedDarkWakes': count, 'limitation': 'Conditional reproduction only; actual IOKit notification delivery is not simulated by macOS.'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, default=BIN / 'TetherHelper')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    helper = args.helper.resolve(strict=True)
    args.out.mkdir(parents=True, exist_ok=False)
    baseline = host_baseline()
    write_json(args.out / 'host-before.json', baseline)
    cases = [('S1-open-power', s1, 'scenario'), ('S2-closed-unplug', s2, 'scenario'),
             ('S3-manual-3min-ac-return', s3, 'scenario'), ('S4-manual-1min-expiry', s4, 'scenario'),
             ('S5-battery-only', s5, 'scenario'), ('S6-off-reconnect', s6, 'scenario'),
             ('R1-display-unknown', lambda c: display_loss(c, None), 'reproduction'),
             ('R2-display-awake', lambda c: display_loss(c, False), 'reproduction'),
             ('P1-protection', protection, 'scenario'),
             ('R3-darkwake-with-notifications', lambda c: darkwake(c, True), 'reproduction'),
             ('R4-darkwake-without-notifications', lambda c: darkwake(c, False), 'reproduction')]
    started = time.time()
    lock = threading.Lock()

    def run(item):
        name, function, kind = item
        c = None
        result = {'name': name, 'kind': kind, 'startedAt': time.time(), 'passed': False}
        try:
            c = Case(name, args.out, helper)
            function(c)
            result['passed'] = True
        except BaseException:
            result['error'] = traceback.format_exc()
        finally:
            if c:
                try:
                    c.finish()
                except BaseException:
                    result['passed'] = False
                    result['cleanupError'] = traceback.format_exc()
                result['checks'] = c.checks
            result['durationSeconds'] = round(time.time() - result['startedAt'], 3)
            (args.out / name).mkdir(exist_ok=True)
            write_json(args.out / name / 'result.json', result)
            with lock:
                print(('PASS ' if result['passed'] else 'FAIL ') + name + ' ' + str(result['durationSeconds']) + 's', flush=True)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(cases)) as pool:
        results = list(pool.map(run, cases))
    after = host_baseline()
    write_json(args.out / 'host-after.json', after)
    summary = {'helper': str(helper), 'helperSHA256': hashlib.sha256(helper.read_bytes()).hexdigest(),
               'startedAt': started, 'durationSeconds': round(time.time() - started, 3),
               'realTimeTimers': True, 'physicalSleepProven': False, 'livePowerSettingsUnchanged': baseline == after,
               'passed': sum(r['passed'] for r in results), 'total': len(results), 'results': results}
    write_json(args.out / 'summary.json', summary)
    print(json.dumps({k: v for k, v in summary.items() if k != 'results'}, ensure_ascii=False), flush=True)
    raise SystemExit(0 if all(r['passed'] for r in results) and baseline == after else 1)


if __name__ == '__main__':
    main()
