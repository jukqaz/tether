#!/usr/bin/env python3
"""v4 G1/G3: private IPC + injected clock; every power write is helper --dry-run."""
import copy
import os
import uuid

assert os.environ.get("TETHER_TEST_HELPER"), "Pass the private, freshly built TetherHelper explicitly"
from service_fixture import Fixture


def packet(power="ac", manual=False, deadline=700, sequence=1, session=None, request=None):
    request = request or str(uuid.uuid4())
    data = dict(version=1, executionVersion=3, sessionID=session or str(uuid.uuid4()), sequence=sequence,
                power=power, expiry=120, reasons=["manual"] if manual else ["automatic"],
                configuration=dict(enabled=True, automaticEnabled=not manual, condition="ac", automaticMinutes=60),
                lidPermit=dict(powerScopes=[power], disconnectAction="sleepIfClosed", protectiveAction="sleepIfClosed"))
    if manual:
        data.update(manualRequestID=request, manualDeadline=deadline, manualStartedOnBattery=power == "battery")
    if power == "battery":
        data["lidPermit"].update(batteryPermitID=request, batteryDuration=7200,
                                batteryDeadline=deadline, batteryMaximumDeadline=7300)
        data["manualBatteryMaximumDeadline"] = 7300
    return data


def empty(data, **values):
    result = copy.deepcopy(data)
    result.update(reasons=[], expiry=None)
    for key in ["manualDeadline", "manualRequestID", "manualExtensionID", "manualBatteryMaximumDeadline",
                "lidPermit", "extensionPreparation", "extensionRollbackID"]:
        result.pop(key, None)
    result.update(values)
    return result


def attach(fixture, data):
    before = fixture.ok("snapshot")
    prepared = fixture.ok("prepareWorkSession", epoch=before["epoch"], revision=before["revision"], workSession=empty(data))
    return fixture.ok("attachWorkSession", epoch=prepared["epoch"], revision=prepared["revision"], workSession=data)


def sleeps(fixture):
    return fixture.logs().count("IOPMSleepSystem [v3")


def step(fixture, **facts):
    fixture.patch(**facts)
    return fixture.rpc("markDiagnostic")


count = 0


def passed(name):
    global count
    count += 1
    print("PASS dry-run:", name, flush=True)


for lid in ["closed", "open"]:
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid=lid) as f:
        data = packet(manual=True)
        # An old dual-scope payload must not preserve AC-origin work after unplug.
        data["configuration"]["manualBatteryContinuationMinutes"] = 30
        data["lidPermit"].update(powerScopes=["ac", "battery"], batteryPermitID=data["manualRequestID"],
                                  batteryDuration=1800)
        assert attach(f, data)["status"]["ownsOverride"]
        ended = step(f, power="battery", manualClock=101)
        assert not ended["status"]["ownsOverride"] and not ended["status"]["manualSession"]["active"], ended
        assert sleeps(f) == (1 if lid == "closed" else 0), f.logs()
        receipt = ended["workSessionBridge"]["lidEndReceipt"]
        assert receipt["kind"] == "disconnect" and receipt["phase"] == "consumed", ended
        if lid == "closed":
            assert receipt["outcome"] == "commandAccepted" and receipt.get("observedSleepAt") is None, receipt
        again = step(f, power="ac", manualClock=102)
        assert not again["status"]["ownsOverride"] and not again["status"]["manualSession"]["active"], again
        assert sleeps(f) == (1 if lid == "closed" else 0)
        passed("every old request consumed on " + lid + " unplug; reconnect does not revive it")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    data = packet()
    assert attach(f, data)["status"]["ownsOverride"]
    f.patch(power="battery", manualClock=101)
    ended = f.ok("syncWorkSession", workSession=empty(data, sequence=2, power="battery", disconnectEndRequested=True))
    assert sleeps(f) == 1 and not ended["status"]["ownsOverride"], ended
    fresh = packet(power="battery", manual=True, sequence=3, session=data["sessionID"])
    fresh["endConsumptionID"] = ended["workSessionBridge"]["lidEndReceipt"]["id"]
    resumed = f.ok("syncWorkSession", workSession=fresh)
    assert resumed["status"]["ownsOverride"] and resumed["status"]["manualSession"]["active"], resumed
    assert sleeps(f) == 1
    passed("GUI-first unplug has one terminal action; a genuinely new battery manual is allowed")

