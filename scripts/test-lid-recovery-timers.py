#!/usr/bin/env python3
"""Real helper timers with private IPC and dry-run power writes, never live pmset.

The two-second deadlines are helper wire injections, not GUI duration choices:
the GUI still requires at least 60 seconds for an explicit battery session.
"""
import copy
import ctypes
import hashlib
import json
import os
from pathlib import Path
import time
import uuid

assert os.environ.get("TETHER_TEST_HELPER"), "Pass the packaged helper explicitly; never build implicitly"
from service_fixture import Fixture


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
system.mach_continuous_time.restype = ctypes.c_uint64
info = Timebase()
assert system.mach_timebase_info(ctypes.byref(info)) == 0 and info.denom > 0


def clock():
    return system.mach_continuous_time() * info.numer / info.denom / 1e9


def attach(f, lease):
    empty = copy.deepcopy(lease)
    empty.update(reasons=[], expiry=None)
    for key in ["lidPermit", "manualDeadline", "manualRequestID", "manualBatteryMaximumDeadline",
                "manualStartedOnBattery"]:
        empty.pop(key, None)
    before = f.ok("snapshot")
    prepared = f.ok("prepareWorkSession", workSession=empty,
                    epoch=before["epoch"], revision=before["revision"])
    return f.ok("attachWorkSession", workSession=lease,
                epoch=prepared["epoch"], revision=prepared["revision"])


def packet(base, power="ac", manual_deadline=None, permit_deadline=None):
    lease = dict(version=1, executionVersion=3, sessionID=str(uuid.uuid4()), sequence=1,
                 power=power, expiry=base + 15, reasons=["automatic"],
                 configuration=dict(enabled=True, automaticEnabled=True, condition="ac", automaticMinutes=60),
                 lidPermit=dict(powerScopes=[power], disconnectAction="sleepIfClosed", protectiveAction="sleepIfClosed"))
    if power == "battery":
        assert manual_deadline is not None and permit_deadline is not None
        request = str(uuid.uuid4())
        lease.update(reasons=["manual"], manualRequestID=request, manualStartedOnBattery=True,
                     manualDeadline=manual_deadline, manualBatteryMaximumDeadline=base + 7200)
        lease["configuration"]["automaticEnabled"] = False
        lease["lidPermit"].update(batteryPermitID=request, batteryDuration=7200,
                                 batteryDeadline=permit_deadline, batteryMaximumDeadline=base + 7200)
    return lease


def wait_released(f, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        # No RPC/notification is sent while waiting. The helper must publish
        # the restoration from its own timer, with an advancing real clock.
        status = json.loads(f.status.read_text())
        if not status["ownsOverride"] and not status["sleepDisabled"]:
            return status
        time.sleep(0.05)
    raise AssertionError(("autonomous timer did not restore", f.status.read_text(), f.logs()))


def completed(f, kind):
    state = json.loads((f.folder / "helper-state.json").read_text())
    receipt = state["lidEndReceipt"]
    assert receipt["kind"] == kind and receipt["phase"] == "consumed", receipt
    assert receipt["outcome"] == "commandAccepted", receipt
    assert state.get("workSessionLease") is None, state
    assert f.logs().count("IOPMSleepSystem [v3") == 1, f.logs()
    return receipt


helper = Path(os.environ["TETHER_TEST_HELPER"]).resolve()
print(json.dumps(dict(scope="packaged-helper-dry-run-real-timers", helper=str(helper),
                      helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest(),
                      shortDeadlineScope="helper-wire-injection-not-GUI-duration")), flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, power="battery", lid="closed",
             lowPowerWarning=False, manualClock=None) as f:
    base = clock()
    lease = packet(base, power="battery", manual_deadline=base + 2, permit_deadline=base + 20)
    assert attach(f, lease)["status"]["ownsOverride"]
    released = wait_released(f, timeout=5)
    observed = clock() - base
    assert 2 <= observed < 5, observed
    assert not released["manualSession"]["active"], released
    receipt = completed(f, "batteryExpired")
    print(json.dumps(dict(case="manual-only-on-battery-deadline", observedSeconds=observed,
                          sleepRequests=1, receiptID=receipt["id"], phase=receipt["phase"],
                          result="passedDryRunRealTimer")), flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, lid="closed", manualClock=None) as f:
    assert attach(f, packet(clock()))["status"]["ownsOverride"]
    f.patch(power="battery", commandFailure=True)
    r = f.rpc("markDiagnostic")
    assert r["error"] == "pmsetFailed" and r["status"]["ownsOverride"], r
    pending = r["workSessionBridge"]["lidEndReceipt"]
    assert pending["phase"] == "captured" and pending["outcome"] == "restoreUnverified", r
    initial = pending["observedAt"]
    f.patch(commandFailure=False)
    wait_released(f, timeout=8)
    observed = clock() - initial
    # Restore retries are anchored at incident +2/+5. Cleanup has a separate
    # 60-second deadline; successful cleanup mints one 15-second action.
    assert 2 <= observed < 5, observed
    assert observed < 60, "cleanup must finish within the original 60-second cause window"
    assert f.logs().count("command request: pmset -a disablesleep 0") == 2
    receipt = completed(f, "disconnect")
    assert receipt["id"] == pending["id"], receipt
    print(json.dumps(dict(case="transient-restore-real-timer", observedSeconds=observed,
                          restoreAttempts=2, sleepRequests=1, receiptID=receipt["id"], phase=receipt["phase"],
                          result="passedDryRunRealTimer")), flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, power="battery", lid="closed",
             lowPowerWarning=False, manualClock=None) as f:
    base = clock()
    lease = packet(base, power="battery", manual_deadline=base + 20, permit_deadline=base + 2)
    assert attach(f, lease)["status"]["ownsOverride"]
    wait_released(f, timeout=5)
    observed = clock() - base
    assert 2 <= observed < 5, observed
    receipt = completed(f, "batteryExpired")
    print(json.dumps(dict(case="battery-permit-deadline-real-timer", observedSeconds=observed,
                          sleepRequests=1, receiptID=receipt["id"], phase=receipt["phase"],
                          result="passedDryRunRealTimer")), flush=True)
