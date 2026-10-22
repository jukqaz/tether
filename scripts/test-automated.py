#!/usr/bin/env python3
"""Run reproducible local/CI gates; never install Tether or request real Sleep.

Helper, installer and update tests use isolated fixtures. Native idle assertions
are finite and belong only to unprivileged test children. Physical lid, lock,
authenticated remote input and administrator installation remain separate gates.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
INTEGRATIONS = (
    "power-writers", "writer-gate", "gui-writer", "writer-guards",
    "recovery-lock", "recovery-executor", "update-feed", "release-preflight",
    "platform", "service", "work-session", "manual-sessions", "conflicts",
    "coordination", "remote-display", "display-observation", "power-observation",
    "native-handoff", "session-handoff", "gui-session", "lifecycle", "power-fixes",
    "capability-routing", "final-scope", "uninstall", "upgrade",
    "physical-recorder", "physical-analysis", "physical-probe", "physical-roundtrip",
)
PREVIOUS_CASES = (
    "actual-previous-off-success", "actual-previous-active-success",
    "actual-previous-detach-success", "actual-previous-watchdog-failure",
    "actual-previous-active-watchdog-failure", "actual-previous-bootstrap-failure",
    "actual-previous-paused-stop",
    "actual-previous-missing-daemon-success", "actual-previous-missing-daemon-watchdog-failure",
    "actual-previous-missing-daemon-bootstrap-failure",
)


def source_hashes():
    paths = [ROOT / "Package.swift", ROOT / "Package.resolved"]
    for directory in ("Sources", "Resources", "scripts", "Tests"):
        paths.extend(p for p in (ROOT / directory).rglob("*")
                     if p.is_file() and "__pycache__" not in p.parts)
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--native-expiry", action="store_true", help="Observe the production driver's explicit 30-second OS health lease (separate native timing gate)")
    parser.add_argument("--sparkle-cli", type=Path)
    parser.add_argument("--sparkle-tools", type=Path)
    parser.add_argument("--previous-helper", action="append", default=[], metavar="BUILD:PATH")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Run as an unprivileged user; the suite never needs sudo")
    if bool(args.sparkle_cli) != bool(args.sparkle_tools):
        parser.error("Supply both --sparkle-cli and --sparkle-tools")
    if args.sparkle_cli and (not args.sparkle_cli.is_file() or not args.sparkle_tools.is_dir()):
        parser.error("Sparkle requires an existing CLI binary and tools directory")
    previous_helpers = []
    for previous in args.previous_helper:
        if ":" not in previous:
            parser.error("--previous-helper requires BUILD:existing-binary-path")
        build, path = previous.split(":", 1)
        if not build.isdecimal() or not Path(path).is_file():
            parser.error("--previous-helper requires BUILD:existing-binary-path")
        if any(prior_build == build for prior_build, _ in previous_helpers):
            parser.error("Supply each previous helper build once")
        previous_helpers.append((build, str(Path(path).resolve())))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.out or ROOT / ".build/verification" / f"automated-{stamp}").resolve()
    if not output.is_relative_to((ROOT / ".build/verification").resolve()):
        parser.error("Keep test artifacts under this repository's .build/verification")
    output.mkdir(parents=True, exist_ok=False)
    before = source_hashes()
    results = []
    completed = False
    env = dict(os.environ, PYTHONUNBUFFERED="1", TETHER_RUN_LIVE_ASSERTION_TESTS="1")
    for name in ("PYTHONOPTIMIZE", "TETHER_TEST_HELPER", "TETHER_TEST_RECOVERY",
                 "TETHER_TEST_PREVIOUS_HELPER", "TETHER_TEST_PREVIOUS_BUILD",
                 "TETHER_INSTALL_TEST_CASES", "TETHER_TEST_CLI_EXECUTABLE"):
        env.pop(name, None)

    def save():
        after = source_hashes()
        changed = [name for name in sorted(before.keys() | after.keys())
                   if before.get(name) != after.get(name)]
        summary = dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       steps=results, sourceInputs=before, sourceChangedDuringRun=changed,
                       completed=completed,
                       passed=completed and bool(results) and all(r["exit"] == r["expected"] for r in results) and not changed,
                       physicalSleepProven=False, authenticatedRemoteProven=False,
                       administratorInstallProven=False, liveAppInstalled=False,
                       optionalGatesNotRun=[name for name, used in
                           [("native-expiry", args.native_expiry),
                            ("native-sparkle", args.sparkle_cli),
                            ("previous-helper-upgrade", args.previous_helper)] if not used])
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")

    def run(name, command, overrides=None, timeout=900, expected=0):
        started = time.monotonic()
        print(f"START {name}", flush=True)
        log = output / f"{name}.log"
        with log.open("w") as handle:
            child = subprocess.Popen(command, cwd=ROOT, env=env | (overrides or {}),
                                     stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = child.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                # Only this command's dedicated process group receives cleanup signals.
                os.killpg(child.pid, signal.SIGCONT)
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                code = 124
        content = log.read_text(errors="replace")
        counts = re.findall(r"Test Suite 'All tests' (?:passed|failed).*?\n\s*Executed (\d+) tests", content)
        skipped = re.findall(r"Test Suite 'All tests' (?:passed|failed).*?\n\s*Executed \d+ tests, with (\d+) tests? skipped", content)
        results.append(dict(name=name, exit=code, expected=expected,
                            seconds=round(time.monotonic() - started, 3), log=log.name,
                            swiftTests=sum(map(int, counts)) if counts else None,
                            swiftSkipped=sum(map(int, skipped)) if counts else None,
                            passedScenarioLines=len(re.findall(r"^PASS\b", content, re.MULTILINE))))
        save()
        print(f"{'PASS' if code == expected else 'FAIL'} {name} ({results[-1]['seconds']}s)", flush=True)
        if code != expected:
            print("\n".join(content.splitlines()[-22:]), flush=True)
        return code == expected

    prerequisites = (
        ("recovery-build", ["swift", "build", "--product", "TetherRecoveryCLI"]),
        ("writer-fixture-build", ["swift", "build", "--product", "TetherWriterFixture"]),
        ("helper-fixture-build", ["swift", "build", "--product", "TetherHelper"]),
        ("cli-fixture-build", ["swift", "build", "--product", "TetherCLI"]),
        ("source-tests", ["swift", "test"]),
        ("package-build", ["/bin/sh", "scripts/build.sh"]),
    )
    for name, command in prerequisites:
        if not run(name, command):
            return 1
    run("ui-native-runner", [sys.executable, "scripts/test-ui-native-runner.py"])
    run("design-quality", [sys.executable, "scripts/test-design-quality.py"])
    run("design-audit-preparation", [sys.executable, "scripts/test-prepare-design-audit.py"])
    for name in INTEGRATIONS:
        run(name, [sys.executable, f"scripts/test-{name}.py"])
    bundle = ROOT / "build/Tether.app"
    helper = bundle / "Contents/Resources/tether-helper"
    cli = bundle / "Contents/Helpers/tether"
    packaged_env = dict(TETHER_TEST_HELPER=str(helper), TETHER_TEST_CLI_EXECUTABLE=str(cli))
    run("packaged-v3-helper", [sys.executable, "scripts/test-redesign-helper.py"], packaged_env)
    run("packaged-v4-helper", [sys.executable, "scripts/test-v4-core-helper.py"], packaged_env)
    run("packaged-app-cli", ["swift", "test", "--filter", "WorkbenchSessionTests|UserSessionCommandTests.testActualCLI|V4CLIIntegrationTests"], packaged_env)
    run("packaged-platform", [sys.executable, "scripts/check-platform.py", str(bundle)])
    run("packaged-signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)])
    private_socket = str(output / "absent-service.sock")
    smoke_env = dict(TETHER_SERVICE_SOCKET=private_socket)
    run("cli-help", [str(cli), "--help"], smoke_env)
    run("cli-battery-cap", [str(cli), "hold", "121m"], smoke_env, expected=2)
    run("cli-retired-extension", [str(cli), "manual", "+1h"], smoke_env, expected=2)
    run("helper-metadata", [str(helper), "--version"])
    if args.native_expiry:
        bins = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, env=env, text=True).strip()
        run("native-expiry", [sys.executable, "scripts/test-idle-lease.py", "--fixture", str(Path(bins) / "TetherWriterFixture"), "--output", str(output / "native-expiry")], timeout=90)
    if args.sparkle_cli:
        run("native-sparkle", [sys.executable, "scripts/test-sparkle-update.py", "--log-dir", str(output / "sparkle")],
            dict(SPARKLE_TEST_CLI=str(args.sparkle_cli.resolve()), SPARKLE_TOOLS_DIR=str(args.sparkle_tools.resolve())))
    for build, path in previous_helpers:
        run(f"upgrade-build-{build}", [sys.executable, "scripts/test-upgrade.py"],
            dict(TETHER_TEST_PREVIOUS_BUILD=build, TETHER_TEST_PREVIOUS_HELPER=path,
                 TETHER_TEST_HELPER=str(helper), TETHER_TEST_RECOVERY=str(bundle / "Contents/Resources/tether-power-recovery"),
                 TETHER_INSTALL_TEST_CASES=",".join(PREVIOUS_CASES)))
    completed = True
    save()
    summary = json.loads((output / "summary.json").read_text())
    print(json.dumps(dict(output=str(output), passed=summary["passed"], steps=len(results)), ensure_ascii=False), flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
