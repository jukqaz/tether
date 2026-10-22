#!/usr/bin/env python3
"""Read-only physical evidence CLI contract against an isolated dry-run helper."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from service_fixture import BIN, Fixture

cli = Path(os.environ.get("TETHER_TEST_CLI_EXECUTABLE", BIN / "TetherCLI"))
count = 0


def passed(label):
    global count
    count += 1
    print("PASS physical probe", label, flush=True)


def call(env, *options):
    return subprocess.run([str(cli), "diagnose", "--snapshot-json", *options],
                          env=env, capture_output=True, text=True, timeout=10)


with Fixture(control={"enabled": False, "debugLog": False,
                      "appPath": "/Users/fixture-private/Tether.app",
                      "holdSource": "fixture-private@example.invalid"}) as fixture:
    env = dict(os.environ, TETHER_SERVICE_SOCKET=fixture.sock)
    initial = fixture.ok("snapshot")
    before = initial["control"]
    evidence = call(env)
    assert evidence.returncode == 0, evidence.stderr
    value = json.loads(evidence.stdout)
    assert value["schemaVersion"] == 1 and value["build"] == initial["status"]["build"]
    assert value["simulated"] is True
    helper = value["helper"]
    assert helper["available"] is True and helper["source"] == "live"
    assert helper["protocolVersion"] == 2 and isinstance(helper["epoch"], str)
    assert isinstance(helper["bridge"], dict) and isinstance(helper["revision"], int)
    assert helper["protection"]["dryRun"] is True
    assert helper["status"].get("protection") is None
    passed("actual IPC fields and dry-run identity remain explicit")
    assert value["startedAt"] <= value["observedAt"]
    assert isinstance(value["continuous"], (int, float)) and value["continuous"] > 0
    assert isinstance(value["bootID"], str)
    assert value["native"]["power"] in ("ac", "battery", "unknown")
    assert set(("lidClosed", "sleepDisabled", "fullWake", "displaySleeping", "thermal")) <= set(value["native"])
    assert value["screenLocked"] is None and value["screenLockSource"] == "notCollected"
    passed("native timestamps and lock availability have separate evidence")
    def private_keys(obj):
        if isinstance(obj, list):
            return any(private_keys(item) for item in obj)
        if isinstance(obj, dict):
            return bool(set(obj) & {"appPath", "holdSource", "executable", "commandLine", "error", "lastError", "lastApplyError"}) or any(private_keys(item) for item in obj.values())
        return False
    assert not private_keys(helper)
    assert "fixture-private" not in evidence.stdout
    passed("private paths sources and free-form errors are omitted")
    assert fixture.ok("snapshot")["control"] == before
    assert "IOPMSleepSystem" not in fixture.logs() and "displaysleepnow" not in fixture.logs()
    passed("snapshot does not configure logging or send a sleep/display action")
    for options in (("--record",), ("--record-minutes", "1"), ("--hours", "6"),
                    ("--out", str(fixture.folder / "unexpected.md")), ("--json",)):
        rejected = call(env, *options)
        assert rejected.returncode == 2, (options, rejected.returncode)
    assert not (fixture.folder / "unexpected.md").exists()
    assert fixture.ok("snapshot")["control"] == before
    passed("snapshot rejects every mutating/export option before execution")
    env["TETHER_SERVICE_SOCKET"] = str(fixture.folder / "absent.sock")
    unavailable = call(env)
    assert unavailable.returncode == 0, unavailable.stderr
    fallback = json.loads(unavailable.stdout)
    assert fallback["simulated"] is True
    assert fallback["helper"]["available"] is False
    assert fallback["helper"]["source"] in ("file", "unavailable")
    assert fallback["helper"]["errorPresent"] is True
    passed("stored fallback or missing helper never becomes a live ACK")

with Fixture(control={"enabled": False}, legacy_state=False, manualClock=100, lid="closed") as fixture:
    lease = dict(version=1, executionVersion=3, sessionID=str(uuid.uuid4()), sequence=1,
                 power="ac", expiry=115, reasons=["automatic"],
                 configuration=dict(enabled=True, automaticEnabled=True, condition="ac", automaticMinutes=60,
                                    limits=dict(batteryFloor=30)),
                 lidPermit=dict(powerScopes=["ac"], disconnectAction="sleepIfClosed", protectiveAction="sleepIfClosed"))
    empty = dict(lease, reasons=[], expiry=None)
    empty.pop("lidPermit")
    initial = fixture.ok("snapshot")
    prepared = fixture.ok("prepareWorkSession", workSession=empty, epoch=initial["epoch"], revision=initial["revision"])
    fixture.ok("attachWorkSession", workSession=lease, epoch=prepared["epoch"], revision=prepared["revision"])
    fixture.patch(power="battery", manualClock=101)
    ended = fixture.ok("markDiagnostic")["workSessionBridge"]["lidEndReceipt"]
    assert ended["kind"] == "disconnect" and ended["phase"] == "consumed" and ended["outcome"] == "commandAccepted"
    reply = call(dict(os.environ, TETHER_SERVICE_SOCKET=fixture.sock))
    assert reply.returncode == 0, reply.stderr
    value = json.loads(reply.stdout)
    assert value["simulated"] is True
    assert value["helper"]["status"]["workSessionCoordinatorVersion"] == 10
    assert value["helper"]["bridge"]["lidEndReceipt"] == ended
    passed("actual v3 disconnect receipt survives the private snapshot encoder")

print(f"PASS physical probe {count} scenarios", flush=True)
