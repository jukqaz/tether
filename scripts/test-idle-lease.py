#!/usr/bin/env python3
"""Observe a stopped native idle driver through its actual OS health timeout.

Only this script's unprivileged children receive signals. No global power, display,
lock, installed service or remote application settings are changed.
"""
import argparse
import json
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time

EXPECTED_HEALTH_TTL = 15


def run(fixture, output):
    if os.geteuid() == 0:
        raise RuntimeError("Run this gate as an unprivileged GUI user")
    output.mkdir(parents=True, exist_ok=False)
    samples = []
    child = foreign = None
    lease = None
    last_active = None

    def snapshot():
        result = subprocess.run([str(fixture), "--idle-snapshot"], text=True,
                                capture_output=True, timeout=8, check=True)
        sample = json.loads(result.stdout)
        if sample["queried"] is not True:
            raise RuntimeError("An unavailable query cannot prove expiry")
        samples.append(sample)
        with (output / "samples.jsonl").open("a") as handle:
            handle.write(json.dumps(sample, sort_keys=True) + "\n")
        return sample

    def active(sample, pid):
        return any(item["pid"] == pid and item["kind"] == "system" for item in sample["requests"])

    def cleanup(process):
        if process is not None and process.poll() is None:
            # Resume only the child retained in this live Popen handle, then terminate it.
            process.send_signal(signal.SIGCONT)
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    try:
        child = subprocess.Popen([str(fixture), "--idle-lease-hang"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        selector = selectors.DefaultSelector()
        try:
            selector.register(child.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=10):
                raise RuntimeError("Native driver did not report a confirmed lease")
            line = child.stdout.readline()
        finally:
            selector.close()
        if not line:
            raise RuntimeError("Native driver exited before confirming its lease")
        lease = json.loads(line)
        interval = lease["expiry"] - lease["started"]
        if (lease["pid"] != child.pid or lease["healthTTL"] != EXPECTED_HEALTH_TTL
                or not math.isclose(interval, EXPECTED_HEALTH_TTL, rel_tol=0, abs_tol=1e-6)):
            raise RuntimeError("The reported native lease must belong to the fixture and span exactly "
                               f"{EXPECTED_HEALTH_TTL} seconds")
        (output / "lease.json").write_text(json.dumps(lease, indent=2) + "\n")
        foreign = subprocess.Popen(["/usr/bin/caffeinate", "-i", "-t", str(EXPECTED_HEALTH_TTL + 35)])
        prepared_until = time.monotonic() + 3
        while True:
            sample = snapshot()
            if active(sample, child.pid) and active(sample, foreign.pid):
                break
            if time.monotonic() >= prepared_until:
                raise RuntimeError("Both independent requests were not observed before stopping the child")
            time.sleep(0.05)
        child.send_signal(signal.SIGSTOP)
        print("Native driver stopped; observing its finite OS request", flush=True)
        last_active = sample["continuous"]
        absent = None
        until = time.monotonic() + lease["healthTTL"] + 10
        while time.monotonic() < until:
            if child.poll() is not None or foreign.poll() is not None:
                raise RuntimeError("A process exit cannot stand in for a live child's timeout")
            sample = snapshot()
            if not active(sample, foreign.pid):
                raise RuntimeError("The independent foreign work request disappeared")
            if active(sample, child.pid):
                last_active = sample["continuous"]
            else:
                absent = sample["continuous"]
                break
            # Poll at least once a second, tightening the last three seconds.
            remaining = lease["expiry"] - sample["continuous"]
            time.sleep(min(1, max(0.1, remaining - 3)))
        if absent is None:
            raise RuntimeError("The native request stayed active beyond the observation deadline")
        if last_active < lease["expiry"] - 2:
            raise RuntimeError("No active observation near the actual timeout; timing is unverified")
        report = {"passed": True, "scope": (f"production idle driver with an explicit {EXPECTED_HEALTH_TTL}-second "
                            "health lease and observed OS timeout on this host"),
                  "child_pid": child.pid, "child_alive_at_expiry": child.poll() is None,
                  "foreign_pid": foreign.pid, "foreign_alive_and_active_at_expiry": True,
                  "lease": lease, "last_active": last_active, "first_inactive": absent,
                  "first_inactive_minus_expiry": absent - lease["expiry"],
                  "observation_interval": absent - last_active, "samples": len(samples),
                  "physical_sleep_proven": False, "root_watchdog_bound_proven": False,
                  "macos26_runtime_proven": False}
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, sort_keys=True), flush=True)
    except Exception as error:
        def observed_active(sample, process):
            if process is None:
                return None
            try:
                return active(sample, process.pid)
            except (KeyError, TypeError):
                return None

        failure = {
            "error": str(error),
            "samples": len(samples),
            "lease_expiry": lease.get("expiry") if isinstance(lease, dict) else None,
            "last_active": last_active,
            "recent_samples": [
                {"continuous": sample.get("continuous"),
                 "own_active": observed_active(sample, child),
                 "foreign_active": observed_active(sample, foreign)}
                for sample in samples[-5:]
            ],
        }
        (output / "failure.json").write_text(json.dumps(failure, indent=2) + "\n")
        print(json.dumps({"failure": failure}, sort_keys=True), flush=True)
        raise
    finally:
        cleanup(child)
        cleanup(foreign)
        if child is not None:
            child.stdout.close()
            child.stderr.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.fixture.resolve(strict=True), args.output.resolve())
