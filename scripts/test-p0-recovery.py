#!/usr/bin/env python3
"""P0 end/recovery interleavings: private helper IPC, dry-run power writes only."""
import copy
import os
import uuid

assert os.environ.get("TETHER_TEST_HELPER"), "Pass the freshly built private helper explicitly"
from service_fixture import Fixture


def lease():
    return dict(version=1, executionVersion=3, sessionID=str(uuid.uuid4()), sequence=1,
                power="ac", expiry=115, reasons=["automatic"],
                configuration=dict(enabled=True, automaticEnabled=True, condition="ac", automaticMinutes=60),
                lidPermit=dict(powerScopes=["ac"], disconnectAction="sleepIfClosed", protectiveAction="sleepIfClosed"))


def attach(f, value=None):
    value = value or lease()
    empty = copy.deepcopy(value); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
    before = f.ok("snapshot")
    prepared = f.ok("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
    result = f.ok("attachWorkSession", workSession=value, epoch=prepared["epoch"], revision=prepared["revision"])
    assert result["status"]["ownsOverride"], result
    return value


def step(f, **values):
    f.patch(**values)
    return f.rpc("markDiagnostic")


def sleeps(f):
    return f.logs().count("IOPMSleepSystem [v3")


def receipt(result):
    return result["workSessionBridge"]["lidEndReceipt"]


for elapsed, expected in [(49, 1), (59.999, 1), (60, 0), (75, 0)]:
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
        attach(f)
        pending = step(f, power="battery", manualClock=101, commandFailure=True)
        assert pending["status"].get("workSession") is None, pending
        assert receipt(pending)["phase"] == "captured" and sleeps(f) == 0, pending
        result = step(f, manualClock=101 + elapsed, commandFailure=False)
        assert not result["status"]["ownsOverride"] and sleeps(f) == expected, result
        end = receipt(result)
        assert end["id"] == receipt(pending)["id"] and end["cleanupDeadline"] == 161, end
        if expected:
            assert end["actionIssuedAt"] == 101 + elapsed and end["actionDeadline"] == 116 + elapsed, end
            assert end["phase"] == "consumed" and end["outcome"] == "commandAccepted", end
        else:
            assert end["outcome"] == "endAuthorityExpired" and end.get("actionID") is None, end
        step(f, manualClock=200)
        assert sleeps(f) == expected
        print("PASS cleanup boundary / late recovery", elapsed, flush=True)


for injected in [dict(lid="open"), dict(power="ac"), dict(power="unknown"), dict(sleepDisabled=True), dict(fullWake=False)]:
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
        attach(f)
        result = step(f, power="battery", manualClock=101, dispatchSnapshot=injected)
        assert sleeps(f) == 0 and receipt(result)["phase"] == "consumed", result
        assert receipt(result)["outcome"] == "endActionCancelled", result
        step(f, manualClock=102, dispatchSnapshot={})
        assert sleeps(f) == 0, "A cancelled action must never replay when normal facts return"
        print("PASS dispatch rechecks", injected, flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    attach(f)
    step(f, power="battery", manualClock=101, commandFailure=True)
    step(f, power="ac", manualClock=102)
    ended = step(f, power="battery", manualClock=150, commandFailure=False)
    assert not ended["status"]["ownsOverride"] and sleeps(f) == 0, ended
    assert receipt(ended)["phase"] == "consumed", ended
    print("PASS confirmed power round trip permanently cancels old end action", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    attach(f)
    result = step(f, power="battery", manualClock=101, sleepFailure=True)
    assert sleeps(f) == 1 and receipt(result)["outcome"] == "commandRejected", result
    step(f, manualClock=102, sleepFailure=False)
    assert sleeps(f) == 1
    f.stop(); f.start()
    assert sleeps(f) == 1
    print("PASS rejected / restarted / late response cannot retry Sleep", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    attach(f)
    result = step(f, power="battery", manualClock=101, finalOwnerUnavailable=True)
    assert not result["status"]["ownsOverride"] and sleeps(f) == 0, result
    step(f, manualClock=102, finalOwnerUnavailable=False)
    assert sleeps(f) == 0
    print("PASS lost owner consumes effect authority while owned restoration continues", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="open") as f:
    attach(f)
    result = f.rpc("sleep")
    assert result["ok"] and sleeps(f) == 1, result
    assert receipt(result)["kind"] == "user", result
    print("PASS explicit user Sleep is not cancelled solely by an open lid", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    original = attach(f)
    pending = step(f, power="unknown", manualClock=105)
    assert pending["status"]["ownsOverride"] and sleeps(f) == 0, pending
    assert pending["status"]["workSession"]["expiry"] == original["expiry"], pending
    expired = step(f, manualClock=115)
    assert not expired["status"]["ownsOverride"] and expired["status"].get("workSession") is None, expired
    assert expired["workSessionBridge"]["lidProtection"]["reason"] == "powerObservationUnavailable", expired
    normal = step(f, power="ac", manualClock=116)
    assert not normal["status"]["ownsOverride"] and sleeps(f) == 0, normal
    print("PASS unknown preserves only original finite grant then consumes without inventing unplug", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    value = lease(); request_id = str(uuid.uuid4())
    value["configuration"].update(condition="any", disconnectPolicy="continueEligible", batteryTimeLimit="twoHours")
    value["automaticRequestID"] = request_id
    value["lidPermit"].update(powerScopes=["ac", "battery"], batteryPermitID=request_id,
                              batteryDuration=7200, batteryTimeLimit="twoHours")
    attach(f, value)
    first = step(f, power="battery", manualClock=101)
    assert first["status"]["ownsOverride"] and sleeps(f) == 0, first
    assert not first["workSessionBridge"].get("lidEndReceipt"), first
    fixed = first["workSessionBridge"]["batteryPermitReceipt"]
    assert fixed["observedAt"] == 101 and fixed["maximumDeadline"] == 7301, fixed
    step(f, power="ac", manualClock=102)
    again = step(f, power="battery", manualClock=103)
    assert again["status"]["ownsOverride"] and sleeps(f) == 0, again
    assert again["workSessionBridge"]["batteryPermitReceipt"] == fixed, again
    assert again["status"]["workSession"]["expiry"] == 115, again
    print("PASS first auto battery anchor precedes unplug decision and never resets on AC round trip", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    value = lease(); value["configuration"]["stopOnSeriousThermal"] = False
    attach(f, value)
    serious = step(f, thermal=2, manualClock=101)
    assert serious["status"]["ownsOverride"] and sleeps(f) == 0, serious
    critical = step(f, thermal=3, manualClock=102)
    assert not critical["status"]["ownsOverride"], critical
    assert critical["workSessionBridge"]["lidProtection"]["reason"] == "thermal", critical
    print("PASS optional serious threshold preserves work while critical always consumes it", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    value = lease(); value["configuration"]["stopOnLowPowerMode"] = True
    attach(f, value)
    stopped = step(f, lowPowerMode=True, manualClock=101)
    assert not stopped["status"]["ownsOverride"], stopped
    assert stopped["workSessionBridge"]["lidProtection"]["reason"] == "lowPowerMode", stopped
    print("PASS selected low power mode stops owned work on AC without waiting for GUI renewal", flush=True)


with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    value = lease(); value.pop("lidPermit")
    empty = copy.deepcopy(value); empty.update(reasons=[], expiry=None)
    before = f.ok("snapshot")
    prepared = f.ok("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
    attached = f.ok("attachWorkSession", workSession=value, epoch=prepared["epoch"], revision=prepared["revision"])
    assert attached["status"]["workSession"]["reasons"] == ["automatic"] and not attached["status"]["ownsOverride"], attached
    unavailable = step(f, lid=None, sleepDisabled=None, manualClock=101)
    assert unavailable["status"]["workSession"]["sessionID"] == attached["status"]["workSession"]["sessionID"], unavailable
    assert not unavailable["workSessionBridge"].get("lidProtection") and sleeps(f) == 0, unavailable
    print("PASS lid-only unknown does not consume unrelated general-only finite work", flush=True)
