#!/usr/bin/env python3
"""Fixture-only regressions for the development physical-test recorder.

No live recording, power command, app control or privileged operation is run.
All files and all subprocess fixtures belong to a TemporaryDirectory.
"""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


# Loading the recorder must not create an extra repository artifact or run main.
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "tether_physical_recorder_under_test",
    Path(__file__).with_name("record-physical-test.py"),
)
RECORDER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RECORDER
SPEC.loader.exec_module(RECORDER)

UTC = dt.timezone.utc
BASE = dt.datetime(2026, 10, 7, 0, 0, tzinfo=UTC).timestamp()
PRIVATE = "PRIVATE_FIXTURE_PAYLOAD"


def power_line(offset=0, domain="Sleep", message="Entering Sleep state due to 'Clamshell Sleep'", zone=UTC):
    stamp = dt.datetime.fromtimestamp(BASE + offset, zone).strftime("%Y-%m-%d %H:%M:%S %z")
    return f"{stamp} {domain} {message}"


def successful_query(**changes):
    value = dict(exitCode=0, timedOut=False, truncated=False, terminationConfirmed=True)
    value.update(changes)
    return value


class TemporaryTestCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="tether-recorder-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)


class PowerParserTests(unittest.TestCase):
    def test_sleep_requires_actual_sleep_domain_and_transition(self):
        parser = RECORDER.PowerParser(BASE)
        distractors = [
            ("Assertions", "PID 123 created PreventSystemSleep named: " + PRIVATE),
            ("Assertions", "Entering Sleep state requested by command"),
            ("Command", "pmset sleepnow: Entering Sleep state"),
            ("Request", "Entering Sleep state requested"),
            ("Sleep", "Sleep requested but refused"),
            ("Information", "System Sleep prevented by another process"),
        ]
        for offset, (domain, message) in enumerate(distractors):
            parser.feed(power_line(offset, domain, message))
        self.assertEqual(parser.events, [])
        parser.feed(power_line(10))
        self.assertEqual(parser.events, [dict(at=BASE + 10, kind="sleep", source="pmset")])

    def test_wake_darkwake_failure_and_display_are_distinct(self):
        parser = RECORDER.PowerParser(BASE)
        cases = [
            ("Wake", "Wake from Normal Sleep due to EC.LidOpen", "wake"),
            ("Wake", "DarkWake to FullWake from Normal Sleep", "wake"),
            ("DarkWake", "DarkWake from Normal Sleep due to RTC", "darkWake"),
            ("Failure", "Sleep failure: " + PRIVATE, "failure"),
            ("Notification", "Display is turned off", "displaySleep"),
            ("Notification", "Display is turned on", "displayWake"),
        ]
        for offset, (domain, message, _) in enumerate(cases):
            parser.feed(power_line(offset, domain, message))
        self.assertEqual([event["kind"] for event in parser.events], [case[2] for case in cases])
        self.assertEqual([event["at"] for event in parser.events], [BASE + i for i in range(len(cases))])
        self.assertTrue(all(set(event) == {"at", "kind", "source"} for event in parser.events))
        self.assertNotIn(PRIVATE, json.dumps(parser.events))

    def test_assertion_display_payload_is_not_a_display_event(self):
        parser = RECORDER.PowerParser(BASE)
        parser.feed(power_line(0, "Assertions", "named: Display is turned off"))
        parser.feed(power_line(1, "Assertions", "named: Display is turned on"))
        parser.feed(power_line(2, "DarkWake", "DarkWake requested, not resumed"))
        parser.feed(power_line(3, "Wake", "Wake requested, not resumed"))
        self.assertEqual(parser.events, [])

    def test_since_boundary_preserves_coverage_but_excludes_old_events(self):
        parser = RECORDER.PowerParser(BASE)
        for offset in (-600, -2, -1, 0, 1):
            parser.feed(power_line(offset))
        self.assertEqual(parser.earliest, BASE - 600)
        self.assertEqual(parser.latest, BASE + 1)
        self.assertEqual([event["at"] for event in parser.events], [BASE - 1, BASE, BASE + 1])
        self.assertTrue(parser.chronological)

    def test_coverage_can_start_with_assertions_without_a_sleep_event(self):
        parser = RECORDER.PowerParser(BASE)
        parser.feed(power_line(-600, "Assertions", "PreventSystemSleep " + PRIVATE))
        parser.feed(power_line(10, "Assertions", "PreventSystemSleep " + PRIVATE))
        self.assertEqual(parser.earliest, BASE - 600)
        self.assertEqual(parser.latest, BASE + 10)
        self.assertEqual(parser.events, [])

    def test_timezone_offsets_preserve_absolute_order(self):
        parser = RECORDER.PowerParser(BASE)
        for offset, hours in ((0, 9), (0, 0), (1, -7), (2, 9)):
            parser.feed(power_line(offset, zone=dt.timezone(dt.timedelta(hours=hours))))
        self.assertEqual([event["at"] for event in parser.events], [BASE, BASE, BASE + 1, BASE + 2])
        self.assertEqual(parser.earliest, BASE)
        self.assertEqual(parser.latest, BASE + 2)
        self.assertTrue(parser.chronological, "Chronology must compare absolute instants, including equal instants")

    def test_descending_time_is_not_accepted_as_chronological(self):
        parser = RECORDER.PowerParser(BASE)
        for offset in (10, 10, 0):
            parser.feed(power_line(offset))
        self.assertFalse(parser.chronological)
        self.assertEqual(parser.earliest, BASE)

    def test_malformed_timestamp_does_not_break_latest_query(self):
        parser = RECORDER.PowerParser(BASE)
        parser.feed(power_line())
        parser.feed("2026-99-07 00:00:00 +0000 Sleep Entering Sleep state")
        self.assertEqual(len(parser.events), 1)
        # Invalid chronology may preserve the last valid boundary or invalidate
        # it, but must never crash or invent a usable later timestamp.
        self.assertIn(parser.latest, (None, BASE))
        self.assertFalse(parser.chronological)
        parser.feed("not a timestamp Sleep Entering Sleep state")
        self.assertEqual(len(parser.events), 1)

    def test_power_query_marks_invalid_final_timestamp_without_running_pmset(self):
        def stream_fixture(_command, **options):
            options["on_line"](power_line())
            options["on_line"]("2026-99-07 00:00:00 +0000 Sleep Entering Sleep state")
            return successful_query(), b""

        with mock.patch.object(RECORDER, "run", side_effect=stream_fixture):
            query, events = RECORDER.power_query(BASE)
        self.assertFalse(query["chronological"])
        self.assertEqual(query["earliestAt"], BASE)
        self.assertIn(query["latestAt"], (None, BASE))
        self.assertEqual(events, [dict(at=BASE, kind="sleep", source="pmset")])

    def test_event_cap_reports_overflow_without_retaining_payloads(self):
        parser = RECORDER.PowerParser(BASE)
        for offset in range(5000):
            parser.feed(power_line(offset))
        self.assertEqual(len(parser.events), 5000)
        self.assertFalse(parser.truncated)
        parser.feed(power_line(5000, message="Entering Sleep state " + PRIVATE))
        self.assertEqual(len(parser.events), 5000)
        self.assertTrue(parser.truncated)
        self.assertEqual(parser.latest, BASE + 5000)
        self.assertNotIn(PRIVATE, json.dumps(parser.events))


