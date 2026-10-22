#!/usr/bin/env python3
"""P0 source/fixture validation. Never install, enable live assertions or request real Sleep."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
# Reviewed fixture-only integrations. Do not inherit future live stages from another runner.
FIXTURES = (
    "power-writers", "writer-gate", "gui-writer", "writer-guards", "recovery-lock",
    "recovery-executor", "service", "work-session", "manual-sessions", "conflicts",
    "coordination", "remote-display", "display-observation", "power-observation",
    "native-handoff", "session-handoff", "gui-session", "lifecycle", "power-fixes",
    "capability-routing", "final-scope", "uninstall", "upgrade", "physical-recorder",
    "physical-analysis", "physical-probe", "physical-roundtrip", "v4-core-helper",
    "redesign-helper", "p0-recovery", "lid-recovery-timers", "ui-native-runner",
    "design-quality", "prepare-design-audit",
)


def inputs():
    files = [ROOT / "Package.swift", ROOT / "Package.resolved"]
    for part in ("Sources", "Tests", "Resources", "scripts"):
        files.extend(p for p in (ROOT / part).rglob("*")
                     if p.is_file() and not p.is_symlink() and "__pycache__" not in p.parts)
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(files) if p.is_file()}


def installed_fingerprint():
    app = Path("/Applications/Tether.app")
    if not app.exists():
        return None
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    return dict(version=info.get("CFBundleShortVersionString"), build=info.get("CFBundleVersion"),
                sha256=hashlib.sha256(binary.read_bytes()).hexdigest())


def source_test_results(body, xml_path):
    if xml_path.exists():
        cases = list(ET.parse(xml_path).getroot().iter("testcase"))
        values = {f"{c.get('classname')}.{c.get('name')}":
                  "skipped" if c.find("skipped") is not None else
                  "failed" if c.find("failure") is not None or c.find("error") is not None else "passed"
                  for c in cases}
        return "xunit", values
    # Xcode's SwiftPM backend can ignore --xunit-output. Keep the canonical
    # terminal XCTest identities and explicit skips instead of inventing an XML.
    values = dict(re.findall(r"Test Case '-\[([^\]]+)\]' (passed|failed|skipped)\s*\(", body))
    return "xctest-log", values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--only", nargs="+", choices=("build", "source-tests", *FIXTURES))
    parser.add_argument("--swift-filter")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Run as an ordinary user")
    out = args.out.resolve()
    if not out.is_relative_to((ROOT / ".build/verification").resolve()):
        parser.error("Output must be under this checkout's .build/verification")
    out.mkdir(parents=True, exist_ok=False)
    before = inputs()
    installed_before = installed_fingerprint()
    steps = []
    products = {}
    env = dict(os.environ, TETHER_RUN_LIVE_ASSERTION_TESTS="0", PYTHONUNBUFFERED="1",
               PYTHONDONTWRITEBYTECODE="1")
    for key in ("TETHER_TEST_HELPER", "TETHER_TEST_RECOVERY", "TETHER_TEST_CLI_EXECUTABLE",
                "TETHER_TEST_PREVIOUS_HELPER", "TETHER_TEST_PREVIOUS_BUILD", "TETHER_INSTALL_TEST_CASES"):
        env.pop(key, None)
    selected = set(args.only or ("build", "source-tests", *FIXTURES))

    def save(completed=False):
        after = inputs()
        changed = [n for n in sorted(before.keys() | after.keys()) if before.get(n) != after.get(n)]
        installed_after = installed_fingerprint()
        summary = dict(recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       sourceRoot=str(ROOT), sourceInputs=before, sourceChangedDuringRun=changed,
                       products=products, steps=steps, completed=completed, swiftFilter=args.swift_filter,
                       passed=completed and bool(steps) and not changed and installed_before == installed_after
                       and all(x["exit"] == 0 for x in steps),
                       installedBefore=installed_before, installedAfter=installed_after,
                       installedUnchanged=installed_before == installed_after,
                       liveAssertionsEnabled=False, installed=False, physicalSleepProven=False,
                       nativeUIExecuted=False, authenticatedRemoteProven=False,
                       omittedStages=[s for s in ("build", "source-tests", *FIXTURES) if s not in selected])
        (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")

    def run(name, command, timeout=900):
        print(f"START {name}", flush=True)
        started = time.monotonic()
        with (out / f"{name}.log").open("w") as log:
            child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = child.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                os.killpg(child.pid, signal.SIGCONT)
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                code = 124
        body = (out / f"{name}.log").read_text(errors="replace")
        step = dict(name=name, command=command, exit=code,
                    seconds=round(time.monotonic() - started, 3), log=f"{name}.log",
                    scenarioPassLines=len(re.findall(r"^PASS\b", body, re.M)))
        if name == "source-tests":
            origin, cases = source_test_results(body, out / "source-tests.xml")
            step.update(testResultSource=origin, tests=len(cases), skipped=sum(v == "skipped" for v in cases.values()),
                        failures=sum(v == "failed" for v in cases.values()))
            (out / "source-test-cases.json").write_text(json.dumps(cases, indent=2) + "\n")
            if code == 0 and not cases:
                code = step["exit"] = 1
        steps.append(step)
        save()
        print(f"{'PASS' if code == 0 else 'FAIL'} {name} ({step['seconds']}s)", flush=True)
        if code:
            print("\n".join(line[:400] for line in body.splitlines()[-16:]), flush=True)
        return code == 0

    if "build" in selected and not run("build", ["swift", "build", "--skip-update"]):
        return 1
    bin_path = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, env=env, text=True).strip()
    for name in ("Tether", "TetherCLI", "TetherHelper", "TetherRecoveryCLI", "TetherWriterFixture"):
        path = Path(bin_path) / name
        if path.is_file():
            products[name] = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    env.update(TETHER_TEST_HELPER=str(Path(bin_path) / "TetherHelper"),
               TETHER_TEST_RECOVERY=str(Path(bin_path) / "TetherRecoveryCLI"),
               TETHER_TEST_CLI_EXECUTABLE=str(Path(bin_path) / "TetherCLI"))
    if "source-tests" in selected:
        command = ["swift", "test", "--skip-update", "--xunit-output", str(out / "source-tests.xml")]
        if args.swift_filter:
            command.extend(["--filter", args.swift_filter])
        if not run("source-tests", command):
            # Fix the identified source failure before running unrelated fixtures.
            # A stopped run stays incomplete; it is never promoted to a full pass.
            return 1
    for name in FIXTURES:
        if name in selected:
            run(name, [sys.executable, f"scripts/test-{name}.py"])
    save(completed=True)
    return 0 if all(s["exit"] == 0 for s in steps) and before == inputs() and installed_before == installed_fingerprint() else 1


if __name__ == "__main__":
    raise SystemExit(main())
