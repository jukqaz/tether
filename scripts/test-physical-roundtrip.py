#!/usr/bin/env python3
"""Saved-log analysis round trips; no live system or app commands are called."""
import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("physical_recorder_roundtrip", Path(__file__).with_name("record-physical-test.py"))
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


class SavedAnalysisTests(unittest.TestCase):
    def analyze(self, rows, queries=b"", events=b""):
        with tempfile.TemporaryDirectory(prefix="tether-physical-analysis-") as temporary:
            directory = Path(temporary) / "session"
            output = recorder.SessionFiles(directory)
            output.save("session.json", {"schemaVersion": 1, "mode": "physical", "phase": "complete"})
            output.save_bytes("samples.jsonl", rows)
            output.save_bytes("queries.jsonl", queries)
            output.save_bytes("events.jsonl", events)
            with mock.patch.object(recorder, "run", side_effect=AssertionError("must not query host")), mock.patch.object(recorder, "settings", side_effect=AssertionError("must not read current settings")):
                report = recorder.analyze_directory(directory)
                second = recorder.analyze_directory(directory)
            self.assertEqual(report, second)
            self.assertEqual(json.loads((directory / "analysis.json").read_text()), report)
            self.assertTrue((directory / "analysis.ko.md").read_text())
            for name in ("analysis.json", "analysis.ko.md"):
                self.assertEqual(stat.S_IMODE((directory / name).stat().st_mode), 0o600)
            return report

    def test_saved_analysis_is_deterministic_private_and_offline(self):
        report = self.analyze(b"{}\n")
        self.assertEqual(report["verdict"], "unknown")
        self.assertEqual(report["integrity"]["sampleCount"], 1)

    def test_corrupt_middle_row_does_not_discard_the_whole_session(self):
        report = self.analyze(b"{}\n{broken}\n{}\n")
        self.assertEqual(report["verdict"], "unknown")
        self.assertEqual(report["integrity"]["sampleCount"], 2)
        self.assertTrue(any("JSON" in text for text in report["integrity"]["issues"]))

    def test_nonobject_and_nonfinite_rows_remain_collection_damage(self):
        report = self.analyze(b"[]\n{\"value\":1e999}\n{}\n")
        self.assertEqual(report["verdict"], "unknown")
        self.assertEqual(report["integrity"]["sampleCount"], 1)
        self.assertTrue(any("JSON" in text for text in report["integrity"]["issues"]))

    def test_partial_final_row_cannot_become_continuous_evidence(self):
        report = self.analyze(b"{}\n{\"sequence\":2")
        self.assertEqual(report["verdict"], "unknown")
        self.assertTrue(report["integrity"]["issues"])

    def test_damaged_query_or_event_rows_are_also_reported(self):
        report = self.analyze(b"{}\n", queries=b"invalid\n", events=b"[1]\n")
        self.assertEqual(report["verdict"], "unknown")
        self.assertTrue(any("JSON" in text for text in report["integrity"]["issues"]))

    def test_retained_helper_limit_is_explicit_and_bounded(self):
        data = b"2026-10-07 00:00:00 observed: power=ac\n" * 5001
        def only_active(path, **_):
            if str(path).endswith("helper.log"):
                return data, SimpleNamespace(st_size=len(data))
            raise FileNotFoundError
        with mock.patch.object(recorder, "read_file", side_effect=only_active):
            query, events = recorder.retained_helper_events(0)
        self.assertTrue(query["truncated"])
        self.assertEqual(query["eventCount"], 5000)
        self.assertEqual(len(events), 5000)

    def test_large_duplicate_analysis_detail_is_bounded_without_editing_inputs(self):
        detail = [{"sequence": i, "batteryPermitReceipts": [{"id": "x" * 150}] * 128} for i in range(100)]
        report = {"verdict": "unknown", "checks": {}, "observations": {"timers": detail}, "timeline": []}
        compact = recorder.bounded_analysis(report)
        self.assertTrue(compact["detailStorage"]["limited"])
        self.assertLessEqual(len(json.dumps(compact, ensure_ascii=False, indent=2).encode()), 512 * 1024)
        self.assertEqual(len(report["observations"]["timers"]), 100)

    def test_single_oversized_detail_never_exports_an_unsubstantiated_pass(self):
        report = {"schemaVersion": 1, "verdict": "pass", "checks": {}, "scope": {}, "integrity": {},
                  "observations": {"timers": [{"unsupportedPayload": "x" * (600 * 1024)}]}, "timeline": []}
        compact = recorder.bounded_analysis(report)
        self.assertEqual(compact["verdict"], "unknown")
        self.assertTrue(compact["detailStorage"]["rawEvidencePreserved"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