class CommandTests(TemporaryTestCase):
    def setUp(self):
        super().setUp()
        self.children = []
        self.addCleanup(self.stop_fixture_children)

    def stop_fixture_children(self):
        # Only Popen objects created by this test are ever signalled.
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=.3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=1)

    def fixture(self, code, **options):
        command = [sys.executable, "-c", f"import os; os.chdir({str(self.root)!r});\n{code}"]
        original = RECORDER.subprocess.Popen

        def capture(*args, **kwargs):
            child = original(*args, **kwargs)
            self.children.append(child)
            return child

        with mock.patch.object(RECORDER.subprocess, "Popen", side_effect=capture):
            return RECORDER.run(command, **options)

    def assert_fixture_reaped(self):
        self.assertEqual(len(self.children), 1)
        self.assertIsNotNone(self.children[0].poll())
        self.assertTrue(self.children[0].stdout.closed)
        self.assertTrue(self.children[0].stderr.closed)

    def test_stdout_preview_and_stderr_storage_are_bounded(self):
        stdout_bytes, stderr_bytes = 256 * 1024, 192 * 1024
        code = (
            "import sys\n"
            f"sys.stdout.buffer.write(b'O' * {stdout_bytes}); sys.stdout.buffer.flush()\n"
            f"sys.stderr.buffer.write(({PRIVATE!r}.encode() * {stderr_bytes})[:{stderr_bytes}]); "
            "sys.stderr.buffer.flush()\n"
        )
        query, output = self.fixture(code, timeout=3, limit=4096)
        self.assertEqual(output, b"O" * 4096)
        self.assertEqual(query["outputBytes"], stdout_bytes)
        self.assertEqual(query["stderrBytes"], stderr_bytes)
        self.assertEqual(query["exitCode"], 0)
        self.assertTrue(query["truncated"])
        self.assertFalse(query["timedOut"])
        self.assertTrue(query["terminationConfirmed"])
        self.assertNotIn(PRIVATE, json.dumps(query))
        self.assert_fixture_reaped()

    def test_stream_parser_sees_full_lines_and_tail_despite_zero_preview(self):
        lines = []
        query, output = self.fixture(
            "import sys\nsys.stdout.write('first\\nsecond\\nlast-without-newline'); sys.stdout.flush()",
            timeout=3, limit=0, on_line=lines.append,
        )
        self.assertEqual(lines, ["first", "second", "last-without-newline"])
        self.assertEqual(output, b"")
        self.assertFalse(query["truncated"], "No stored preview is distinct from event truncation")
        self.assertFalse(query["timedOut"])
        self.assertEqual(query["exitCode"], 0)
        self.assert_fixture_reaped()

    def test_oversized_unterminated_line_stops_own_child(self):
        lines = []
        query, output = self.fixture(
            "import sys, time\nsys.stdout.buffer.write(b'X' * 524288); sys.stdout.flush(); time.sleep(60)",
            timeout=2, limit=16, on_line=lines.append,
        )
        self.assertEqual(len(output), 16)
        self.assertEqual(lines, [])
        self.assertTrue(query["truncated"])
        self.assertTrue(query["terminationConfirmed"])
        self.assert_fixture_reaped()

    def test_short_timeout_kills_and_reaps_own_signal_resistant_child(self):
        began = time.monotonic()
        query, _ = self.fixture(
            "import signal, sys, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print('ready', flush=True)\ntime.sleep(60)",
            timeout=.25, limit=32,
        )
        self.assertTrue(query["timedOut"])
        self.assertTrue(query["terminationConfirmed"])
        self.assertIsNotNone(query["exitCode"])
        self.assertLess(time.monotonic() - began, 3)
        self.assertGreaterEqual(query["endedContinuous"], query["startedContinuous"])
        self.assert_fixture_reaped()

    def test_callback_error_still_terminates_own_child(self):
        def reject(_):
            raise ValueError("fixture parser rejection")

        with self.assertRaisesRegex(ValueError, "fixture parser rejection"):
            self.fixture("import time\nprint('ready', flush=True)\ntime.sleep(60)",
                         timeout=2, on_line=reject)
        self.assert_fixture_reaped()

    def test_missing_fixture_executable_records_only_error_class(self):
        query, output = RECORDER.run([str(self.root / PRIVATE)], timeout=.2)
        self.assertEqual(output, b"")
        self.assertEqual(query["errorClass"], "FileNotFoundError")
        self.assertTrue(query["terminationConfirmed"])
        self.assertNotIn(PRIVATE, json.dumps(query))


