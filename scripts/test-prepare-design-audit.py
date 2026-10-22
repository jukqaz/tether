#!/usr/bin/env python3
"""Synthetic matching/path/provenance regressions; never launches a UI application."""
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("prepare_design_audit", Path(__file__).with_name("prepare-design-audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl7sAAAAASUVORK5CYII=")
FRAME = {"x": 10, "y": 20, "width": 760, "height": 628}


class PrepareDesignAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.attachments = self.root / "attachments"
        self.attachments.mkdir()
        self.output = self.root / "audit"
        self.native = self.root / "result.json"
        self.run = {"status": "passed", "sourceExecutableSHA256": "a" * 64,
                    "fixture_bundle_id": "io.github.jukqaz.tether.ui-tests." + "1" * 32,
                    "fixtureExecutablePath": "/private/fixture/Contents/MacOS/Tether",
                    "fixtureExecutableSHA256": "b" * 64}
        self.native.write_text(json.dumps(self.run))
        self.groups = []

    def tearDown(self):
        self.temp.cleanup()

    def capture(self, step="settings-en-general-screenshot", surface="settings", test="testGeneral", **changes):
        layout = {"schemaVersion": 1, "step": step, "surface": surface, "windowFrame": FRAME,
                  "elements": [{"identifier": "leaf", "elementType": "button", "label": "Start",
                                "valueString": "", "frame": FRAME, "enabled": True, "hittable": True}],
                  "meta": {"provenance": {"fixtureBundleIdentifier": self.run["fixture_bundle_id"],
                            "fixtureExecutablePath": self.run["fixtureExecutablePath"],
                            "sourceExecutableSHA256": "", "testName": f"-[Module.Tests {test}]"}}}
        layout.update(changes)
        index = len(self.groups)
        layout_name, png_name = f"opaque-layout-{index}.json", f"opaque-image-{index}.png"
        layout_path = self.attachments / layout_name
        layout_path.write_text(json.dumps(layout))
        (self.attachments / png_name).write_bytes(PNG)
        common = {"deviceId": "mac", "configurationName": "native", "isAssociatedWithFailure": False}
        group = {"testIdentifier": f"Tests/{test}()", "attachments": [
            {**common, "exportedFileName": layout_name, "timestamp": 101 + index,
             "suggestedHumanReadableName": f"{step}-layout_0_11111111-1111-1111-1111-111111111111.json"},
            {**common, "exportedFileName": png_name, "timestamp": 100 + index,
             "suggestedHumanReadableName": f"{step}_0_22222222-2222-2222-2222-222222222222.png"}]}
        self.groups.append(group)
        return layout, layout_path, group

    def prepare(self, **options):
        (self.attachments / "manifest.json").write_text(json.dumps(self.groups))
        return audit.prepare(self.native, self.attachments, self.output, **options)

    def split_exports(self):
        secondary = self.root / "layout-attachments"
        secondary.mkdir()
        png_groups, layout_groups = [], []
        for group in self.groups:
            png_items, layout_items = [], []
            for item in group["attachments"]:
                if item["exportedFileName"].endswith(".png"):
                    png_items.append(item)
                else:
                    layout_items.append(item)
                    source = self.attachments / item["exportedFileName"]
                    source.rename(secondary / source.name)
            png_groups.append({**group, "attachments": png_items})
            layout_groups.append({**group, "attachments": layout_items})
        self.groups = png_groups
        (secondary / "manifest.json").write_text(json.dumps(layout_groups))
        return secondary

    def test_uuid_layout_detection_exact_join_and_originals_preserved(self):
        layout, source, group = self.capture()
        original = source.read_bytes()
        summary = self.prepare()
        selected = summary["selected"][0]
        prepared = json.loads(Path(selected["layout"]).read_text())
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(Path(selected["screenshot"]).read_bytes(), PNG)
        self.assertEqual(prepared["meta"], layout["meta"])
        proof = prepared["provenance"]
        self.assertEqual(proof["sourceExecutableSHA256"], "a" * 64)
        self.assertEqual(proof["rawLayoutSHA256"], audit.sha256(original))
        self.assertEqual(proof["screenshotSHA256"], audit.sha256(PNG))
        self.assertEqual(proof["nativeResultSHA256"], audit.sha256(self.native.read_bytes()))
        self.assertEqual(proof["manifestTestIdentifier"], group["testIdentifier"])
        self.assertNotIn("textChecks", prepared)
        self.assertNotIn("visualConfirmedClipping", prepared)

    def test_native_sidebar_types_and_adaptive_appearance_are_preserved(self):
        for scheme in ("light", "dark"):
            with self.subTest(scheme=scheme):
                self.groups.clear()
                layout, source, _ = self.capture(
                    elements=[{"identifier": "settings-tab-general", "elementType": "tableRow",
                        "label": "작업 유지", "valueString": "1", "frame": FRAME,
                        "enabled": True, "hittable": True},
                        {"identifier": "settings-tab-safety", "elementType": "outlineRow",
                        "label": "기기 보호", "valueString": "0", "frame": FRAME,
                        "enabled": True, "hittable": True},
                        {"identifier": "settings-tab-system", "elementType": "cell",
                        "label": "앱 설정", "valueString": "0", "frame": FRAME,
                        "enabled": True, "hittable": True}],
                    compositeElements=[{"identifier": "settings-navigation", "elementType": "outline",
                        "label": "설정 페이지", "valueString": "", "frame": FRAME,
                        "enabled": True, "hittable": True, "composite": True}],
                    appearance={"colorScheme": scheme, "palette": "adaptive-graphite", "accent": "blue"})
                original = source.read_bytes()
                # Each subtest gets a separate derived output; raw exports remain intact.
                self.output = self.root / ("audit-" + scheme)
                summary = self.prepare()
                prepared = json.loads(Path(summary["selected"][0]["layout"]).read_text())
                for field in ("elements", "compositeElements", "appearance"):
                    self.assertEqual(prepared[field], layout[field])
                self.assertEqual(source.read_bytes(), original)
                self.assertNotIn("textChecks", prepared)
                self.assertNotIn("measuredColors", prepared)

    def test_wrong_test_step_or_configuration_does_not_match(self):
        for field, value in (("step", "settings-en-general-screenshot-extra"),
                             ("test", "testOther"), ("configurationName", "other")):
            with self.subTest(field=field):
                self.groups.clear()
                _, _, group = self.capture()
                if field == "test":
                    image = group["attachments"].pop()
                    self.groups.append({"testIdentifier": "Tests/testOther()", "attachments": [image]})
                elif field == "step":
                    group["attachments"][1]["suggestedHumanReadableName"] = \
                        value + "_0_22222222-2222-2222-2222-222222222222.png"
                else:
                    group["attachments"][1][field] = value
                with self.assertRaises(audit.AuditError):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_empty_capture_is_rejected_before_output_creation(self):
        self.capture(elements=[])
        with self.assertRaises(audit.AuditError):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_keyboard_layout_text_is_not_mistaken_for_layout_json(self):
        _, _, group = self.capture()
        (self.attachments / "keyboard.txt").write_text("com.apple.keylayout.2SetHangul")
        group["attachments"].append({"exportedFileName": "keyboard.txt",
            "suggestedHumanReadableName": "keyboard-layout_0_11111111-1111-1111-1111-111111111111.txt"})
        self.assertEqual(self.prepare()["coverage"]["captureCount"], 1)

    def test_existing_nonempty_output_is_never_overwritten(self):
        self.capture()
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("keep")
        with self.assertRaises(audit.AuditError):
            self.prepare()
        self.assertEqual(sentinel.read_text(), "keep")

    def test_duplicate_test_step_is_rejected_and_distinct_tests_get_unique_names(self):
        self.capture()
        self.capture()
        with self.assertRaises(audit.AuditError):
            self.prepare()
        self.assertFalse(self.output.exists())
        self.groups.clear()
        self.capture(test="testA")
        self.capture(test="testB")
        summary = self.prepare()
        self.assertEqual(len({item["layout"] for item in summary["selected"]}), 2)

    def test_surface_exclusions_and_exact_include_filter(self):
        self.capture(step="good-screenshot", surface="menu", test="testGood")
        self.capture(step="other-screenshot", test="testOther")
        self.capture(step="launch-en-ac-screenshot", test="testLaunch")
        self.capture(step="failure-screenshot", test="testFailure")
        self.capture(step="missing-button-screenshot", test="testMissing")
        self.capture(step="not-hittable-button-screenshot", test="testHit")
        self.capture(step="landing-screenshot", surface="landing", test="testLanding")
        summary = self.prepare(include_steps=["good-screenshot"])
        self.assertEqual(summary["coverage"]["steps"], ["good-screenshot"])
        self.assertEqual(summary["coverage"]["surfaces"], ["menu"])
        self.assertEqual(len(summary["excluded"]), 6)

    def test_manifest_traversal_and_symlink_are_rejected_even_when_excluded(self):
        for unsafe in ("../outside.json", "/tmp/outside.json", "..\\outside.json"):
            with self.subTest(unsafe=unsafe):
                self.groups.clear()
                _, _, group = self.capture(step="failure-screenshot")
                group["attachments"][0]["exportedFileName"] = unsafe
                with self.assertRaises(audit.AuditError):
                    self.prepare()
        self.groups.clear()
        _, source, _ = self.capture()
        source.unlink()
        source.symlink_to(self.native)
        with self.assertRaises(audit.AuditError):
            self.prepare()

    def test_fixture_and_test_provenance_mismatch_cannot_acquire_source_hash(self):
        for field in ("fixtureBundleIdentifier", "fixtureExecutablePath", "testName", "sourceExecutableSHA256"):
            with self.subTest(field=field):
                self.groups.clear()
                layout, source, _ = self.capture()
                layout["meta"]["provenance"][field] = "wrong"
                source.write_text(json.dumps(layout))
                with self.assertRaises(audit.AuditError):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_ambiguous_png_and_missing_requested_step_fail(self):
        _, _, group = self.capture()
        group["attachments"].append(dict(group["attachments"][1]))
        with self.assertRaises(audit.AuditError):
            self.prepare()
        group["attachments"].pop()
        with self.assertRaises(audit.AuditError):
            self.prepare(include_steps=["settings-en"])

    def test_failed_native_run_is_preserved_without_inferred_pass(self):
        self.capture()
        self.run["status"] = "failed"
        self.native.write_text(json.dumps(self.run))
        summary = self.prepare()
        self.assertEqual(summary["status"], "prepared")
        self.assertEqual(summary["nativeResultStatus"], "failed")
        self.assertIn("testPass", summary["notInferred"])

    def test_ocr_is_hash_bound_without_visual_verdict_and_has_private_destination(self):
        self.capture()
        binary = self.root / "recognizer"
        binary.write_text("placeholder")
        binary.chmod(0o700)
        def recognize(arguments, **kwargs):
            self.assertNotEqual(Path(arguments[2]).parent, self.attachments)
            Path(arguments[2]).write_text(json.dumps({"schemaVersion": 1, "lines": [], "source": arguments[1]}))
            return type("Completed", (), {"returncode": 0, "stderr": ""})()
        with patch.object(audit.subprocess, "run", side_effect=recognize):
            summary = self.prepare(ocr=binary)
        ocr = json.loads(Path(summary["selected"][0]["ocr"]).read_text())
        self.assertEqual(ocr["screenshotSHA256"], audit.sha256(PNG))
        self.assertFalse(ocr["absenceProvesClipping"])
        self.assertNotIn("textChecks", ocr)
        self.assertNotIn("visualConfirmedClipping", ocr)

    def test_separate_exports_preserve_both_manifest_provenance(self):
        self.capture()
        secondary = self.split_exports()
        raw_secondary = (secondary / "manifest.json").read_bytes()
        summary = self.prepare(layout_attachments=secondary)
        self.assertEqual(len(summary["manifests"]), 2)
        proof = summary["selected"][0]["provenance"]
        self.assertEqual(proof["layoutManifestSHA256"], audit.sha256(raw_secondary))
        self.assertEqual(proof["layoutManifestSourcePath"], str(secondary / "manifest.json"))
        self.assertEqual(proof["screenshotManifestSHA256"], audit.sha256((self.attachments / "manifest.json").read_bytes()))
        self.assertEqual(proof["screenshotManifestSourcePath"], str(self.attachments / "manifest.json"))
        self.assertEqual(Path(proof["rawLayoutSourcePath"]).parent, secondary)
        self.assertEqual(Path(proof["screenshotSourcePath"]).parent, self.attachments)
        self.assertEqual((secondary / "manifest.json").read_bytes(), raw_secondary)
        self.assertEqual((self.output / "layout-attachment-manifest.json").read_bytes(), raw_secondary)

    def test_separate_exports_still_require_exact_configuration(self):
        self.capture()
        secondary = self.split_exports()
        self.groups[0]["attachments"][0]["configurationName"] = "different"
        with self.assertRaises(audit.AuditError):
            self.prepare(layout_attachments=secondary)
        self.assertFalse(self.output.exists())

    def test_duplicate_layout_across_separate_exports_is_rejected(self):
        self.capture()
        secondary = self.split_exports()
        manifest_path = secondary / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest[0]["attachments"].append(dict(manifest[0]["attachments"][0]))
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(audit.AuditError):
            self.prepare(layout_attachments=secondary)
        self.assertFalse(self.output.exists())

    def test_secondary_manifest_cannot_escape_its_own_root(self):
        self.capture()
        secondary = self.split_exports()
        manifest_path = secondary / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest[0]["attachments"][0]["exportedFileName"] = "../attachments/opaque-image-0.png"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(audit.AuditError):
            self.prepare(layout_attachments=secondary)


if __name__ == "__main__":
    unittest.main()
