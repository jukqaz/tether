#!/usr/bin/env python3
"""v4 policy over executionVersion 3 IPC; isolated journals and dry-run OS effects."""
import copy
import fcntl
import json
import subprocess
import sys
import uuid
from service_fixture import Fixture

results = []


def passed(ids, label):
    results.append(dict(cases=ids, label=label, result="passedAdapter"))
    print("PASS", ",".join(ids), label, flush=True)


def packet(*, sequence=1, power="ac", expiry=130, reasons=None, session=None,
           scopes=None, permit_id=None, duration=None, deadline=None,
           disconnect="sleepIfClosed", protective="sleepIfClosed", issued_at=100):
    scopes = scopes or [power]
    # v4 automatic work is AC-only. Positive battery cases explicitly start a
    # finite manual request; retained opposite-power fields never grant a handoff.
    reasons = (["manual"] if power == "battery" else ["automatic"]) if reasons is None else reasons
    result = dict(version=1, executionVersion=3, sessionID=session or str(uuid.uuid4()),
                  sequence=sequence, power=power, expiry=expiry,
                  reasons=reasons,
                  configuration=dict(enabled=True, automaticEnabled="automatic" in reasons, condition="ac", automaticMinutes=60,
                                     limits=dict(batteryFloor=30)))
    result["lidPermit"] = dict(powerScopes=scopes, disconnectAction=disconnect, protectiveAction=protective)
    if "battery" in scopes:
        result["lidPermit"].update(batteryPermitID=permit_id or str(uuid.uuid4()),
                                  batteryDuration=duration or 1800)
        if deadline is not None:
            result["lidPermit"]["batteryDeadline"] = deadline
    if "manual" in reasons:
        result["manualRequestID"] = result["lidPermit"].get("batteryPermitID", str(uuid.uuid4()))
        if power == "battery":
            result.update(manualDeadline=deadline or issued_at + (duration or 1800),
                          manualStartedOnBattery=True, manualBatteryMaximumDeadline=issued_at + 7200)
            result["lidPermit"]["batteryMaximumDeadline"] = issued_at + 7200
    return result