class JSONPrivacyTests(TemporaryTestCase):
    def test_invalid_json_and_nonfinite_numbers_are_rejected(self):
        invalid = [b'{"value":', b'{"value":NaN}', b'{"value":Infinity}',
                   b'{"value":-Infinity}', b'{"nested":[1e999]}', b'{"nested":{"value":-1e999}}', b'\xff']
        for data in invalid:
            with self.subTest(data=data), self.assertRaises((ValueError, UnicodeError)):
                RECORDER.decode_json(data)
        self.assertEqual(RECORDER.decode_json(b'{"value":1.25,"count":3}'), {"value":1.25, "count":3})

    def test_scrub_removes_nested_private_paths_sources_and_freeform_errors(self):
        value = {
            "power": "ac", "owned": True, "sequence": 4,
            "note": f"read /Users/private-fixture/{PRIVATE}/file and /Volumes/private-fixture/{PRIVATE}/data",
            "nested": [{"holdSource": PRIVATE, "error": f"/Users/private-fixture/{PRIVATE}",
                        "lastApplyError": {"message": PRIVATE}, "lidError": None,
                        "appPath": f"/Applications/{PRIVATE}.app", "commandLine": PRIVATE,
                        "description": PRIVATE, "assertionName": PRIVATE, "executable": PRIVATE,
                        "cache": f"/private/var/folders/fixture/{PRIVATE}",
                        "temporary": f"/var/folders/fixture/{PRIVATE}"}],
        }
        clean = RECORDER.scrub(value)
        self.assertEqual((clean["power"], clean["owned"], clean["sequence"]), ("ac", True, 4))
        self.assertEqual(clean["nested"][0]["errorPresent"], True)
        self.assertEqual(clean["nested"][0]["lastApplyErrorPresent"], True)
        self.assertEqual(clean["nested"][0]["lidErrorPresent"], False)
        self.assertNotIn(PRIVATE, json.dumps(clean))
        self.assertNotIn("/Users/", json.dumps(clean))
        self.assertNotIn("/Volumes/", json.dumps(clean))
        self.assertNotIn("holdSource", clean["nested"][0])
        self.assertIn("holdSource", value["nested"][0], "Sanitizing evidence must not mutate its input")

    def test_scrub_caps_nested_lists(self):
        clean = RECORDER.scrub({"samples": [{"sequence": i} for i in range(1200)]})
        self.assertEqual(len(clean["samples"]), 1024)
        self.assertEqual(clean["samples"][-1], {"sequence": 1023})

    def test_read_json_fails_closed_without_private_error_payload(self):
        path = self.root / "snapshot.json"
        for data in (b'{"broken":', b'[]', b'null', b'"string"', b'{"value":NaN}', b'{"value":1e999}', b'\xff'):
            with self.subTest(data=data):
                path.write_bytes(data)
                result = RECORDER.read_json(path)
                self.assertFalse(result["available"])
                self.assertIsNone(result["value"])
                self.assertEqual(set(result), {"available", "value", "errorClass"})
                self.assertNotIn(str(self.root), json.dumps(result))

    def test_read_json_sanitizes_a_valid_object(self):
        path = self.root / "snapshot.json"
        path.write_text(json.dumps({"power": "battery", "holdSource": PRIVATE, "error": PRIVATE}), encoding="utf-8")
        result = RECORDER.read_json(path)
        self.assertTrue(result["available"])
        self.assertEqual(result["value"], {"power": "battery", "errorPresent": True})
        self.assertIsInstance(result["modifiedAt"], float)
        self.assertNotIn(PRIVATE, json.dumps(result))

    def test_command_json_refuses_partial_failed_or_nonobject_results(self):
        variants = [(successful_query(exitCode=1), b'{"valid":true}'),
                    (successful_query(timedOut=True), b'{"valid":true}'),
                    (successful_query(truncated=True), b'{"valid":true}'),
                    (successful_query(), b'[]'), (successful_query(), b'{"value":NaN}'),
                    (successful_query(), b'{"value":1e999}'), (successful_query(), b'{"broken":')]
        for query, data in variants:
            with self.subTest(query=query, data=data), mock.patch.object(RECORDER, "run", return_value=(query, data)):
                result = RECORDER.command_json(["fixture-only"])
                self.assertFalse(result["available"])
                self.assertIsNone(result["value"])

    def test_command_json_keeps_usable_facts_but_not_private_strings(self):
        data = json.dumps({"power": "ac", "note": f"/Users/private-fixture/{PRIVATE}", "holdSource": PRIVATE}).encode()
        with mock.patch.object(RECORDER, "run", return_value=(successful_query(), data)):
            result = RECORDER.command_json(["fixture-only"])
        self.assertTrue(result["available"])
        self.assertEqual(result["value"]["power"], "ac")
        self.assertNotIn(PRIVATE, json.dumps(result))