for old_manual in [False, True]:
    with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
        data = packet(manual=old_manual)
        assert attach(f, data)["status"]["ownsOverride"]
        # No empty release or helper power event occurs before this new request.
        f.patch(power="battery", manualClock=101)
        fresh = packet(power="battery", manual=True, sequence=2, session=data["sessionID"])
        confirmed = f.ok("syncWorkSession", workSession=fresh)
        current = confirmed["status"]["workSession"]
        assert current["manualRequestID"].lower() == fresh["manualRequestID"].lower(), confirmed
        assert current["reasons"] == ["manual"] and confirmed["status"]["ownsOverride"], confirmed
        assert sleeps(f) == 0 and not confirmed["workSessionBridge"].get("lidEndReceipt"), confirmed
        stale = copy.deepcopy(data); stale["sequence"] = 3
        assert f.rpc("syncWorkSession", workSession=stale)["error"] == "invalidWorkLease"
        after = f.ok("snapshot")
        assert after["status"]["workSession"]["manualRequestID"].lower() == fresh["manualRequestID"].lower(), after
        assert sleeps(f) == 0, f.logs()
        passed("new battery manual overtakes old " + ("manual" if old_manual else "automatic") + " release without inheriting its unplug")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, power="battery", lid="closed") as f:
    data = packet(power="battery", manual=True)
    assert attach(f, data)["status"]["ownsOverride"]
    # The app's intermediate AC projection never arrives at the helper.
    step(f, power="ac", manualClock=101)
    f.patch(power="battery", manualClock=102)
    old = copy.deepcopy(data); old["sequence"] = 2
    rejected = f.rpc("syncWorkSession", workSession=old)
    assert rejected["error"] == "invalidWorkLease", rejected
    assert rejected["status"].get("workSession") is None and not rejected["status"]["ownsOverride"], rejected
    assert rejected["workSessionBridge"]["lidEndReceipt"]["kind"] == "disconnect", rejected
    assert sleeps(f) == 1, f.logs()
    passed("a battery-origin old ID cannot cross AC and re-unplug without an intermediate AC lease")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    data = packet()
    attach(f, data)
    pending = step(f, power="battery", manualClock=101, commandFailure=True)
    receipt_id = pending["workSessionBridge"]["lidEndReceipt"]["id"]
    assert pending["status"]["ownsOverride"] and sleeps(f) == 0, pending
    before = f.logs().count("command request: pmset -a disablesleep 0")
    step(f, manualClock=102, commandFailure=False)
    assert f.logs().count("command request: pmset -a disablesleep 0") == before
    recovered = step(f, manualClock=106)
    assert not recovered["status"]["ownsOverride"] and sleeps(f) == 1, recovered
    assert recovered["workSessionBridge"]["lidEndReceipt"]["id"] == receipt_id
    passed("T / T+1 / T+5 retry finishes inside the original terminal window")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    attach(f, packet())
    step(f, power="battery", manualClock=101, commandFailure=True)
    recovered = step(f, manualClock=132, commandFailure=False)
    assert not recovered["status"]["ownsOverride"] and sleeps(f) == 0, recovered
    assert recovered["workSessionBridge"]["lidEndReceipt"]["outcome"] == "endAuthorityExpired", recovered
    passed("after T+30 only own restoration survives; old Sleep is never replayed")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed") as f:
    data = packet(manual=True)
    attach(f, data)
    pending = copy.deepcopy(data)
    extension_id = str(uuid.uuid4())
    pending.update(sequence=2, extensionPreparation=dict(id=extension_id, requestID=data["manualRequestID"],
                   currentDeadline=700, proposedDeadline=1600, expiresAt=105))
    prepared = f.ok("syncWorkSession", workSession=pending)
    assert prepared["status"]["workSession"]["manualDeadline"] == 700
    assert prepared["workSessionBridge"]["extensionPreparationReceipt"]["preparation"]["id"].lower() == extension_id.lower(), prepared
    committed = copy.deepcopy(data)
    committed.update(sequence=3, manualDeadline=1600, manualExtensionID=extension_id)
    committed["lidPermit"]["extensionID"] = extension_id
    f.patch(manualClock=101)
    confirmed = f.ok("syncWorkSession", workSession=committed)
    assert confirmed["status"]["workSession"]["manualDeadline"] == 1600
    stale = copy.deepcopy(data); stale["sequence"] = 4
    assert f.rpc("syncWorkSession", workSession=stale)["error"] == "extensionNotPrepared"
    rollback = copy.deepcopy(data); rollback.update(sequence=5, extensionRollbackID=extension_id)
    restored = f.ok("syncWorkSession", workSession=rollback)
    assert restored["status"]["workSession"]["manualDeadline"] == 700
    passed("prepare keeps old authority; explicit commit/rollback are distinct from a late old revision")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, power="battery", lid="closed") as f:
    data = packet(power="battery", manual=True, deadline=2000)
    attach(f, data)
    pending = copy.deepcopy(data)
    extension_id = str(uuid.uuid4())
    pending.update(sequence=2, extensionPreparation=dict(id=extension_id, requestID=data["manualRequestID"],
                   currentDeadline=2000, proposedDeadline=2900, expiresAt=105))
    f.ok("syncWorkSession", workSession=pending)
    committed = copy.deepcopy(data)
    committed.update(sequence=3, manualDeadline=2900, manualExtensionID=extension_id)
    committed["lidPermit"].update(batteryDeadline=2900, extensionID=extension_id)
    confirmed = f.ok("syncWorkSession", workSession=committed)
    receipt = confirmed["workSessionBridge"]["batteryPermitReceipt"]
    assert receipt["deadline"] == 2900 and receipt["maximumDeadline"] == 7300, confirmed
    assert receipt["extensionID"].lower() == extension_id.lower()
    passed("an explicit battery extension updates its receipt while preserving the first-start ceiling")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, power="battery", lid="closed") as f:
    data = packet(power="battery", manual=True)
    attach(f, data)
    ended = f.ok("syncWorkSession", workSession=empty(data, sequence=2,
                 manualTaskEndRequestID=data["manualRequestID"]))
    assert sleeps(f) == 1 and ended["workSessionBridge"]["lidEndReceipt"]["kind"] == "taskEnded", ended
    assert ended["workSessionBridge"]["lidEndReceipt"].get("observedSleepAt") is None
    sleeping = step(f, systemSleeping=True, manualClock=101)
    assert sleeping["workSessionBridge"]["lidEndReceipt"]["observedSleepAt"] == 101, sleeping
    awake = step(f, systemSleeping=False, power="ac", manualClock=102)
    assert not awake["status"]["ownsOverride"] and not awake["status"]["manualSession"]["active"], awake
    assert sleeps(f) == 1
    passed("linked task end follows battery terminal policy; request acceptance and simulated OS Sleep stay separate")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, power="battery", lid="closed") as f:
    data = packet(power="battery", manual=True)
    attach(f, data)
    f.patch(manualClock=101, commandFailure=True)
    pending = f.rpc("syncWorkSession", workSession=empty(data, sequence=2,
                   manualTaskEndRequestID=data["manualRequestID"]))
    assert pending["status"]["ownsOverride"] and sleeps(f) == 0, pending
    assert pending["workSessionBridge"]["lidEndReceipt"]["kind"] == "taskEnded", pending
    # Restore may finish in the window, but lost final owner approval cancels
    # this task's Sleep permanently while retaining only our cleanup authority.
    recovered = step(f, manualClock=106, commandFailure=False, finalOwnerUnavailable=True)
    assert not recovered["status"]["ownsOverride"] and sleeps(f) == 0, recovered
    assert recovered["workSessionBridge"]["lidEndReceipt"]["phase"] == "consumed", recovered
    again = step(f, manualClock=107, finalOwnerUnavailable=False)
    assert not again["status"]["ownsOverride"] and sleeps(f) == 0, again
    passed("task end restore debt survives transient failure; lost owner cancels the old Sleep permanently")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, lid="closed", sleepDisabled=True) as f:
    attach(f, packet())
    ended = step(f, power="battery", manualClock=101)
    assert ended["status"]["sleepDisabled"] and not ended["status"]["ownsOverride"], ended
    assert sleeps(f) == 0 and "command request: pmset -a disablesleep 0" not in f.logs(), f.logs()
    passed("foreign global ownership is preserved without a forced clear or Sleep")

with Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, sleepDisabled=True) as f:
    data = packet(manual=True)
    data.pop("lidPermit")
    reply = attach(f, data)
    assert reply["status"]["manualSession"]["active"], reply
    assert reply["protection"].get("blockReason") is None, reply
    assert reply["status"]["sleepDisabled"] and not reply["status"]["ownsOverride"], reply
    normalized = copy.deepcopy(data)
    for field in ["sessionID", "manualRequestID"]:
        normalized[field] = str(uuid.UUID(normalized[field])).upper()
    assert reply["status"]["workSession"] == normalized, reply
    assert "command request:" not in f.logs(), f.logs()
    passed("a foreign global override cannot block general-only work or create root ownership")

print("PASS", count, "v4 private helper scenarios; no real power writes or actual Sleep", flush=True)