def attach(f, lease):
    empty = copy.deepcopy(lease)
    empty.update(reasons=[], expiry=None)
    empty.pop("lidPermit", None)
    before = f.ok("snapshot")
    prepared = f.ok("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
    return f.ok("attachWorkSession", workSession=lease, epoch=prepared["epoch"], revision=prepared["revision"])


def fixture(**values):
    # v4 policy fixtures retain the v3 wire, never an autonomous root acquisition.
    return Fixture(control=dict(enabled=False), legacy_state=False, manualClock=100, **values)


def sleeps(f):
    return f.logs().count("IOPMSleepSystem [v3")


def released(lease, *, sequence=2, disconnect=True):
    result = copy.deepcopy(lease)
    result.update(sequence=sequence, power="battery", reasons=[], expiry=None,
                  disconnectEndRequested=disconnect)
    result.pop("lidPermit", None)
    result.pop("manualDeadline", None)
    return result


with Fixture(control=dict(enabled=True), legacy_state=False, lid="closed", manualClock=100) as f:
    r = f.ok("snapshot")
    assert r["workSessionBridge"]["coordinated"] and not r["status"]["ownsOverride"], r
    assert "disablesleep 1" not in f.logs() and sleeps(f) == 0, r
    assert f.rpc("attachApp")["error"] == "coordinatorRequired"
    r = attach(f, packet())
    assert r["status"]["ownsOverride"], r
    passed(["R3-003"], "fresh helper ignores old enabled control and grants lid maintenance only for an authenticated finite v3 lease")


for reasons in [["automatic"], ["manual"], ["automatic", "manual"]]:
    with fixture(lid="closed", external=False, authenticatedRemote=False, foreignKeepAwake=False,
                 foreignDisplayKeepAwake=False, displaySleeping=None, displayTopology="none") as f:
        lease = packet(reasons=reasons)
        if "manual" in reasons:
            lease["manualDeadline"] = 120
        lease["configuration"]["automaticEnabled"] = "automatic" in reasons
        initial = attach(f, lease)
        assert initial["status"]["ownsOverride"] and sleeps(f) == 0, initial
        # No helper marker/notification runs first: the GUI observes battery and
        # releases its AC work before the helper's debounced power evaluation.
        f.patch(power="battery", manualClock=101)
        empty = released(lease)
        r = f.ok("syncWorkSession", workSession=empty)
        end = r["workSessionBridge"].get("lidEndReceipt")
        assert not r["status"]["ownsOverride"] and end is not None, r
        assert end["kind"] == "disconnect" and end["sequence"] == lease["sequence"], r
        assert end["phase"] == "consumed" and end["outcome"] == "commandAccepted" and sleeps(f) == 1, r
        assert "observedSleepAt" not in end, r
        empty.update(sequence=3, endConsumptionID=end["id"])
        f.ok("syncWorkSession", workSession=empty)
        for clock in [102, 103]:
            f.patch(manualClock=clock)
            f.ok("markDiagnostic")
        assert sleeps(f) == 1
    passed(["R3-008", "R3-013"], "GUI-first unplug retains one approved end of " + "+".join(reasons) + " AC work without remote, display or foreign requests")


for control in ["openLid", "followOS", "disabled", "automaticOff", "lidOff", "manualOff", "userStop",
                "oldClient", "expiredLease", "expiredManual", "thermal", "missingObserver"]:
    with fixture(lid="open" if control == "openLid" else "closed") as f:
        lease = packet(reasons=["manual"] if control in ["manualOff", "expiredManual"] else ["automatic"],
                       disconnect="followOS" if control == "followOS" else "sleepIfClosed")
        if "manual" in lease["reasons"]:
            lease["manualDeadline"] = 120
            lease["configuration"]["automaticEnabled"] = False
        assert attach(f, lease)["status"]["ownsOverride"]
        clock = 130 if control == "expiredLease" else 120 if control == "expiredManual" else 101
        f.patch(power="battery", manualClock=clock)
        if control == "thermal":
            f.patch(thermal=2)
        if control == "missingObserver":
            f.patch(powerSourceObservationAvailable=False)
        empty = released(lease, disconnect=control not in ["disabled", "automaticOff", "lidOff", "manualOff", "userStop"])
        if control == "disabled":
            empty["configuration"]["enabled"] = False
        if control == "automaticOff":
            empty["configuration"]["automaticEnabled"] = False
        if control == "oldClient":
            empty.pop("disconnectEndRequested")
        r = f.ok("syncWorkSession", workSession=empty)
        assert not r["status"]["ownsOverride"] and sleeps(f) == 0, r
        end = r["workSessionBridge"].get("lidEndReceipt")
        if control == "followOS":
            assert end["kind"] == "disconnect" and end["outcome"] == "cancelled", r
        else:
            assert end is None, r
    passed(["R3-008", "R3-037"], "GUI-first " + control + " releases only owned work without inventing a disconnect Sleep")


for control in ["expiredLease", "expiredManual", "manualExpiredAutomaticLive"]:
    with fixture(lid="closed") as f:
        reasons = ["automatic", "manual"] if control == "manualExpiredAutomaticLive" else ["manual"]
        lease = packet(reasons=reasons)
        lease["manualDeadline"] = 120
        lease["configuration"]["automaticEnabled"] = "automatic" in reasons
        assert attach(f, lease)["status"]["ownsOverride"]
        f.patch(power="battery", manualClock=130 if control == "expiredLease" else 120)
        # The helper sees the cable change before the GUI publishes its empty
        # session. The same authority boundaries must apply in both orders.
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
        end = r["workSessionBridge"].get("lidEndReceipt")
        if control == "manualExpiredAutomaticLive":
            assert sleeps(f) == 1 and end["kind"] == "disconnect", r
        else:
            assert sleeps(f) == 0 and end is None, r
    passed(["R3-008", "R3-037"], "helper-first " + control + " matches live grant and reason boundaries")


for control in ["expiredLeaseAtProtection", "expiredLeaseThenThermal", "expiredManualThenThermal",
                "expiredManualThenWarning", "expiredManualAutomaticLive"]:
    battery_warning = control == "expiredManualThenWarning"
    power = "battery" if battery_warning else "ac"
    with fixture(power=power, lid="closed", lowPowerWarning=False) as f:
        manual = control.startswith("expiredManual")
        reasons = ["manual"] if manual else ["automatic"]
        if control == "expiredManualAutomaticLive":
            reasons.append("automatic")
        lease = packet(power=power, reasons=reasons, deadline=1900 if battery_warning else None)
        lease["configuration"]["automaticEnabled"] = "automatic" in reasons
        if manual:
            lease["manualDeadline"] = 120
        assert attach(f, lease)["status"]["ownsOverride"]
        expired_at = 120 if manual else 130
        manual_battery_end = control == "expiredManualThenWarning"
        if control not in ["expiredLeaseAtProtection", "expiredManualAutomaticLive"]:
            f.patch(manualClock=expired_at)
            r = f.ok("markDiagnostic")
            assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
            assert sleeps(f) == (1 if manual_battery_end else 0), r
            if manual_battery_end:
                battery_end = r["workSessionBridge"]["lidEndReceipt"]
                assert battery_end["kind"] == "batteryExpired", r
            else:
                assert "lidEndReceipt" not in r["workSessionBridge"], r
            expired_at += 1
        f.patch(manualClock=expired_at, **(dict(lowPowerWarning=True) if battery_warning else dict(thermal=2)))
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
        if manual_battery_end:
            assert "lidProtection" not in r["workSessionBridge"], r
        else:
            assert r["workSessionBridge"]["lidProtection"]["reason"] == ("battery" if battery_warning else "thermal"), r
        if control == "expiredManualAutomaticLive":
            assert sleeps(f) == 1 and r["workSessionBridge"]["lidEndReceipt"]["kind"] == "protection", r
        elif manual_battery_end:
            assert sleeps(f) == 1 and r["workSessionBridge"]["lidEndReceipt"]["id"] == battery_end["id"], r
            assert r["workSessionBridge"]["lidEndReceipt"]["kind"] == "batteryExpired", r
        else:
            assert sleeps(f) == 0 and "lidEndReceipt" not in r["workSessionBridge"], r
        f.patch(manualClock=expired_at + 1)
        f.ok("markDiagnostic")
        assert sleeps(f) == (1 if control == "expiredManualAutomaticLive" or manual_battery_end else 0)
    passed(["R3-037", "R3-051", "R3-052"], control + " retains protection without borrowing expired end authority")


with fixture(lid="closed") as f:
    lease = packet(scopes=["ac", "battery"], reasons=["manual"], duration=1800)
    lease["manualDeadline"] = 1900
    assert attach(f, lease)["status"]["ownsOverride"]
    f.patch(power="battery", manualClock=101)
    continued = copy.deepcopy(lease)
    continued.update(sequence=2, power="battery", disconnectEndRequested=False)
    continued["lidPermit"]["batteryDeadline"] = 1901
    assert f.rpc("syncWorkSession", workSession=continued)["error"] == "invalidWorkLease"
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    assert r["workSessionBridge"]["lidEndReceipt"]["kind"] == "disconnect", r
    assert "batteryPermitReceipt" not in r["workSessionBridge"], r
    f.patch(power="ac", manualClock=102)
    lease["sequence"] = 3
    assert f.rpc("syncWorkSession", workSession=lease)["error"] == "lidLeaseRevoked"
    assert not f.ok("markDiagnostic")["status"]["ownsOverride"] and sleeps(f) == 1
    passed(["R3-010", "R3-014"], "GUI-first opposite-power scope cannot carry the old manual request across unplug or revive it on AC")


with fixture(lid="closed", sleepDisabled=True) as f:
    lease = packet()
    assert not attach(f, lease)["status"]["ownsOverride"]
    f.patch(power="battery", manualClock=101)
    r = f.ok("syncWorkSession", workSession=released(lease))
    assert not r["status"]["ownsOverride"] and r["status"]["sleepDisabled"] and sleeps(f) == 0, r
    assert "lidEndReceipt" not in r["workSessionBridge"] and "disablesleep 0" not in f.logs(), r
    passed(["R3-036"], "GUI-first empty work cannot adopt or clear a pre-existing foreign global override")


with fixture(lid="closed") as f:
    lease = packet()
    attach(f, lease)
    f.patch(power="battery", manualClock=101, finalSnapshot=dict(sleepDisabled=True))
    r = f.ok("syncWorkSession", workSession=released(lease))
    assert not r["status"]["ownsOverride"] and sleeps(f) == 0, r
    assert r["workSessionBridge"]["lidEndReceipt"]["outcome"] == "cancelled", r
    passed(["R3-036", "R3-038"], "GUI-first restoration still rechecks a final foreign global override before any Sleep")


with fixture(lid="closed", foreignKeepAwake=True, authenticatedRemote=True, guiStalled=True) as f:
    lease = packet()
    r = attach(f, lease)
    assert r["status"]["ownsOverride"], r
    f.patch(power="battery", manualClock=101)
    r = f.ok("markDiagnostic")
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert not r["status"]["ownsOverride"] and end["phase"] == "consumed", r
    assert end["kind"] == "disconnect" and end["outcome"] == "commandAccepted" and sleeps(f) == 1, r
    assert "observedSleepAt" not in end, r
    assert "GUI assertion release unconfirmed" in f.logs()
    lease["sequence"] = 2
    assert f.rpc("syncWorkSession", workSession=lease)["error"] == "lidLeaseRevoked"
    for clock in [102, 103, 104]:
        f.patch(manualClock=clock)
        f.ok("markDiagnostic")
    assert sleeps(f) == 1
    # The GUI may consume the incident while still seeing an old AC sample.
    # Its end ACK cannot grant work on a different helper-observed source or
    # cause the already consumed disconnection to request Sleep again.
    lease.update(sequence=3, endConsumptionID=end["id"])
    assert f.rpc("syncWorkSession", workSession=lease)["error"] == "invalidWorkLease"
    r = f.ok("markDiagnostic")
    assert r["workSessionBridge"]["lidEndReceipt"]["id"] == end["id"] and sleeps(f) == 1, r
    f.patch(systemSleeping=True)
    r = f.ok("markDiagnostic")
    assert r["workSessionBridge"]["lidEndReceipt"]["observedSleepAt"] == 104, r
    assert r["workSessionBridge"]["sleepConsumption"]["sequence"] == 1, r
    assert r["workSessionBridge"]["sleepConsumption"]["sessionID"].lower() == lease["sessionID"].lower(), r
    f.patch(systemSleeping=False)
    f.ok("markDiagnostic")
    assert sleeps(f) == 1
    passed(["R3-008", "R3-012", "R3-049"], "stalled GUI, remote connection and foreign idle work cannot delay one approved disconnect Sleep")

for lid, action in [("open", "sleepIfClosed"), ("closed", "followOS")]:
    with fixture(lid=lid) as f:
        attach(f, packet(disconnect=action))
        f.patch(power="battery", manualClock=101)
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and sleeps(f) == 0, r
        assert r["workSessionBridge"]["lidEndReceipt"]["outcome"] == "cancelled", r
    passed(["R3-009" if lid == "open" else "R3-011"], f"{lid}/{action} restores only own override without a Sleep call")

for source, thermal in [("ac", 2), ("battery", 3)]:
    with fixture(power=source, lid="closed", foreignKeepAwake=True) as f:
        lease = packet(power=source, reasons=["automatic", "manual"] if source == "ac" else ["manual"],
                       scopes=[source], deadline=1900 if source == "battery" else None,
                       disconnect="followOS")
        lease["manualDeadline"] = 1900
        attach(f, lease)
        f.patch(thermal=thermal, manualClock=101)
        r = f.ok("markDiagnostic")
        latch = r["workSessionBridge"]["lidProtection"]
        end = r["workSessionBridge"]["lidEndReceipt"]
        assert not r["status"]["ownsOverride"] and latch["reason"] == "thermal", r
        assert end["kind"] == "protection" and end["outcome"] == "commandAccepted" and sleeps(f) == 1, r
        assert r["status"]["lastEvent"] == "protectionSleep", r
        f.patch(thermal=0, manualClock=102)
        f.ok("markDiagnostic")
        lease["sequence"] = 2
        assert not f.rpc("syncWorkSession", workSession=lease)["ok"]
        lease.update(sequence=3, endConsumptionID=end["id"])
        assert f.rpc("syncWorkSession", workSession=lease)["error"] == "safetyBlocked"
        resumed = copy.deepcopy(lease)
        resumed.update(sequence=4, protectionResumeID=latch["id"])
        if source == "ac":
            resumed.update(reasons=["automatic"])
            resumed.pop("manualDeadline", None)
            resumed.pop("manualRequestID", None)
        else:
            # Protection consumed the former manual intent. This is a separate,
            # explicitly approved battery start, not restoration by cooling.
            new_id = str(uuid.uuid4())
            resumed.update(manualRequestID=new_id)
            resumed["lidPermit"]["batteryPermitID"] = new_id
        r = f.ok("syncWorkSession", workSession=resumed)
        assert r["status"]["ownsOverride"] and "lidProtection" not in r["workSessionBridge"], r
        if source == "ac":
            assert json.loads((f.folder / "helper-state.json").read_text())["workSessionLease"]["reasons"] == ["automatic"], r
        assert sleeps(f) == 1
        f.stop()
        days = json.loads((f.folder / "usage.json").read_text())["stats"]["days"]
        assert sum(day["forcedSleeps"] for day in days) == 1, days
    passed(["R3-051" if source == "ac" else "R3-052"], f"{source} thermal {thermal} revokes all permits once and requires the observed latch on explicit safe Resume")

for lid in ["closed", "open"]:
    with fixture(power="battery", lid=lid, lowPowerWarning=False, guiStalled=True, foreignKeepAwake=True) as f:
        lease = packet(power="battery", scopes=["battery"], deadline=1900, reasons=["manual"])
        lease["manualDeadline"] = 1900
        attach(f, lease)
        f.patch(lowPowerWarning=True, manualClock=101)
        r = f.ok("markDiagnostic")
        latch = r["workSessionBridge"]["lidProtection"]
        end = r["workSessionBridge"]["lidEndReceipt"]
        assert not r["status"]["ownsOverride"] and latch["reason"] == "battery", r
        assert r["status"]["batteryPercent"] == 80, r
        assert end["kind"] == "protection" and end["phase"] == "consumed", r
        assert sleeps(f) == (1 if lid == "closed" else 0), r
        if lid == "closed":
            assert r["status"]["lastEvent"] == "protectionSleep", r
        for clock in [102, 103, 104]:
            f.patch(manualClock=clock, thermal=0)
            f.ok("markDiagnostic")
        lease.update(sequence=2, endConsumptionID=end["id"], protectionResumeID=latch["id"])
        assert f.rpc("syncWorkSession", workSession=lease)["error"] == "safetyBlocked"
        f.patch(lowPowerWarning=False, manualClock=105)
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and r["workSessionBridge"]["lidProtection"]["id"] == latch["id"], r
        lease.pop("protectionResumeID")
        lease["sequence"] = 3
        assert f.rpc("syncWorkSession", workSession=lease)["error"] == "safetyBlocked"
        automatic = copy.deepcopy(lease)
        automatic.update(sequence=4, protectionResumeID=latch["id"], reasons=["automatic"])
        assert f.rpc("syncWorkSession", workSession=automatic)["error"] == "invalidWorkLease"
        new_id = str(uuid.uuid4())
        lease.update(sequence=5, protectionResumeID=latch["id"], manualRequestID=new_id)
        lease["lidPermit"]["batteryPermitID"] = new_id
        r = f.ok("syncWorkSession", workSession=lease)
        assert r["status"]["ownsOverride"] and "lidProtection" not in r["workSessionBridge"], r
        assert sleeps(f) == (1 if lid == "closed" else 0)
    passed(["R3-052"], f"{lid}: warning ends stalled-GUI manual work once; warning-clear cannot enable battery automatic, and a new explicit manual ID is required")

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    attach(f, packet(power="battery", deadline=1900))
    f.patch(lowPowerWarning=True, manualClock=101)
    first = f.ok("markDiagnostic")["workSessionBridge"]["lidProtection"]
    f.stop(); f.start()
    r = f.ok("snapshot")
    assert not r["status"]["ownsOverride"] and r["workSessionBridge"]["lidProtection"]["id"] == first["id"], r
    f.patch(lowPowerWarning=False, thermal=0, manualClock=102)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and r["workSessionBridge"]["lidProtection"]["id"] == first["id"], r
    assert sleeps(f) == 1
    passed(["R3-052"], "warning, helper restart, cooling and warning-clear observations never reactivate ended work or replay Sleep")

for warning, expected in [(True, "safetyBlocked"), (None, "powerObservationUnavailable")]:
    with fixture(power="battery", lid="closed", lowPowerWarning=warning) as f:
        lease = packet(power="battery", deadline=1900)
        empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
        before = f.ok("snapshot")
        prep = f.ok("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
        r = f.rpc("attachWorkSession", workSession=lease, epoch=prep["epoch"], revision=prep["revision"])
        assert r["error"] == expected and not r["status"]["ownsOverride"] and sleeps(f) == 0, r
    passed(["R3-052"], f"new battery permit rejects warning={warning} without treating unknown as healthy")

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    lease = packet(power="battery", deadline=1900)
    attach(f, lease)
    f.patch(lowPowerWarning=None, manualClock=101)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and r["workSessionBridge"]["lidProtection"]["reason"] == "sensor", r
    assert sleeps(f) == 0
    end = r["workSessionBridge"]["lidEndReceipt"]
    lease.update(sequence=2, endConsumptionID=end["id"], protectionResumeID=r["workSessionBridge"]["lidProtection"]["id"])
    assert f.rpc("syncWorkSession", workSession=lease)["error"] == "safetyBlocked"
    passed(["R3-052"], "unavailable direct warning releases owned battery work, retains observation protection and cannot authorize Sleep or Resume")

for warning in [True, None]:
    with fixture(lid="closed", lowPowerWarning=warning) as f:
        r = attach(f, packet())
        assert r["status"]["ownsOverride"] and "lidProtection" not in r["workSessionBridge"], r
        f.patch(manualClock=101)
        r = f.ok("markDiagnostic")
        assert r["status"]["ownsOverride"] and sleeps(f) == 0, r
    passed(["R3-051"], f"AC work ignores the battery warning value {warning}")

for final in [False, None]:
    with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
        attach(f, packet(power="battery", deadline=1900))
        f.patch(lowPowerWarning=True, finalLowPowerWarning=final, manualClock=101)
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and r["workSessionBridge"]["lidProtection"]["reason"] == "battery", r
        assert r["workSessionBridge"]["lidEndReceipt"]["outcome"] == "cancelled" and sleeps(f) == 0, r
    passed(["R3-038", "R3-052"], f"final battery warning {final} cancels protective Sleep while keeping the latch")

for final_battery, expected_sleeps in [(30, 1), (80, 0)]:
    with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
        attach(f, packet(power="battery", deadline=1900))
        f.patch(battery=30, finalBattery=final_battery, manualClock=101)
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and r["workSessionBridge"]["lidProtection"]["reason"] == "battery", r
        assert sleeps(f) == expected_sleeps, r
    passed(["R3-052"], f"battery floor protection shares the one-shot path and rechecks final charge {final_battery}")

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    lease = packet(power="battery", scopes=["ac", "battery"], duration=1800, deadline=1900)
    attach(f, lease)
    first = f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipt"]
    assert first["observedAt"] == 100 and first["deadline"] == 1900, first
    f.patch(manualClock=110)
    enlarged = copy.deepcopy(lease)
    enlarged.update(sequence=2, expiry=140, manualDeadline=5000)
    enlarged["lidPermit"].update(batteryDuration=7200, batteryDeadline=5000)
    assert f.rpc("syncWorkSession", workSession=enlarged)["error"] == "extensionNotPrepared"
    lease.update(sequence=3, expiry=140)
    r = f.ok("syncWorkSession", workSession=lease)
    assert r["workSessionBridge"]["batteryPermitReceipt"] == first, r
    f.patch(power="ac", manualClock=115)
    lease.update(sequence=4, power="ac", expiry=145)
    r = f.ok("syncWorkSession", workSession=lease)
    assert r["status"]["ownsOverride"] and r["workSessionBridge"]["batteryPermitReceipt"] == first, r
    f.patch(power="battery", manualClock=120)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    assert r["workSessionBridge"]["batteryPermitReceipt"] == first, r
    assert r["workSessionBridge"]["lidEndReceipt"]["kind"] == "disconnect", r
    f.stop(); f.start()
    r = f.ok("snapshot")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    assert json.loads((f.folder / "helper-state.json").read_text())["batteryPermitReceipts"] == [first]
    empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
    r = f.ok("prepareWorkSession", workSession=empty, epoch=r["epoch"], revision=r["revision"])
    assert r["workSessionBridge"]["batteryPermitReceipt"] == first and not r["status"]["ownsOverride"], r
    assert sleeps(f) == 1
    passed(["R3-014", "R3-015", "R3-017"], "direct manual receipt keeps its first deadline through refresh and AC; re-unplug consumes work, and restart retains evidence only")

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    session = str(uuid.uuid4())
    manual = packet(power="battery", session=session, scopes=["ac", "battery"], duration=7200, deadline=7300)
    attach(f, manual)
    first = f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipt"]
    assert first["observedAt"] == 100 and first["deadline"] == 7300, first
    f.patch(power="ac", manualClock=110)
    automatic = packet(sequence=2, session=session, expiry=140)
    r = f.ok("syncWorkSession", workSession=automatic)
    assert r["status"]["ownsOverride"] and r["workSessionBridge"]["batteryPermitReceipt"] == first, r
    assert r["workSessionBridge"]["batteryPermitReceipts"] == [first], r
    # A saved or late manual receipt cannot turn this new AC-only automatic
    # decision into battery authorization after the next cable boundary.
    f.patch(power="battery", manualClock=111)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    assert r["workSessionBridge"]["batteryPermitReceipts"] == [first], r
    continued = copy.deepcopy(automatic)
    continued.update(sequence=3, power="battery", expiry=141)
    assert not f.rpc("syncWorkSession", workSession=continued)["ok"]
    assert not f.ok("snapshot")["status"]["ownsOverride"] and sleeps(f) == 1
    passed(["R3-014", "R3-015"], "late manual receipt remains evidence after an AC automatic-ID swap but cannot authorize automatic battery continuation")

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    session = str(uuid.uuid4())
    manual = packet(power="battery", session=session, duration=1800, deadline=1900)
    attach(f, manual)
    first = f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipt"]
    f.patch(manualClock=110)
    empty = copy.deepcopy(manual); empty.update(sequence=2, reasons=[], expiry=None); empty.pop("lidPermit")
    assert not f.ok("syncWorkSession", workSession=empty)["status"]["ownsOverride"]
    newer = packet(sequence=3, power="battery", session=session, expiry=140,
                   duration=1800, deadline=1910, issued_at=110)
    # Discard this successful ACK locally: persisted evidence must still contain
    # both separately approved requests, never a fallback automatic handoff.
    f.ok("syncWorkSession", workSession=newer)
    current = f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipt"]
    assert current["observedAt"] == 110 and current["deadline"] == 1910, current
    assert current["permitID"] != first["permitID"]
    assert f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipts"] == [first, current]
    f.patch(manualClock=111)
    older = copy.deepcopy(manual)
    assert f.rpc("syncWorkSession", workSession=older)["error"] == "invalidWorkLease"
    r = f.ok("snapshot")
    assert r["workSessionBridge"]["batteryPermitReceipts"] == [first, current], r
    assert r["workSessionBridge"]["batteryPermitReceipt"] == current and sleeps(f) == 0, r
    passed(["R3-014", "R3-015"], "lost ACK keeps older and current explicit manual records distinct and rejects a stale old-request replay")

for terminal in ["systemSleep", "lidEnd"]:
    with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
        lease = packet(power="battery", scopes=["ac", "battery"], duration=7200, deadline=7300)
        attach(f, lease)
        first = f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipt"]
        assert first["observedAt"] == 100 and first["deadline"] == 7300, first
        f.patch(power="ac", manualClock=110)
        lease.update(sequence=2, power="ac", expiry=140)
        assert f.ok("syncWorkSession", workSession=lease)["status"]["ownsOverride"]
        f.patch(manualClock=120)
        if terminal == "systemSleep":
            # Exercise the real OS notification handler with a fake observation;
            # no Sleep command is issued to the developer's machine.
            f.patch(systemSleeping=True)
            r = f.ok("markDiagnostic")
            consumed = r["workSessionBridge"]["sleepConsumption"]
            assert consumed["sessionID"] == first["sessionID"] and consumed["observedAt"] == 120, r
            f.patch(systemSleeping=False, manualClock=140)
            r = f.ok("markDiagnostic")
        else:
            r = f.ok("sleep")
            ended = r["workSessionBridge"]["lidEndReceipt"]
            assert ended["phase"] == "consumed" and ended["sessionID"] == first["sessionID"], r
            f.patch(manualClock=140)
            r = f.ok("markDiagnostic")
        assert r["workSessionBridge"]["batteryPermitReceipt"] == first, r
        assert r["workSessionBridge"]["batteryPermitReceipts"] == [first], r
        assert not r["status"]["ownsOverride"] and sleeps(f) == (terminal == "lidEnd"), r
        assert "workSessionLease" not in json.loads((f.folder / "helper-state.json").read_text())
        # A same-boot terminal journal also preserves late ACK metadata across a
        # helper restart; it remains evidence, never restored execution authority.
        f.stop(); f.start()
        r = f.ok("snapshot")
        assert r["workSessionBridge"]["batteryPermitReceipts"] == [first], r
        assert not r["status"]["ownsOverride"] and sleeps(f) == (terminal == "lidEnd"), r
        # Fresh authenticated preparation takes precedence over the old terminal
        # scope, even though its battery evidence is still retained in the journal.
        empty = packet(session=str(uuid.uuid4()), reasons=[])
        empty.update(expiry=None); empty.pop("lidPermit")
        r = f.ok("prepareWorkSession", workSession=empty, epoch=r["epoch"], revision=r["revision"])
        assert r["workSessionBridge"]["batteryPermitReceipts"] == [], r
        assert "batteryPermitReceipt" not in r["workSessionBridge"] and not r["status"]["ownsOverride"], r
        assert json.loads((f.folder / "helper-state.json").read_text())["batteryPermitReceipts"] == [first]
    passed(["R3-014", "R3-049"], terminal + " preserves late battery evidence without granting work; a new authenticated preparation excludes the old session")

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    old = packet(power="battery", scopes=["ac", "battery"], deadline=1900)
    attach(f, old)
    f.patch(power="ac", manualClock=110)
    old.update(sequence=2, power="ac", expiry=140)
    f.ok("syncWorkSession", workSession=old)
    f.patch(power="ac", systemSleeping=True, manualClock=120)
    f.ok("markDiagnostic")
    f.patch(systemSleeping=False, manualClock=140)
    f.ok("markDiagnostic")
    f.patch(power="battery")
    new = packet(power="battery", expiry=170, scopes=["ac", "battery"], deadline=1940, issued_at=140)
    r = attach(f, new)
    first = r["workSessionBridge"]["batteryPermitReceipt"]
    assert r["status"]["ownsOverride"] and r["workSessionBridge"]["batteryPermitReceipts"] == [first], r
    assert first["sessionID"].lower() == new["sessionID"].lower() and first["observedAt"] == 140, r
    f.patch(power="ac", manualClock=160)
    new.update(sequence=2, power="ac", expiry=190)
    f.ok("syncWorkSession", workSession=new)
    r = f.ok("sleep")
    assert r["workSessionBridge"]["sleepConsumption"]["sessionID"].lower() == old["sessionID"].lower(), r
    assert r["workSessionBridge"]["lidEndReceipt"]["sessionID"].lower() == new["sessionID"].lower(), r
    assert r["workSessionBridge"]["batteryPermitReceipts"] == [first], r
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    passed(["R3-014", "R3-049"], "the newest consumed end selects its own session's evidence over an older system Sleep receipt")

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    old = packet(power="battery", reasons=["manual"], deadline=120)
    old["manualDeadline"] = 400
    old["configuration"]["automaticEnabled"] = False
    assert attach(f, old)["status"]["ownsOverride"]
    f.patch(manualClock=110)
    newer = copy.deepcopy(old)
    new_id = str(uuid.uuid4())
    newer.update(sequence=2, expiry=115, manualRequestID=new_id)
    newer["lidPermit"].update(batteryPermitID=new_id, batteryDeadline=400)
    assert f.ok("syncWorkSession", workSession=newer)["status"]["ownsOverride"]
    f.patch(manualClock=115, commandFailure=True)
    r = f.rpc("markDiagnostic")
    assert r["error"] == "pmsetFailed" and r["status"]["ownsOverride"], r
    assert not r["workSessionBridge"].get("lidEndReceipt") and sleeps(f) == 0, r
    f.patch(manualClock=120, commandFailure=False)
    r = f.rpc("markDiagnostic")
    assert not r["workSessionBridge"].get("lidEndReceipt") and sleeps(f) == 0, r
    f.patch(manualClock=145)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
    assert not r["workSessionBridge"].get("lidEndReceipt") and sleeps(f) == 0, r
    passed(["R3-014", "R3-036", "R3-037"], "a new permit with an earlier parent expiry discards the older prepared endpoint and only restores owned debt")

for mismatch in ["sessionID", "bootID"]:
    with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
        lease = packet(power="battery", scopes=["ac", "battery"], duration=1800, deadline=1900)
        attach(f, lease)
        first = f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipt"]
        f.patch(power="ac", systemSleeping=True, manualClock=120)
        f.ok("markDiagnostic")
        f.patch(systemSleeping=False, manualClock=140)
        f.ok("markDiagnostic")
        f.stop()
        state_file = f.folder / "helper-state.json"
        journal = json.loads(state_file.read_text())
        journal["workSleepConsumption"][mismatch] = str(uuid.uuid4())
        state_file.write_text(json.dumps(journal))
        f.start()
        r = f.ok("snapshot")
        assert r["workSessionBridge"]["batteryPermitReceipts"] == [], r
        assert "batteryPermitReceipt" not in r["workSessionBridge"] and not r["status"]["ownsOverride"], r
        assert json.loads(state_file.read_text())["batteryPermitReceipts"] == [first] and sleeps(f) == 0
    passed(["R3-014", "R3-049"], "terminal receipt metadata excludes mismatched " + mismatch)

for mismatch in ["sessionID", "bootID"]:
    with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
        session = str(uuid.uuid4())
        lease = packet(power="battery", session=session, scopes=["ac", "battery"], duration=1800, deadline=1900)
        attach(f, lease)
        original = f.ok("snapshot")["workSessionBridge"]["batteryPermitReceipt"]
        f.patch(power="ac", manualClock=120)
        f.ok("markDiagnostic")
        f.stop()
        state_file = f.folder / "helper-state.json"
        journal = json.loads(state_file.read_text())
        journal["batteryPermitReceipts"][0][mismatch] = str(uuid.uuid4())
        state_file.write_text(json.dumps(journal))
        f.start()
        r = f.ok("snapshot")
        empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
        r = f.ok("prepareWorkSession", workSession=empty, epoch=r["epoch"], revision=r["revision"])
        assert "batteryPermitReceipt" not in r["workSessionBridge"], r
        assert r["workSessionBridge"]["batteryPermitReceipts"] == [], r
        assert not r["status"]["ownsOverride"] and sleeps(f) == 0, r
    passed(["R3-014"], "response receipt fallback/batch excludes mismatched " + mismatch)

with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
    lease = packet(power="battery", duration=1800, deadline=120)
    attach(f, lease)
    r = f.ok("snapshot")
    assert r["workSessionBridge"]["batteryPermitReceipt"]["deadline"] == 120, r
    f.patch(manualClock=121)
    lease.update(sequence=2, expiry=151)
    lease["lidPermit"]["batteryDeadline"] = 1000
    assert f.rpc("syncWorkSession", workSession=lease)["error"] == "batteryPermitExpired"
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["kind"] == "batteryExpired" and end["phase"] == "consumed", r
    assert end["outcome"] == "commandAccepted", r
    f.patch(manualClock=122)
    f.ok("markDiagnostic")
    assert sleeps(f) == 1
    passed(["R3-010", "R3-014"], "the earlier battery deadline ends once and a late refresh cannot reauthorize the expired ID")

for case, values, parent_expiry, action, expected_sleeps in [
        ("closed", dict(manualClock=110), 130, "sleepIfClosed", 1),
        ("parent-at-endpoint", dict(manualClock=110), 110, "sleepIfClosed", 1),
        ("last-moment", dict(manualClock=139), 130, "sleepIfClosed", 1),
        ("stale-endpoint", dict(manualClock=141), 130, "sleepIfClosed", 0),
        ("heartbeat-before-endpoint", dict(manualClock=110), 109, "sleepIfClosed", 0),
        ("open", dict(manualClock=110, lid="open"), 130, "sleepIfClosed", 0),
        ("AC", dict(manualClock=110, power="ac"), 130, "sleepIfClosed", 0),
        ("unknown-power", dict(manualClock=110, power="unknown"), 130, "sleepIfClosed", 0),
        ("follow-OS", dict(manualClock=110), 130, "followOS", 0)]:
    with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
        lease = packet(power="battery", expiry=parent_expiry, deadline=110, disconnect=action, protective=action)
        assert attach(f, lease)["status"]["ownsOverride"]
        f.patch(**values)
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and sleeps(f) == expected_sleeps, r
        if expected_sleeps:
            end = r["workSessionBridge"]["lidEndReceipt"]
            assert end["kind"] == "batteryExpired" and end["phase"] == "consumed", r
            assert end["outcome"] == "commandAccepted", r
        f.patch(manualClock=values["manualClock"] + 1)
        f.ok("markDiagnostic")
        assert sleeps(f) == expected_sleeps
    passed(["R3-014", "R3-037"], "battery endpoint " + case + " uses its fixed 30-second preapproved end window once")

for automatic_enabled in [False, True]:
    with fixture(power="battery", lid="closed", lowPowerWarning=False) as f:
        lease = packet(power="battery", reasons=["manual"], deadline=120)
        lease["manualDeadline"] = 110
        lease["configuration"]["automaticEnabled"] = automatic_enabled
        assert attach(f, lease)["status"]["ownsOverride"]
        f.patch(manualClock=110)
        r = f.ok("markDiagnostic")
        assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
        assert r["workSessionBridge"]["lidEndReceipt"]["kind"] == "batteryExpired", r
        forbidden = copy.deepcopy(lease)
        forbidden.update(sequence=2, reasons=["manual", "automatic"], expiry=140)
        assert not f.rpc("syncWorkSession", workSession=forbidden)["ok"]
        f.patch(manualClock=111)
        f.ok("markDiagnostic")
        assert not f.ok("snapshot")["status"]["ownsOverride"] and sleeps(f) == 1
    passed(["R3-013", "R3-014"], f"manual battery expiry ends once with saved AC automatic={automatic_enabled}; mixed automatic battery work cannot revive it")

for changed in [dict(finalSnapshot=dict(power="ac")), dict(finalSnapshot=dict(lid="open")),
                dict(finalSnapshot=dict(power="unknown")), dict(finalSnapshot=dict(lid=None)),
                dict(finalSnapshot=dict(sleepDisabled=True)), dict(finalSnapshot=dict(sleepDisabled=None)),
                dict(finalOwnerUnavailable=True), dict(finalBatteryPermitValid=True)]:
    with fixture(lid="closed") as f:
        attach(f, packet())
        f.patch(power="battery", manualClock=101, **changed)
        r = f.ok("markDiagnostic")
        assert r["workSessionBridge"]["lidEndReceipt"]["outcome"] == "cancelled" and sleeps(f) == 0, r
        f.patch(manualClock=102)
        f.ok("markDiagnostic")
        assert sleeps(f) == 0
    passed(["R3-038"], "final requery cancels once on " + str(changed))

with fixture(lid="closed") as f:
    attach(f, packet())
    with (f.folder / "recovery.lock").open("r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        f.patch(power="battery", manualClock=101)
        r = f.rpc("markDiagnostic")
        assert r["error"] == "recoveryLockBusy" and r["status"]["ownsOverride"], r
        assert sleeps(f) == 0 and not r["workSessionBridge"].get("lidEndReceipt"), r
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    f.patch(manualClock=102)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
    assert r["workSessionBridge"]["lidEndReceipt"]["kind"] == "disconnect" and sleeps(f) == 1, r
    f.patch(manualClock=103)
    f.ok("markDiagnostic")
    assert sleeps(f) == 1
    passed(["R3-008", "R3-036"], "a busy recovery lock preserves the unplug boundary until one successful transaction")

for source, target, condition in [("ac", "battery", "ac"), ("battery", "ac", "battery"),
                                  ("ac", "battery", "any")]:
    with fixture(lid="closed", power=source) as f:
        lease = packet(power=source, scopes=["ac", "battery"], duration=1800,
                       deadline=1800 if source == "battery" else None,
                       reasons=["automatic", "manual"])
        lease["manualDeadline"] = 120
        lease["configuration"].update(condition=condition, manualBatteryContinuationMinutes=30)
        if source == "battery":
            empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
            before = f.ok("snapshot")
            prep = f.ok("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
            rejected = f.rpc("attachWorkSession", workSession=lease, epoch=prep["epoch"], revision=prep["revision"])
            assert rejected["error"] == "invalidWorkLease" and not rejected["status"]["ownsOverride"], rejected
            f.patch(power=target, manualClock=122)
            assert not f.ok("markDiagnostic")["status"]["ownsOverride"] and sleeps(f) == 0
        else:
            assert attach(f, lease)["status"]["ownsOverride"]
            f.patch(manualClock=121)
            assert f.ok("markDiagnostic")["status"]["ownsOverride"], "AC automatic remains after manual expiry"
            f.patch(power=target, manualClock=122)
            forbidden = copy.deepcopy(lease)
            forbidden.update(sequence=2, power=target, expiry=152)
            assert not f.rpc("syncWorkSession", workSession=forbidden)["ok"]
            r = f.ok("markDiagnostic")
            assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
            assert sleeps(f) == 1 and r["workSessionBridge"]["lidEndReceipt"]["kind"] == "disconnect", r
        f.patch(manualClock=123)
        f.ok("markDiagnostic")
        assert sleeps(f) == (1 if source == "ac" else 0)
    passed(["R3-008", "R3-010"], "legacy " + condition + " cannot authorize battery automatic or carry an expired manual scope across a power boundary")

with fixture(lid="closed") as f:
    attach(f, packet())
    f.patch(power="battery", manualClock=101, commandFailure=True)
    r = f.rpc("markDiagnostic")
    assert r["error"] == "pmsetFailed", r
    assert r["status"]["ownsOverride"] and sleeps(f) == 0, r
    pending = r["workSessionBridge"]["lidEndReceipt"]
    assert pending["phase"] == "captured" and pending["outcome"] == "restoreUnverified", r
    assert json.loads((f.folder / "power-ownership.json").read_text())["owned"]
    writes = f.logs().count("command request: pmset -a disablesleep 0")
    for clock in [102, 103, 104]:
        f.patch(manualClock=clock)
        r = f.rpc("markDiagnostic")
        assert r["error"] == "pmsetFailed", r
        end = r["workSessionBridge"]["lidEndReceipt"]
        assert end["id"] == pending["id"] and end["phase"] == "captured", r
        assert end["outcome"] == "restoreUnverified", r
    assert f.logs().count("command request: pmset -a disablesleep 0") == writes and sleeps(f) == 0
    # Exercise the same observation key as production. A transient command
    # failure must not suppress restoration forever, and changing the injected
    # fault must not bypass the retry interval.
    f.patch(manualClock=106)
    r = f.rpc("markDiagnostic")
    assert r["error"] == "pmsetFailed", r
    assert r["workSessionBridge"]["lidEndReceipt"]["id"] == pending["id"], r
    assert r["workSessionBridge"]["lidEndReceipt"]["phase"] == "captured", r
    assert f.logs().count("command request: pmset -a disablesleep 0") == writes + 1
    f.patch(commandFailure=False, manualClock=107)
    r = f.rpc("markDiagnostic")
    assert r["error"] == "pmsetFailed" and r["status"]["ownsOverride"], r
    assert f.logs().count("command request: pmset -a disablesleep 0") == writes + 1
    f.patch(manualClock=111)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["id"] == pending["id"] and end["phase"] == "consumed", r
    assert end["outcome"] == "commandAccepted", r
    assert f.logs().count("command request: pmset -a disablesleep 0") == writes + 2
    f.patch(manualClock=112)
    f.ok("markDiagnostic")
    assert sleeps(f) == 1
    passed(["R3-036"], "failed restoration retains one end, suppresses fast repeats and uses the 5/10-second retry slots before one verified Sleep")

for case, changed in [
        ("open", dict(lid="open")), ("AC", dict(power="ac")),
        ("unknown-power", dict(power="unknown")), ("unknown-lid", dict(lid=None)),
        ("owner-unavailable", dict(finalOwnerUnavailable=True)),
        ("boot-change", dict(bootID="another-boot")), ("not-full-wake", dict(fullWake=False))]:
    with fixture(lid="closed") as f:
        attach(f, packet())
        f.patch(power="battery", manualClock=101, commandFailure=True)
        pending = f.rpc("markDiagnostic")["workSessionBridge"]["lidEndReceipt"]
        assert pending["phase"] == "captured" and sleeps(f) == 0
        f.patch(commandFailure=False, manualClock=102, **changed)
        r = f.rpc("markDiagnostic")
        end = json.loads((f.folder / "helper-state.json").read_text())["lidEndReceipt"]
        assert end["id"] == pending["id"] and end["phase"] == "consumed", r
        assert end["outcome"] == "cancelled" and sleeps(f) == 0, r
        f.patch(manualClock=132)
        f.rpc("markDiagnostic")
        assert sleeps(f) == 0
    passed(["R3-036", "R3-038"], "pending restoration cancels once on " + case + " without borrowing later Sleep authority")

with fixture(lid="closed") as f:
    attach(f, packet())
    f.patch(power="battery", manualClock=101, commandFailure=True)
    pending = f.rpc("markDiagnostic")["workSessionBridge"]["lidEndReceipt"]
    f.patch(commandFailure=False, manualClock=102)
    replacement = packet(power="battery", expiry=132, deadline=1900, issued_at=102)
    r = attach(f, replacement)
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["id"] == pending["id"] and end["phase"] == "consumed" and end["outcome"] == "cancelled", r
    assert r["status"]["ownsOverride"] and sleeps(f) == 0, r
    f.patch(manualClock=132)
    f.ok("markDiagnostic")
    assert sleeps(f) == 0
    passed(["R3-036", "R3-038"], "a new authenticated valid lease cancels the pending old end and preserves only its new work")

with fixture(lid="closed") as f:
    lease = packet()
    attach(f, lease)
    f.patch(power="battery", manualClock=101, commandFailure=True)
    pending = f.rpc("markDiagnostic")["workSessionBridge"]["lidEndReceipt"]
    disabled = released(lease, disconnect=False)
    disabled["endConsumptionID"] = pending["id"]
    disabled["configuration"]["enabled"] = False
    f.patch(commandFailure=False, manualClock=102)
    r = f.rpc("syncWorkSession", workSession=disabled)
    assert r["control"]["enabled"] is False, r
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["id"] == pending["id"] and end["phase"] == "consumed" and end["outcome"] == "cancelled", r
    assert sleeps(f) == 0, r
    f.patch(manualClock=131)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"] and sleeps(f) == 0, r
    passed(["R3-036", "R3-038"], "an authenticated disabled empty lease cancels the pending end before recovery can request Sleep")

with fixture(lid="closed") as f:
    attach(f, packet(expiry=130))
    f.patch(power="battery", manualClock=101, commandFailure=True)
    pending = f.rpc("markDiagnostic")["workSessionBridge"]["lidEndReceipt"]
    f.patch(commandFailure=False, manualClock=131)
    r = f.ok("markDiagnostic")
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["id"] == pending["id"] and end["phase"] == "consumed", r
    assert end["outcome"] == "endAuthorityExpired", r
    assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"] and sleeps(f) == 0, r
    passed(["R3-036", "R3-037"], "a restore retry at the 30-second end-action deadline repairs ownership without a new Sleep")

with fixture(lid="closed") as f:
    attach(f, packet())
    f.patch(power="battery", manualClock=101, commandFailure=True)
    pending = f.rpc("markDiagnostic")["workSessionBridge"]["lidEndReceipt"]
    f.stop()
    f.patch(commandFailure=False, manualClock=102)
    f.start()
    r = f.ok("snapshot")
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["id"] == pending["id"] and end["phase"] == "consumed", r
    assert end["outcome"] == "executorInterrupted" and sleeps(f) == 0, r
    assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
    passed(["R3-036", "R3-037"], "helper restart interrupts a pending end and restores its own debt without reviving Sleep")


owner_script = r'''
import copy, json, socket, sys, uuid
socket_path, encoded = sys.argv[1:]
lease = json.loads(encoded)
def rpc(action, **values):
    request = dict(version=2, id=str(uuid.uuid4()), action=action, **values)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(socket_path)
        connection.sendall(json.dumps(request).encode() + b'\n')
        data = b''
        while not data.endswith(b'\n'):
            part = connection.recv(8192)
            assert part, 'missing response'
            data += part
    reply = json.loads(data)
    assert reply['ok'], reply
    return reply
empty = copy.deepcopy(lease)
empty.update(reasons=[], expiry=None)
empty.pop('lidPermit', None)
before = rpc('snapshot')
prepared = rpc('prepareWorkSession', workSession=empty, epoch=before['epoch'], revision=before['revision'])
print(json.dumps(rpc('attachWorkSession', workSession=lease,
                     epoch=prepared['epoch'], revision=prepared['revision'])), flush=True)
if sys.stdin.readline().strip() == 'detach':
    print(json.dumps(rpc('detachApp')), flush=True)
'''

for owner_alive in [True, False]:
    with fixture(lid="closed") as f:
        owner = subprocess.Popen([sys.executable, "-c", owner_script, f.sock, json.dumps(packet())],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            initial = json.loads(owner.stdout.readline())
            assert initial["status"]["ownsOverride"], initial
            if owner_alive:
                # The same authenticated process requests detach after battery
                # and closed lid are already visible to the helper.
                f.patch(power="battery", manualClock=101)
                output, errors = owner.communicate("detach\n", timeout=5)
                assert owner.returncode == 0, errors
                r = json.loads(output)
                assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
                assert r["workSessionBridge"]["lidEndReceipt"]["kind"] == "disconnect", r
            else:
                # Keep a real owned restore debt across the owner's exit. Its
                # later unplug observation cannot supply a new Sleep grant.
                f.patch(commandFailure=True)
                _, errors = owner.communicate("exit\n", timeout=5)
                assert owner.returncode == 0, errors
                f.patch(power="battery", commandFailure=False, manualClock=101)
                r = f.ok("markDiagnostic")
                assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"], r
                assert sleeps(f) == 0, r
            f.patch(manualClock=102)
            f.ok("markDiagnostic")
            assert sleeps(f) == (1 if owner_alive else 0)
        finally:
            if owner.poll() is None:
                owner.kill()
            owner.wait(timeout=5)
    passed(["R3-008", "R3-036", "R3-038"], "live-owner detach ends observed battery work once" if owner_alive else
           "dead-owner unplug restores owned debt without new Sleep authority")

with fixture(lid="closed") as f:
    attach(f, packet())
    f.patch(power="battery", manualClock=101, sleepFailure=True)
    r = f.ok("markDiagnostic")
    assert r["workSessionBridge"]["lidEndReceipt"]["outcome"] == "commandRejected" and sleeps(f) == 1, r
    assert r["status"]["lastEvent"] == "sleepRefused", r
    f.patch(sleepFailure=False, manualClock=102)
    f.ok("markDiagnostic")
    assert sleeps(f) == 1 and "pmset sleepnow" not in f.logs()
    f.stop()
    # sleepRequestAttempts is the source-level alias of this retained stored
    # key. A rejected native call still contributes one request attempt.
    days = json.loads((f.folder / "usage.json").read_text())["stats"]["days"]
    assert sum(day["forcedSleeps"] for day in days) == 1, days
    passed(["R3-008", "R3-048"], "rejected Sleep remains one consumed attempt without retry TTL or pmset fallback")

with fixture(lid="closed") as f:
    attach(f, packet())
    f.patch(manualClock=130)
    r = f.ok("markDiagnostic")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 0, r
    f.stop(); f.patch(power="battery"); f.start()
    assert not f.ok("snapshot")["status"]["ownsOverride"] and sleeps(f) == 0
    passed(["R3-037"], "finite lease expiry and restart restore only; neither invents a disconnect event")

with fixture(lid="open") as f:
    attach(f, packet())
    r = f.ok("sleep")
    assert not r["status"]["ownsOverride"] and sleeps(f) == 1, r
    assert r["workSessionBridge"]["lidEndReceipt"]["kind"] == "user", r
    f.ok("markDiagnostic")
    assert sleeps(f) == 1
    passed(["R3-047", "R3-048"], "authorized user Sleep shares the once-only restoration path even with open lid on AC")

with fixture(lid="open") as f:
    empty = packet(reasons=[])
    empty.update(expiry=None)
    empty.pop("lidPermit")
    r = attach(f, empty)
    assert not r["status"]["ownsOverride"] and sleeps(f) == 0, r
    r = f.ok("sleep")
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["kind"] == "user" and end["phase"] == "consumed" and end["outcome"] == "commandAccepted", r
    assert sleeps(f) == 1, r
    f.ok("markDiagnostic")
    assert sleeps(f) == 1
    passed(["R3-047", "R3-048"], "an authenticated user Sleep after an empty v3 attachment uses its own end window and requests once")

with fixture(lid="open", sleepDisabled=True) as f:
    lease = packet()
    empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
    before = f.ok("snapshot")
    prep = f.ok("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
    r = f.rpc("attachWorkSession", workSession=lease, epoch=prep["epoch"], revision=prep["revision"])
    assert r["ok"] and not r["status"]["ownsOverride"] and "disablesleep 0" not in f.logs(), r
    assert f.ok("snapshot")["status"]["sleepDisabled"] and sleeps(f) == 0
    passed(["R3-036"], "pre-existing foreign global override is neither claimed nor cleared during executor migration")

with fixture(lid="closed") as f:
    attach(f, packet())
    f.patch(power="battery", manualClock=101, commandNoEffect=True)
    r = f.rpc("markDiagnostic")
    assert r["error"] == "powerVerificationFailed" and r["status"]["ownsOverride"], r
    assert sleeps(f) == 0 and json.loads((f.folder / "power-ownership.json").read_text())["owned"]
    pending = r["workSessionBridge"]["lidEndReceipt"]
    assert pending["phase"] == "captured" and pending["outcome"] == "restoreUnverified", r
    f.patch(commandNoEffect=False, manualClock=106)
    r = f.ok("markDiagnostic")
    end = r["workSessionBridge"]["lidEndReceipt"]
    assert end["id"] == pending["id"] and end["phase"] == "consumed" and end["outcome"] == "commandAccepted", r
    assert not r["status"]["ownsOverride"] and not r["status"]["sleepDisabled"] and sleeps(f) == 1, r
    passed(["R3-035", "R3-036"], "an ineffective restore keeps the end captured until a later verified restore allows its one Sleep")

with fixture(lid="closed") as f:
    attach(f, packet())
    f.patch(thermal=2, finalThermal=0, manualClock=101)
    r = f.ok("markDiagnostic")
    assert sleeps(f) == 0 and r["workSessionBridge"]["lidEndReceipt"]["outcome"] == "cancelled", r
    assert r["workSessionBridge"]["lidProtection"]["reason"] == "thermal", r
    passed(["R3-051"], "cooling before final protective Sleep cancels that call while retaining the protection latch")

with fixture(lid="open") as f:
    attach(f, packet())
    f.stop()
    state_file = f.folder / "helper-state.json"
    state_file.write_bytes(b"{malformed execution journal")
    original = state_file.read_bytes()
    f.start()
    assert state_file.read_bytes() == original and not f.ok("snapshot")["status"]["ownsOverride"]
    lease = packet()
    empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
    before = f.ok("snapshot")
    rejected = f.rpc("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
    assert not rejected["ok"] and state_file.read_bytes() == original, rejected
    assert sleeps(f) == 0
    passed(["R3-036"], "malformed helper execution journal survives relaunch and rejects fresh grants without replacing the original")

with fixture(lid="open") as f:
    f.stop()
    state_file = f.folder / "helper-state.json"
    state_file.write_text(json.dumps(dict(lidExecutionVersion=3, userSessionCoordinated=True, savedBatteryLowPower=0)))
    f.patch(powerModeKey="lowpowermode", batteryPowerMode=1, commandFailure=True)
    f.start()
    lease = packet()
    empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
    before = f.ok("snapshot")
    prep = f.rpc("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
    assert prep["error"] == "pmsetFailed", prep
    r = f.rpc("attachWorkSession", workSession=lease, epoch=prep["epoch"], revision=prep["revision"])
    assert not r["status"]["ownsOverride"] and "disablesleep 1" not in f.logs(), r
    assert r["workSessionBridge"]["coordinated"] and r["status"]["appConnected"], r
    assert json.loads(state_file.read_text())["savedBatteryLowPower"] == 0
    assert r["protection"]["blockReason"] == "powerModeRestoreFailed", r
    passed(["R3-041"], "legacy restore debt retains its value and blocks the global writer while preserving app coordination")

for failure in ["powerSourceObservationAvailable", "lidNotificationAvailable", "thermalObservationAvailable"]:
    with fixture(**{failure: False}) as f:
        lease = packet()
        empty = copy.deepcopy(lease); empty.update(reasons=[], expiry=None); empty.pop("lidPermit")
        before = f.ok("snapshot")
        prep = f.ok("prepareWorkSession", workSession=empty, epoch=before["epoch"], revision=before["revision"])
        r = f.rpc("attachWorkSession", workSession=lease, epoch=prep["epoch"], revision=prep["revision"])
        assert r["error"] == "powerObservationUnavailable" and "disablesleep 1" not in f.logs(), r
    passed(["R3-037"], "missing native observer refuses new lid work: " + failure)

print(json.dumps(dict(passed=len(results), failed=0, results=results,
                     scope="real isolated helper and IPC, fake OS observations and dry-run writes",
                     physical_behavior_proven=False, native_root_execution_proven=False)), flush=True)
