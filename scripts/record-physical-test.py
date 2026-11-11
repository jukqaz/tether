#!/usr/bin/env python3
"""Read-only, bounded development recording for physical Tether tests.

No power settings, assertions, logging preferences or other apps are changed.
Start before the user's operations; STOP/Ctrl-C/deadline finalizes and analyzes.
"""
import argparse
from collections import deque
import copy
import ctypes
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import queue
import re
import selectors
import signal
import stat
import subprocess
import sys
import threading
import time
import uuid

# Importing the saved-log analyzer must not leave extra development files.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = ROOT / ".build/verification/physical-tests"
SUPPORT = Path("/Library/Application Support/Tether")
HELPER_LOG = Path("/Library/Logs/Tether/helper.log")
APP = Path("/Applications/Tether.app")
FORBIDDEN = {"appPath", "holdSource", "executable", "commandLine", "description", "assertionName"}
ERROR_KEYS = {"error", "lastError", "lastApplyError", "lidError"}


def continuous_time():
    # Match TetherCore.ContinuousTime, including time spent asleep on macOS.
    if sys.platform != "darwin":
        return time.monotonic()  # Unit tests only; live recording rejects this OS.
    if not hasattr(continuous_time, "clock"):
        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        lib.mach_continuous_time.restype = ctypes.c_uint64
        value = Timebase()
        if lib.mach_timebase_info(ctypes.byref(value)) != 0 or not value.denom:
            raise RuntimeError("continuousClockUnavailable")
        continuous_time.clock = (lib, value.numer / value.denom / 1e9)
    lib, factor = continuous_time.clock
    return lib.mach_continuous_time() * factor


def scrub(value):
    if isinstance(value, list):
        return [scrub(v) for v in value[:1024]]
    if isinstance(value, str):
        return re.sub(r"(?:/Users|/Volumes|/private/var/folders|/var/folders)/[^\s\"']+", "<private-path>", value)
    if not isinstance(value, dict):
        return value
    result = {}
    for key, item in value.items():
        if key in FORBIDDEN:
            continue
        if key in ERROR_KEYS:
            result[key + "Present"] = item is not None
        else:
            result[key] = scrub(item)
    return result