class InputFileBoundaryTests(TemporaryTestCase):
    def test_regular_single_link_file_is_read_with_stat(self):
        path = self.root / "regular.json"
        path.write_bytes(b'{"power":"ac"}')
        data, info = RECORDER.read_file(path, limit=64)
        self.assertEqual(data, path.read_bytes())
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(info.st_nlink, 1)

    def test_symlink_hardlink_directory_and_fifo_are_refused(self):
        regular = self.root / "regular"
        regular.write_bytes(b"fixture")
        symlink = self.root / "symlink"
        symlink.symlink_to(regular)
        hardlink = self.root / "hardlink"
        os.link(regular, hardlink)
        directory = self.root / "directory"
        directory.mkdir()
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        for path in (symlink, hardlink, regular, directory, fifo):
            with self.subTest(name=path.name), self.assertRaises((OSError, ValueError)):
                RECORDER.read_file(path, limit=64)

    def test_oversized_file_is_refused_before_payload_is_read(self):
        path = self.root / "oversized"
        with path.open("wb") as output:
            output.truncate(65)
        with mock.patch.object(RECORDER.os, "read", side_effect=AssertionError("Oversized input must not be read")):
            with self.assertRaises(ValueError):
                RECORDER.read_file(path, limit=64)


class SessionFileTests(TemporaryTestCase):
    def session(self, maximum_bytes=4096):
        files = RECORDER.SessionFiles(self.root / "session", maximum_bytes=maximum_bytes)
        self.addCleanup(files.close)
        return files

    def test_session_directory_and_outputs_have_private_permissions(self):
        files = self.session()
        files.append("samples.jsonl", {"power": "ac"})
        files.save("session.json", {"phase": "recording"})
        files.save_bytes("analysis.ko.md", "fixture result\n".encode())
        self.assertEqual(stat.S_IMODE(files.directory.stat().st_mode), 0o700)
        for name in ("samples.jsonl", "session.json", "analysis.ko.md"):
            with self.subTest(name=name):
                self.assertEqual(stat.S_IMODE((files.directory / name).stat().st_mode), 0o600)
        self.assertEqual(json.loads((files.directory / "samples.jsonl").read_bytes()), {"power": "ac"})
        self.assertTrue((files.directory / "samples.jsonl").read_bytes().endswith(b"\n"))
        self.assertEqual(sorted(path.name for path in files.directory.iterdir()),
                         ["analysis.ko.md", "samples.jsonl", "session.json"])

    def test_existing_session_directory_is_not_reused(self):
        directory = self.root / "session"
        directory.mkdir()
        sentinel = directory / "keep.txt"
        sentinel.write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            RECORDER.SessionFiles(directory)
        self.assertEqual(sentinel.read_bytes(), b"keep")

    def test_append_cap_reserves_room_for_final_metadata(self):
        value = {"sequence": 1}
        size = len((json.dumps(value, separators=(",", ":")) + "\n").encode())
        files = self.session(maximum_bytes=size * 4)
        for _ in range(3):
            files.append("samples.jsonl", value)
        before = (files.directory / "samples.jsonl").read_bytes()
        with self.assertRaises(OverflowError):
            files.append("samples.jsonl", value)
        self.assertEqual((files.directory / "samples.jsonl").read_bytes(), before)
        self.assertEqual(files.bytes, size * 3)
        files.save_bytes("final.txt", b"F" * size)
        self.assertEqual(files.bytes, files.maximum_bytes)

    def test_save_and_save_bytes_share_total_capacity_with_appends(self):
        files = self.session(maximum_bytes=96)
        files.append("samples.jsonl", {"sequence": 1})
        files.save("session.json", {"ok": True})
        remaining = files.maximum_bytes - files.bytes
        files.save_bytes("end.txt", b"E" * remaining)
        self.assertEqual(files.bytes, 96)
        with self.assertRaises(OverflowError):
            files.save_bytes("too-big.txt", b"!")
        with self.assertRaises(OverflowError):
            files.save("too-big.json", {"too": "big"})
        self.assertFalse((files.directory / "too-big.txt").exists())
        self.assertFalse((files.directory / "too-big.json").exists())
        self.assertEqual(sum(path.stat().st_size for path in files.directory.iterdir()), files.bytes)

    def test_replacing_own_manifest_counts_its_current_size_only(self):
        files = self.session(maximum_bytes=32)
        files.save_bytes("session.json", b"A" * 16)
        files.save_bytes("session.json", b"B" * 32)
        self.assertEqual(files.bytes, 32)
        self.assertEqual((files.directory / "session.json").read_bytes(), b"B" * 32)
        with self.assertRaises(OverflowError):
            files.save_bytes("session.json", b"C" * 33)
        self.assertEqual((files.directory / "session.json").read_bytes(), b"B" * 32)
        self.assertEqual(files.bytes, 32)
        self.assertEqual([path.name for path in files.directory.iterdir()], ["session.json"])

    def test_foreign_files_cannot_be_appended_or_replaced(self):
        files = self.session()
        target = files.directory / "foreign.json"
        target.write_bytes(b"foreign data")
        operations = [lambda: files.append("foreign.json", {}),
                      lambda: files.save("foreign.json", {}),
                      lambda: files.save_bytes("foreign.json", b"replacement")]
        for operation in operations:
            with self.assertRaises((OSError, ValueError)):
                operation()
            self.assertEqual(target.read_bytes(), b"foreign data")
            self.assertEqual(files.bytes, 0)

    def test_output_names_cannot_escape_new_session_directory(self):
        files = self.session()
        sentinel = self.root / "outside.json"
        sentinel.write_bytes(b"outside data")
        for name in ("", ".", "..", "../outside.json", "nested/child.json", str(sentinel)):
            for method in ("append", "save", "save_bytes"):
                with self.subTest(name=name, method=method), self.assertRaises((OSError, ValueError)):
                    getattr(files, method)(name, b"replacement" if method == "save_bytes" else {"new": True})
        self.assertEqual(sentinel.read_bytes(), b"outside data")
        self.assertEqual(list(files.directory.iterdir()), [])
        self.assertEqual(files.bytes, 0)

    def test_replaced_owned_target_symlink_or_hardlink_is_refused(self):
        files = self.session()
        files.save_bytes("session.json", b"owned")
        target = files.directory / "session.json"
        sentinel = self.root / "outside"
        sentinel.write_bytes(b"outside data")
        target.unlink()
        target.symlink_to(sentinel)
        with self.assertRaises((OSError, ValueError)):
            files.save_bytes("session.json", b"replacement")
        self.assertTrue(target.is_symlink())
        target.unlink()
        os.link(sentinel, target)
        with self.assertRaises((OSError, ValueError)):
            files.save_bytes("session.json", b"replacement")
        self.assertEqual(sentinel.read_bytes(), b"outside data")

    def test_nonfinite_output_is_rejected_before_creating_a_file(self):
        files = self.session()
        for number in (float("nan"), float("inf"), float("-inf")):
            for method in ("append", "save"):
                with self.subTest(number=number, method=method), self.assertRaises(ValueError):
                    getattr(files, method)("nonfinite.json", {"value": number})
        self.assertEqual(files.bytes, 0)
        self.assertEqual(list(files.directory.iterdir()), [])

    def test_close_flushes_and_closes_owned_append_handles(self):
        files = RECORDER.SessionFiles(self.root / "session")
        self.addCleanup(lambda: files.close() if any(not handle.closed for handle in files.handles.values()) else None)
        files.append("samples.jsonl", {"sequence": 1})
        files.append("events.jsonl", {"kind": "sleep"})
        files.close()
        self.assertTrue(all(handle.closed for handle in files.handles.values()))
        self.assertEqual(json.loads((files.directory / "events.jsonl").read_bytes()), {"kind": "sleep"})