def decode_json(data):
    def invalid(_):
        raise ValueError("nonFiniteJSON")
    def finite_number(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError("nonFiniteJSON")
        return number
    return json.loads(data, parse_constant=invalid, parse_float=finite_number)


def run(command, timeout=5, limit=1024 * 1024, on_line=None):
    """Drain both pipes with finite storage/deadline; stop only our own child.

    Streaming parsers receive every stdout line. A bounded preview of stdout is
    never confused with truncation of parsed power events.
    """
    began, clock = time.time(), continuous_time()
    result = dict(startedAt=began, startedContinuous=clock, exitCode=None,
                  timedOut=False, truncated=False, outputBytes=0, stderrBytes=0)
    try:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
    except OSError as error:
        result.update(errorClass=type(error).__name__, endedAt=time.time(),
                      endedContinuous=continuous_time(), terminationConfirmed=True)
        return result, b""
    preview, pending = bytearray(), bytearray()
    selector = selectors.DefaultSelector()
    for pipe in (child.stdout, child.stderr):
        os.set_blocking(pipe.fileno(), False)
        selector.register(pipe, selectors.EVENT_READ)
    try:
        while selector.get_map() or child.poll() is None:
            if continuous_time() - clock >= timeout:
                result["timedOut"] = True
                break
            for key, _ in selector.select(.05):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if key.fileobj is child.stderr:
                    result["stderrBytes"] += len(chunk)
                    continue  # Free-form errors may contain private paths.
                result["outputBytes"] += len(chunk)
                remaining = max(0, limit - len(preview))
                preview.extend(chunk[:remaining])
                if on_line is None:
                    result["truncated"] |= len(chunk) > remaining
                else:
                    pending.extend(chunk)
                    while b"\n" in pending:
                        line, _, tail = pending.partition(b"\n")
                        pending = bytearray(tail)
                        on_line(line.decode("utf-8", "replace"))
                    if len(pending) > 65536 or result["outputBytes"] > 64 * 1024 * 1024:
                        result["truncated"] = True
                        break
            if result["truncated"] and on_line is not None:
                break
        if pending and on_line is not None and not result["truncated"]:
            on_line(pending.decode("utf-8", "replace"))
    finally:
        selector.close()
        if child.poll() is None:
            # A collector timeout cannot signal Tether, launchd or another app.
            child.terminate()
            try:
                child.wait(timeout=.3)
            except subprocess.TimeoutExpired:
                child.kill()
        try:
            child.wait(timeout=1)
            result["terminationConfirmed"] = True
        except subprocess.TimeoutExpired:
            result["terminationConfirmed"] = False
        child.stdout.close()
        child.stderr.close()
        result.update(exitCode=child.returncode, endedAt=time.time(),
                      endedContinuous=continuous_time())
    return result, bytes(preview)


def command_json(command):
    query, output = run(command)
    value = None
    if query["exitCode"] == 0 and not query["timedOut"] and not query["truncated"]:
        try:
            value = scrub(decode_json(output))
        except (ValueError, UnicodeError):
            query["errorClass"] = "invalidJSON"
    return dict(available=isinstance(value, dict), query=query,
                value=value if isinstance(value, dict) else None)


def read_file(path, limit=2 * 1024 * 1024):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
            raise ValueError("unsafeOrOversizedFile")
        data = bytearray()
        while len(data) <= limit:
            block = os.read(descriptor, min(65536, limit + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        if len(data) > limit:
            raise ValueError("oversizedFile")
        return bytes(data), info
    finally:
        os.close(descriptor)


def read_json(path):
    try:
        data, info = read_file(path)
        value = scrub(decode_json(data))
        if not isinstance(value, dict):
            raise ValueError("notAnObject")
        return dict(available=True, value=value, modifiedAt=info.st_mtime)
    except (OSError, ValueError, UnicodeError) as error:
        return dict(available=False, value=None, errorClass=type(error).__name__)


def settings():
    try:
        data, info = read_file(Path.home() / "Library/Preferences/io.github.jukqaz.tether.plist")
        value = plistlib.loads(data).get("userOwnedSessionSettings")
        if isinstance(value, bytes):
            value = decode_json(value)
        if not isinstance(value, dict):
            raise ValueError("settingsUnavailable")
        allowed = {"version", "enabled", "automaticEnabled", "automaticSuppressed", "batterySuppressed",
                   "allowClosedLid", "lockOnClose", "powerCondition", "disconnectAction", "limits"}
        return dict(available=True, value={k: scrub(v) for k, v in value.items() if k in allowed},
                    source="storedPreferences", modifiedAt=info.st_mtime)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        return dict(available=False, value=None, errorClass=type(error).__name__)


STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+(\S+)\s+(.*)$")


class PowerParser:
    def __init__(self, since):
        self.since, self.earliest, self.last_stamp = since, None, None
        self.chronological, self.truncated = True, False
        self.events = []

    @property
    def latest(self):
        if not self.last_stamp:
            return None
        try:
            return dt.datetime.strptime(self.last_stamp, "%Y-%m-%d %H:%M:%S %z").timestamp()
        except ValueError:
            self.chronological = False
            return None

    def feed(self, line):
        match = STAMP.match(line)
        if not match:
            return
        if self.last_stamp is not None:
            if match[1][-5:] == self.last_stamp[-5:]:
                self.chronological &= match[1] >= self.last_stamp
            else:
                try:
                    previous = self.latest
                    current = dt.datetime.strptime(match[1], "%Y-%m-%d %H:%M:%S %z").timestamp()
                    self.chronological &= previous is not None and current >= previous
                except ValueError:
                    self.chronological = False
        self.last_stamp = match[1]
        domain, message = match[2], match[3]
        kind = None
        if domain == "Sleep" and message.startswith("Entering Sleep state"):
            kind = "sleep"
        elif domain == "Wake" and (message.startswith("Wake from") or message.startswith("DarkWake to FullWake")):
            kind = "wake"
        elif domain == "DarkWake" and message.startswith("DarkWake from"):
            kind = "darkWake"
        elif domain == "Failure":
            kind = "failure"
        elif domain != "Assertions" and "Display is turned off" in message:
            kind = "displaySleep"
        elif domain != "Assertions" and "Display is turned on" in message:
            kind = "displayWake"
        # Large assertion histories contain private payloads and thousands of
        # repeated timestamps. Parse dates only for the boundary and wanted events.
        if kind is None and self.earliest is not None:
            return
        try:
            at = dt.datetime.strptime(match[1], "%Y-%m-%d %H:%M:%S %z").timestamp()
        except ValueError:
            self.chronological = False
            return
        self.earliest = min(at, self.earliest) if self.earliest is not None else at
        if at < self.since - 1:
            return
        if kind:
            if len(self.events) >= 5000:
                self.truncated = True
                return
            self.events.append(dict(at=at, kind=kind, source="pmset"))


def power_query(since):
    parser = PowerParser(since)
    query, _ = run(["/usr/bin/pmset", "-g", "log"], timeout=8, limit=0, on_line=parser.feed)
    latest = parser.latest
    query.update(source="pmset", earliestAt=parser.earliest, latestAt=latest,
                 chronological=parser.chronological, eventCount=len(parser.events))
    query["truncated"] |= parser.truncated
    return query, parser.events


def assertions(include_names=False):
    query, output = run(["/usr/bin/pmset", "-g", "assertions"], timeout=3)
    valid = query["exitCode"] == 0 and not query["timedOut"] and not query["truncated"]
    text = output.decode("utf-8", "replace")
    counts = {key: int(value) for key, value in re.findall(r"^\s+(\w+)\s+(\d+)\s*$", text, re.M)}
    owners = []
    # Persist only PID/type (optionally the app name), never assertion payload.
    for pid, name, kind in re.findall(r"pid (\d+)\(([^\n]*?)\):[^\n]*?\s(Prevent\w+|No\w+|BackgroundTask|UserIsActive|ExternalMedia|NetworkClientActive)\s+named:", text):
        owner = dict(pid=int(pid), type=kind)
        if include_names:
            owner["name"] = name[:128]
        if owner not in owners:
            owners.append(owner)
    return dict(available=valid and bool(counts), query=query, counts=counts if valid else {},
                owners=owners if valid else [])


FACTS = {"power", "lid", "fullWake", "enabled", "appConnected", "condition", "sleepDisabled", "owned",
         "display", "displaySleeping", "hold", "thermal", "block", "systemPowerObservation", "nativeDisplay",
         "displayRecovery", "displayRequests", "sleepDeferral", "manual", "guiAuthority", "event", "holding",
         "automatic", "automaticEnabled", "manualRemaining", "batteryRemaining", "batteryPercent", "until",
         "batteryUntil", "automaticMinutes", "pendingMinutes", "manualEnd", "canStart", "failed"}


def log_event(line, source):
    # Both allowlisted helper transitions and common-session key/value events are
    # evidence. Do not persist raw stderr, paths, account names or request bodies.
    match = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(\.\d+)?(?:\s?([+-]\d{4}))?\s+(.+)$", line)
    if not match:
        return None
    try:
        if match[3]:
            at = dt.datetime.strptime(match[1] + match[3], "%Y-%m-%d %H:%M:%S%z").timestamp()
        else:
            at = dt.datetime.strptime(match[1], "%Y-%m-%d %H:%M:%S").astimezone().timestamp()
        at += float(match[2] or "0")
    except ValueError:
        return None
    message = match[4]
    fields = {k: v[:80] for k, v in re.findall(r"(\w+)=([A-Za-z0-9_.:-]+)", message) if k in FACTS}
    kinds = [("observed:", "observation"), ("system power: will sleep", "willSleep"),
             ("system power: powered on", "poweredOn"), ("clamshell override released", "overrideReleased"),
             ("power disconnected: clamshell off", "powerReleased"), ("on power: clamshell on", "overrideApplied"),
             ("sleep request refused", "sleepRefused"), ("sleep now requested", "sleepRequested"),
             ("helper stopping", "helperStopping"), ("helper started", "helperStarted"),
             ("watchdog:", "watchdog"), ("event=", "commonActivity")]
    kind = next((kind for needle, kind in kinds if needle in message), None)
    if kind is None:
        return None
    if "error=" in message:
        fields["errorPresent"] = "error=none" not in message
    return dict(at=at, source=source, kind=kind, fields=fields)


def retained_helper_events(since):
    events, availability, total = deque(maxlen=5000), [], 0
    for suffix in (".3", ".2", ".1", ""):
        path = Path(str(HELPER_LOG) + suffix)
        try:
            data, info = read_file(path, limit=8 * 1024 * 1024)
            availability.append(dict(rotation=suffix or "active", available=True, bytes=info.st_size))
            for line in data.decode("utf-8", "replace").splitlines():
                event = log_event(line, "helper")
                if event is not None and event["at"] >= since - 1:
                    events.append(event)
                    total += 1
        except (OSError, ValueError) as error:
            availability.append(dict(rotation=suffix or "active", available=False, errorClass=type(error).__name__))
    return dict(source="helperLogs", queriedAt=time.time(), files=availability,
                eventCount=len(events), truncated=total > len(events)), list(events)


def common_log_events(since):
    events = []
    overflow = False
    def parse(line):
        nonlocal overflow
        event = log_event(line, "common")
        if event is not None and event["at"] >= since - 1:
            if len(events) < 5000:
                events.append(event)
            else:
                overflow = True
    stamp = dt.datetime.fromtimestamp(since).strftime("%Y-%m-%d %H:%M:%S")
    query, _ = run(["/usr/bin/log", "show", "--style", "compact", "--info", "--start", stamp,
                    "--predicate", 'subsystem == "io.github.jukqaz.tether"'], timeout=8, limit=0, on_line=parse)
    query.update(source="commonOSLog", eventCount=len(events))
    query["truncated"] |= overflow
    return query, events


class SessionFiles:
    def __init__(self, directory, maximum_bytes=32 * 1024 * 1024):
        directory.mkdir(parents=True, mode=0o700, exist_ok=False)
        os.chmod(directory, 0o700)
        self.directory, self.maximum_bytes, self.bytes = directory, maximum_bytes, 0
        self.handles = {}
        self.sizes = {}

    def target(self, name):
        if not name or Path(name).name != name or name in (".", ".."):
            raise ValueError("invalidOutputName")
        path = self.directory / name
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if name not in self.sizes or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
                raise ValueError("foreignOutputFile")
        return path

    def append(self, name, value):
        target = self.target(name)
        data = (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode()
        # Leave room to finish the manifest and a bounded analysis after the cap.
        reserve = min(1024 * 1024, self.maximum_bytes // 4)
        if self.bytes + len(data) > self.maximum_bytes - reserve:
            raise OverflowError("sessionSizeLimit")
        if name not in self.handles:
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            self.handles[name] = os.fdopen(fd, "wb")
        self.handles[name].write(data)
        self.handles[name].flush()
        self.bytes += len(data)
        self.sizes[name] = self.sizes.get(name, 0) + len(data)

    def save(self, name, value):
        data = (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode()
        self.save_bytes(name, data)

    def save_bytes(self, name, data):
        target = self.target(name)
        previous = self.sizes.get(name, 0)
        if self.bytes - previous + len(data) > self.maximum_bytes:
            raise OverflowError("sessionSizeLimit")
        temporary = self.directory / ("." + uuid.uuid4().hex)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, target)
            self.bytes = self.bytes - previous + len(data)
            self.sizes[name] = len(data)
        finally:
            temporary.unlink(missing_ok=True)

    def close(self):
        for handle in self.handles.values():
            os.fsync(handle.fileno())
            handle.close()


def helper_files():
    paths = {"helper": "/Library/PrivilegedHelperTools/local.tether.helper",
             "helperRegistration": "/Library/LaunchDaemons/local.tether.helper.plist",
             "watchdog": "/Library/PrivilegedHelperTools/local.tether.watchdog",
             "watchdogRegistration": "/Library/LaunchDaemons/local.tether.watchdog.plist",
             "recoveryLock": "/Library/PrivilegedHelperTools/local.tether.recovery-lock",
             "recoveryExecutor": "/Library/PrivilegedHelperTools/local.tether.power-recovery"}
    result = {}
    for key, path in paths.items():
        try:
            info = os.lstat(path)
            result[key] = dict(present=stat.S_ISREG(info.st_mode), executable=bool(info.st_mode & 0o111))
        except OSError as error:
            result[key] = dict(present=False, errorClass=type(error).__name__)
    return result


def bounded_analysis(report, limit=512 * 1024):
    """Bound duplicate report detail; complete raw evidence remains in JSONL."""
    def size(value):
        return len(json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2).encode())
    if size(report) <= limit:
        return report
    result = copy.deepcopy(report)
    counts = {}
    def bound(parent, name, maximum):
        values = parent.get(name)
        if isinstance(values, list) and len(values) > maximum:
            counts[name] = len(values)
            parent[name] = values[-maximum:]
    observations = result.get("observations", {})
    bound(observations.get("display", {}), "samples", 64)
    for name in ("protection", "timers"):
        bound(observations, name, 64)
    bound(observations.get("otherAppOwners", {}), "candidates", 64)
    bound(result, "timeline", 128)
    bound(result.get("integrity", {}), "gaps", 64)
    for check in result.get("checks", {}).values():
        bound(check, "intervals", 64)
        bound(check, "incidents", 64)
    result["detailStorage"] = dict(limited=True, originalCounts=counts, rawEvidencePreserved=True)
    if size(result) > limit:
        # If a single detail still cannot fit, do not publish a success lacking
        # its report evidence. The hashes let the developer analyze the raw rows.
        result = dict(schemaVersion=1, verdict="unknown", summary="분석 상세가 저장 한도를 초과했습니다. 원본 기록을 보존했으며 별도 분석이 필요합니다.",
                      scope=result.get("scope", {}), analysisEngine=result.get("analysisEngine", {}),
                      integrity=dict(issues=["분석 보고서 저장 한도 초과"], gaps=[], sampleCount=result.get("integrity", {}).get("sampleCount")),
                      checks={}, observations={}, timeline=[], detailStorage=result["detailStorage"])
    return result


def analyze_directory(directory):
    analyzer_path = ROOT / "scripts/physical_test_analysis.py"
    specification = importlib.util.spec_from_file_location("physical_analysis", analyzer_path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    manifest = read_file(directory / "session.json")[0]
    session = decode_json(manifest)
    hashes = {"session.json": hashlib.sha256(manifest).hexdigest()}
    def rows(name):
        path = directory / name
        if not path.exists():
            hashes[name] = None
            return []
        data, _ = read_file(path, limit=32 * 1024 * 1024)
        hashes[name] = hashlib.sha256(data).hexdigest()
        # A terminated writer's partial final line is a collection gap, never a pass.
        lines = data.splitlines(keepends=True)
        result = []
        for line in lines:
            if not line.endswith(b"\n"):
                session["partialFinalLine"] = True
                continue
            try:
                value = decode_json(line)
                if not isinstance(value, dict):
                    raise ValueError("invalidRow")
                result.append(value)
            except (ValueError, UnicodeError):
                # Salvage earlier evidence, but never hide a damaged record as a
                # successful query, a continuous interval or an absent OS event.
                session["invalidJSONLines"] = session.get("invalidJSONLines", 0) + 1
        return result
    report = module.analyze(session, rows("samples.jsonl"), rows("queries.jsonl"), rows("events.jsonl"))
    report["analysisEngine"] = dict(sha256=hashlib.sha256(analyzer_path.read_bytes()).hexdigest(),
                                    inputSHA256=hashes)
    report = bounded_analysis(report)
    files = SessionFiles.__new__(SessionFiles)
    files.directory = directory
    files.maximum_bytes = 33 * 1024 * 1024  # 32 MiB inputs plus bounded final reports.
    files.sizes = {p.name: p.stat().st_size for p in directory.iterdir()
                   if p.is_file() and not p.is_symlink()}
    files.bytes = sum(files.sizes.values())
    files.save("analysis.json", report)
    rendered = module.markdown(report).encode()
    if report.get("detailStorage", {}).get("limited"):
        note = "\n분석 상세 저장을 제한했습니다. 전체 원본은 JSONL에 보존되어 있습니다. 축약 전 상세 개수: "
        rendered += (note + json.dumps(report["detailStorage"].get("originalCounts", {}), ensure_ascii=False) + "\n").encode()
    if len(rendered) > 256 * 1024:
        rendered = "한국어 분석 보고서가 저장 한도를 초과했습니다. analysis.json과 원본 기록으로 판단하며 이 파일을 통과 근거로 사용하지 않습니다.\n".encode()
    files.save_bytes("analysis.ko.md", rendered)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minutes", type=int, default=30, choices=range(1, 241), metavar="1...240")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--app", type=Path, default=APP)
    parser.add_argument("--probe-cli", type=Path)
    parser.add_argument("--include-app-names", action="store_true")
    parser.add_argument("--analyze", type=Path, metavar="SESSION_DIRECTORY")
    args = parser.parse_args()
    if args.analyze:
        directory = args.analyze.resolve()
        if not directory.is_relative_to(OUTPUT_ROOT.resolve()):
            parser.error("Analyze only this repository's recorded physical-test sessions")
        analyze_directory(directory)
        print(str(directory / "analysis.ko.md"))
        return
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.error("Record on macOS as the signed-in user, without sudo")
    if any(key.startswith("TETHER_") for key in os.environ):
        parser.error("Remove TETHER_* fixture overrides before physical recording")
    app = args.app.resolve()
    cli = app / "Contents/Helpers/tether"
    probes = [ROOT / ".build/out/Products/Debug/TetherCLI", ROOT / ".build/debug/TetherCLI", cli]
    probe = args.probe_cli or next((p for p in probes if p.is_file()), cli)
    if not cli.is_file() or not probe.is_file():
        parser.error("A Tether app and a built CLI with diagnose --snapshot-json are required")
    identifier = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    directory = (args.out or OUTPUT_ROOT / identifier).absolute()
    if not directory.resolve().is_relative_to(OUTPUT_ROOT.resolve()):
        parser.error("Keep recordings under .build/verification/physical-tests; never Desktop")
    info = plistlib.loads(read_file(app / "Contents/Info.plist")[0])
    if info.get("CFBundleIdentifier") != "io.github.jukqaz.tether":
        parser.error("Physical recording requires the production Tether app, not Preview")
    files = SessionFiles(directory)
    started, clock = time.time(), continuous_time()
    boot_query, boot = run(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], limit=128)
    boot_id = boot.decode().strip() if boot_query["exitCode"] == 0 else "unknown"
    os_query, os_version = run(["/usr/bin/sw_vers", "-productVersion"], limit=128)
    meta = dict(schemaVersion=1, id=identifier, mode="physical", phase="recording", collectorPID=os.getpid(),
                startedAt=started, startedContinuous=clock, durationSeconds=args.minutes * 60,
                sampleIntervalSeconds=3, maximumGapSeconds=10, appBuild=int(info["CFBundleVersion"]),
                host=dict(bootID=boot_id, osVersion=os_version.decode().strip() if os_query["exitCode"] == 0 else None),
                helperFiles=helper_files(), powerPolicyChanged=False, loggingPolicyChanged=False,
                includeAppNames=args.include_app_names, maximumBytes=files.maximum_bytes,
                collectorSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                probeSHA256=hashlib.sha256(read_file(probe, limit=128 * 1024 * 1024)[0]).hexdigest())
    files.save("session.json", meta)
    stopped = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    seen, results = set(), queue.Queue(maxsize=2)
    worker = None
    cached_assertions = None
    sequence, previous, next_assertions, next_logs = 0, None, 0, 0
    def store_query(query, events):
        files.append("queries.jsonl", query)
        for event in events:
            key = json.dumps(event, sort_keys=True)
            if key not in seen:
                files.append("events.jsonl", event)
                seen.add(key)
    def query_worker():
        try:
            results.put(power_query(started))
        except Exception as error:
            results.put((dict(source="pmset", startedAt=time.time(), endedAt=time.time(),
                              exitCode=None, errorClass=type(error).__name__, timedOut=False,
                              truncated=False, chronological=False, earliestAt=None), []))
    print("RECORDING " + str(directory), flush=True)
    print("Read-only; STOP or Ctrl-C ends recording. No manual timestamps or problem markers needed.", flush=True)
    try:
        while not stopped.is_set() and not (directory / "STOP").exists() and continuous_time() < clock + args.minutes * 60:
            began, now = time.time(), continuous_time()
            if worker is None and now >= next_logs:
                worker = threading.Thread(target=query_worker, daemon=True)
                worker.start()
            while not results.empty():
                store_query(*results.get_nowait())
                worker = None
                next_logs = max(next_logs, now + 60)
            native = command_json([str(probe), "diagnose", "--snapshot-json"])
            common = command_json([str(cli), "status", "--json"])
            value = common.get("value") or {}
            common["value"] = value.get("receipt") if value.get("commonSessionAvailable") is True else None
            common["available"] = isinstance(common["value"], dict)
            if cached_assertions is None or now >= next_assertions:
                cached_assertions = assertions(args.include_app_names)
                next_assertions = continuous_time() + 15
            sequence += 1
            evidence = native.get("value") or {}
            sample = dict(schemaVersion=1, sequence=sequence, capturedAt=began, continuous=now,
                          completedAt=time.time(), completedContinuous=continuous_time(),
                          bootID=evidence.get("bootID", boot_id), evidence=evidence,
                          evidenceQuery=native["query"], common=common,
                          settings=settings(), watchdog=read_json(SUPPORT / "watchdog-status.json"),
                          assertions=cached_assertions)
            if previous is not None and now - previous > meta["maximumGapSeconds"]:
                sample["samplingGapSeconds"] = now - previous
            previous = now
            files.append("samples.jsonl", sample)
            if sequence == 1:
                helper = evidence.get("helper") or {}
                status = helper.get("status") or {}
                meta["preflight"] = dict(appBuild=meta["appBuild"], probeBuild=evidence.get("build"),
                    helperBuild=status.get("build"), closedLidEnabled=(sample["settings"].get("value") or {}).get("allowClosedLid"),
                    helperCoordinatorVersion=status.get("workSessionCoordinatorVersion"),
                    appConnected=status.get("appConnected"), guiSessionAuthority=status.get("guiSessionAuthority"),
                    lidSupport=(common.get("value") or {}).get("lidSupport"),
                    nativeAvailable=native["available"], commonAvailable=common["available"],
                    helperLive=helper.get("source") == "live" and helper.get("available") is True)
                files.save("session.json", meta)
            if sequence == 1 or sequence % 20 == 0:
                store_query(*retained_helper_events(started))
            stopped.wait(max(0, 3 - (continuous_time() - now)))
        meta["stopReason"] = "signal" if stopped.is_set() else "userStop" if (directory / "STOP").exists() else "deadline"
        meta["phase"] = "complete"
    except OverflowError:
        meta.update(phase="limited", stopReason="sessionSizeLimit")
    except Exception as error:
        meta.update(phase="interrupted", stopReason=type(error).__name__)
    finally:
        meta.update(endedAt=time.time(), endedContinuous=continuous_time(), samples=sequence,
                    helperFilesAtEnd=helper_files())
        # Finish after wake if the Mac was asleep at the deadline. Never wake it,
        # restart a timer, alter policies or restart a stopped collection.
        if isinstance(worker, threading.Thread):
            worker.join(timeout=10)
            if worker.is_alive():
                meta["backgroundQueryIncomplete"] = True
        try:
            while not results.empty():
                store_query(*results.get_nowait())
            store_query(*power_query(started))
            store_query(*retained_helper_events(started))
            store_query(*common_log_events(started))
        except OverflowError:
            meta.update(phase="limited", stopReason="sessionSizeLimit")
        except Exception as error:
            meta["finalQueryError"] = type(error).__name__
        files.save("session.json", meta)
        files.close()
        analyze_directory(directory)
        print("FINISHED " + str(directory / "analysis.ko.md"), flush=True)


if __name__ == "__main__":
    main()