class HelperAndAssertionTests(unittest.TestCase):
    def test_helper_events_keep_allowlisted_facts_without_raw_payload(self):
        message = (
            "2026-10-07 00:00:00.125+0000 observed: power=ac lid=closed appConnected=true owned=true "
            f"sleepDisabled=true holdSource={PRIVATE} appPath=/Users/private-fixture/{PRIVATE} "
            f"commandLine={PRIVATE} error=/Users/private-fixture/{PRIVATE} note={PRIVATE}"
        )
        result = RECORDER.log_event(message, "helper")
        self.assertEqual(result["at"], BASE + .125)
        self.assertEqual(result["kind"], "observation")
        self.assertEqual(result["source"], "helper")
        self.assertEqual(result["fields"]["power"], "ac")
        self.assertEqual(result["fields"]["lid"], "closed")
        self.assertEqual(result["fields"]["errorPresent"], True)
        self.assertEqual(set(result), {"at", "source", "kind", "fields"})
        self.assertNotIn(PRIVATE, json.dumps(result))
        self.assertNotIn("/Users/", json.dumps(result))

    def test_helper_timestamp_offsets_and_fractional_seconds_are_respected(self):
        for suffix, expected in (("+0000", BASE), ("+0900", BASE - 9 * 3600), ("-0700", BASE + 7 * 3600)):
            with self.subTest(suffix=suffix):
                result = RECORDER.log_event(f"2026-10-07 00:00:00.250 {suffix} helper started", "helper")
                self.assertEqual(result["at"], expected + .25)

    def test_helper_transition_kinds_and_common_session_activity(self):
        cases = [("system power: will sleep", "willSleep"),
                 ("system power: powered on", "poweredOn"),
                 ("clamshell override released", "overrideReleased"),
                 ("power disconnected: clamshell off", "powerReleased"),
                 ("on power: clamshell on", "overrideApplied"),
                 ("sleep request refused", "sleepRefused"),
                 ("sleep now requested", "sleepRequested"),
                 ("helper stopping", "helperStopping"), ("helper started", "helperStarted"),
                 ("watchdog: owned=false", "watchdog"),
                 ("event=manualStarted holding=true manual=true", "commonActivity")]
        for message, kind in cases:
            with self.subTest(kind=kind):
                result = RECORDER.log_event(f"2026-10-07 00:00:00+0000 {message} note={PRIVATE}", "helper")
                self.assertEqual(result["kind"], kind)
                self.assertNotIn(PRIVATE, json.dumps(result))
        self.assertIsNone(RECORDER.log_event(f"2026-10-07 00:00:00+0000 unrelated {PRIVATE}", "helper"))
        self.assertIsNone(RECORDER.log_event("2026-99-07 00:00:00+0000 helper started", "helper"))

    def test_common_log_event_cap_marks_truncation(self):
        def stream_fixture(_command, **options):
            for offset in range(5001):
                stamp = dt.datetime.fromtimestamp(BASE + offset, UTC).strftime("%Y-%m-%d %H:%M:%S%z")
                options["on_line"](f"{stamp} event=sample holding=true note={PRIVATE}")
            return successful_query(), b""

        with mock.patch.object(RECORDER, "run", side_effect=stream_fixture):
            query, events = RECORDER.common_log_events(BASE)
        self.assertEqual(len(events), 5000)
        self.assertEqual(query["eventCount"], 5000)
        self.assertTrue(query["truncated"])
        self.assertNotIn(PRIVATE, json.dumps(events))

    def assertion_fixture(self, **query_changes):
        return (
            successful_query(**query_changes),
            ("Assertion status system-wide:\n   PreventSystemSleep 1\n   PreventUserIdleSystemSleep 1\n"
             f"pid 123(FixtureApp): [0x1] PreventSystemSleep named: \"{PRIVATE}\"\n"
             f"pid 123(FixtureApp): [0x2] PreventSystemSleep named: \"{PRIVATE}\"\n"
             f"pid 456({'L' * 200}): [0x3] PreventUserIdleSystemSleep named: \"{PRIVATE}\"\n").encode(),
        )

    def test_assertion_names_are_opt_in_and_request_payloads_never_retained(self):
        with mock.patch.object(RECORDER, "run", return_value=self.assertion_fixture()):
            result = RECORDER.assertions()
        self.assertTrue(result["available"])
        self.assertEqual(result["counts"], {"PreventSystemSleep": 1, "PreventUserIdleSystemSleep": 1})
        self.assertEqual(result["owners"], [{"pid": 123, "type": "PreventSystemSleep"},
                                            {"pid": 456, "type": "PreventUserIdleSystemSleep"}])
        self.assertNotIn("FixtureApp", json.dumps(result))
        self.assertNotIn(PRIVATE, json.dumps(result))
        with mock.patch.object(RECORDER, "run", return_value=self.assertion_fixture()):
            named = RECORDER.assertions(include_names=True)
        self.assertEqual(named["owners"][0]["name"], "FixtureApp")
        self.assertEqual(len(named["owners"][1]["name"]), 128)
        self.assertNotIn(PRIVATE, json.dumps(named))

    def test_failed_assertion_queries_do_not_expose_partial_owners(self):
        for changes in ({"exitCode": 1}, {"timedOut": True}, {"truncated": True}):
            with self.subTest(changes=changes), mock.patch.object(RECORDER, "run", return_value=self.assertion_fixture(**changes)):
                result = RECORDER.assertions(include_names=True)
                self.assertFalse(result["available"])
                self.assertEqual(result["counts"], {})
                self.assertEqual(result["owners"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
