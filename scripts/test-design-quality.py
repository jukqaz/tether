#!/usr/bin/env python3
"""Synthetic regression checks only: no GUI, OS writes or image manipulation."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("design_quality", Path(__file__).with_name("design-quality.py"))
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


def bounds(x=0, y=0, width=300, height=400):
    return {"x": x, "y": y, "width": width, "height": height}


def action(identifier, x, y, width=80, height=24, **metadata):
    return dict(identifier=identifier, elementType="Button", label=identifier,
                valueString="", frame=bounds(x, y, width, height), enabled=True,
                hittable=True, **metadata)


class DesignQualityTests(unittest.TestCase):
    def setUp(self):
        self.capture = {"schemaVersion": 1, "step": "menu", "surface": "MenuBarExtra",
                        "window": {"frame": bounds()}, "elements": [
                            action("panel-start-manual", 20, 20, ancestorIdentifiers=[]),
                            action("settings", 180, 20, ancestorIdentifiers=[]),
                            {"identifier": "title", "elementType": "StaticText", "label": "Keep awake",
                             "valueString": "", "frame": bounds(20, 60, 240, 22),
                             "enabled": True, "hittable": False}],
                        "scrollViews": [{"frame": bounds(10, 10, 260, 350)}]}

    def measure(self, capture=None, recommend=False, native=None):
        return quality.evaluate_capture(capture or self.capture, Path("menu-layout.json"), recommend, native)

    def report(self, captures, recommend=False):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for index, capture in enumerate(captures):
                nested = directory / str(index)
                nested.mkdir()
                (nested / "capture-layout.json").write_text(json.dumps(capture))
            return quality.evaluate_directory(directory, recommend)

    def test_valid_geometry_has_partial_not_final_hundred(self):
        report = self.report([self.capture], recommend=True)
        self.assertEqual(report["status"], "measured")
        self.assertEqual(report["score"]["partialScore"], 100)
        self.assertEqual(report["score"]["totalVerifiedPoints"], 60)
        self.assertEqual(report["coverage"]["weightedPercent"], 60)
        self.assertEqual(report["groups"]["interaction"]["knownWeight"], 0)
        self.assertEqual(report["rubric"]["menuWidthPoints"], 300)
        self.assertEqual(report["rubric"]["menuWidthTolerancePoints"], 1)
        self.assertIn("300±1pt", report["captures"][0]["rules"]["menu_width"]["reason"])
        for rule in ["essential_text_visibility", "rendered_contrast", "keyboard_activation", "pointer_activation"]:
            self.assertEqual(report["captures"][0]["rules"][rule]["status"], "unknown")

    def test_horizontal_control_clipping_is_hard_failure(self):
        self.capture["elements"][0]["frame"] = bounds(330, 20, 80, 24)
        report = self.report([self.capture])
        self.assertEqual(report["status"], "failed")
        self.assertGreater(report["coverage"]["hardFailures"], 0)
        self.assertLess(report["score"]["partialScore"], 100)

    def test_vertical_hittable_control_clipping_is_hard_failure(self):
        self.capture["elements"][0]["frame"] = bounds(20, 390, 80, 24)
        self.assertEqual(self.report([self.capture])["status"], "failed")

    def test_vertical_offscreen_scroll_text_and_control_are_expected(self):
        self.capture["elements"][2]["frame"] = bounds(20, 900, 260, 22)
        self.capture["elements"].append(action("offscreen", 20, 940, ancestorIdentifiers=[]))
        self.capture["elements"][-1]["hittable"] = False
        measured = self.measure()
        self.assertEqual(measured["rules"]["static_text_horizontal_bounds"]["status"], "pass")
        self.assertEqual(measured["rules"]["actionable_window_bounds"]["status"], "pass")
        self.assertFalse(any(f["hardFailure"] for f in measured["findings"]))

    def test_offscreen_hittable_scroll_controls_require_observed_matching_viewport(self):
        offscreen = action("scroll-action", 20, 390, ancestorIdentifiers=[])
        self.capture["elements"].append(offscreen)
        self.assertEqual(self.report([self.capture])["status"], "failed")
        offscreen["observedScrollViewport"] = {
            "queryIndex": 0, "frame": copy.deepcopy(self.capture["scrollViews"][0]["frame"]),
            "relationship": "typed-descendant-exact-match"}
        measured = self.measure()
        self.assertEqual(measured["rules"]["actionable_window_bounds"]["status"], "pass")
        self.assertFalse(any(f["hardFailure"] for f in measured["findings"]))
        # Partial intersection is not an offscreen exclusion, even below 0.5pt.
        for y in (350, 359.75):
            with self.subTest(y=y):
                offscreen["frame"] = bounds(20, y, 80, 80)
                report = self.report([self.capture])
                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["captures"][0]["rules"]["actionable_window_bounds"]["status"], "fail")
        offscreen["frame"] = bounds(20, 390, 80, 24)
        self.capture["elements"] = [offscreen]
        self.assertEqual(self.measure()["rules"]["actionable_window_bounds"]["status"], "unknown")

    def test_forged_or_malformed_scroll_viewport_cannot_make_geometry_pass(self):
        valid = {"queryIndex": 0, "frame": copy.deepcopy(self.capture["scrollViews"][0]["frame"]),
                 "relationship": "typed-descendant-exact-match"}
        invalid = ["unverified", {}, dict(valid, queryIndex=True), dict(valid, queryIndex=-1),
                   dict(valid, queryIndex=1), dict(valid, relationship="inferred-parent"),
                   dict(valid, frame=bounds(10, 10, 279, 350)), dict(valid, frame=bounds(width=0))]
        for observed in invalid:
            with self.subTest(observed=observed):
                capture = copy.deepcopy(self.capture)
                capture["elements"].append(action("scroll-action", 20, 390,
                    ancestorIdentifiers=[], observedScrollViewport=observed))
                report = self.report([capture], recommend=True)
                self.assertEqual(report["status"], "incomplete")
                self.assertTrue(report["captures"][0]["invalidEvidence"])
                self.assertEqual(report["captures"][0]["rules"]["actionable_window_bounds"]["status"], "unknown")
                self.assertEqual(report["score"]["totalVerifiedPoints"], 0)
                self.assertEqual(report["coverage"]["hardFailures"], 0)

    def test_horizontal_static_text_overflow_is_hard_failure(self):
        self.capture["elements"][2]["frame"] = bounds(-10, 900, 400, 22)
        report = self.report([self.capture])
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["captures"][0]["rules"]["static_text_horizontal_bounds"]["status"], "fail")

    def test_confirmed_independent_action_overlap_is_hard_failure(self):
        self.capture["elements"][1]["frame"] = bounds(60, 20, 80, 24)
        report = self.report([self.capture])
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["captures"][0]["rules"]["independent_action_overlap"]["status"], "fail")

    def test_parent_child_and_duplicate_bounds_are_not_collision(self):
        self.capture["elements"] = [action("parent", 20, 20, 200, 100, ancestorIdentifiers=[]),
                                    action("child", 25, 25, ancestorIdentifiers=["parent"]),
                                    action("child", 25, 25, ancestorIdentifiers=["parent"])]
        measured = self.measure()
        self.assertEqual(measured["rules"]["independent_action_overlap"]["status"], "unknown")
        self.assertFalse(any(f["hardFailure"] for f in measured["findings"]))

    def test_composite_bounds_are_excluded(self):
        self.capture["elements"][0]["composite"] = True
        self.capture["elements"][1]["frame"] = bounds(20, 20, 80, 24)
        measured = self.measure()
        self.assertEqual(measured["rules"]["independent_action_overlap"]["status"], "unknown")
        self.assertFalse(any(f["hardFailure"] for f in measured["findings"]))

    def test_missing_ancestry_leaves_overlapping_actions_unknown(self):
        self.capture["elements"][1]["frame"] = bounds(60, 20, 80, 24)
        del self.capture["elements"][0]["ancestorIdentifiers"]
        self.capture["elements"][0]["parentIdentifier"] = None
        report = self.report([self.capture])
        rule = report["captures"][0]["rules"]["independent_action_overlap"]
        self.assertEqual(rule["status"], "unknown")
        self.assertEqual(report["coverage"]["hardFailures"], 0)
        self.assertLess(report["coverage"]["weightedPercent"], 60)

    def test_optional_native_target_recommendation_is_not_hard_gate(self):
        self.capture["elements"][0]["identifier"] = "custom-duration-confirm"
        self.capture["elements"][0]["frame"]["height"] = 18
        self.assertEqual(self.measure()["rules"]["recommended_target_height"]["status"], "unknown")
        report = self.report([self.capture], recommend=True)
        self.assertEqual(report["status"], "measured")
        self.assertEqual(report["captures"][0]["rules"]["recommended_target_height"]["status"], "fail")
        self.assertEqual(report["coverage"]["hardFailures"], 0)

    def test_native_system_controls_are_not_subject_to_optional_target_recommendation(self):
        self.capture["elements"] = [action("close", 10, 10, 16, 16, osStandard=True)]
        measured = self.measure(recommend=True)
        self.assertEqual(measured["rules"]["recommended_target_height"]["status"], "unknown")

    def test_declared_composite_elements_are_excluded_from_collision(self):
        self.capture["compositeElements"] = [copy.deepcopy(self.capture["elements"][0])]
        self.capture["elements"][1]["frame"] = bounds(20, 20, 80, 24)
        self.assertEqual(self.measure()["rules"]["independent_action_overlap"]["status"], "unknown")

    def test_separately_captured_composite_actions_keep_bounds_and_target_checks(self):
        parent = action("panel-start-manual", 340, 10, 80, 18, ancestorIdentifiers=[])
        parent["elementType"] = "MenuButton"
        self.capture["elements"] = []
        self.capture["compositeElements"] = [parent]
        measured = self.measure()
        self.assertEqual(measured["rules"]["actionable_window_bounds"]["status"], "fail")
        self.assertEqual(measured["rules"]["recommended_target_height"]["status"], "fail")
        self.assertEqual(measured["rules"]["independent_action_overlap"]["status"], "unknown")

    def test_native_helper_action_types_are_measured(self):
        for kind in ["Toggle", "MenuButton", "ToolbarButton", "SecureTextField", "TextView", "Link", "Tab"]:
            with self.subTest(kind=kind):
                capture = copy.deepcopy(self.capture)
                capture["elements"][0]["elementType"] = kind
                capture["elements"][0]["frame"] = bounds(340, 10, 80, 24)
                self.assertEqual(self.measure(capture)["rules"]["actionable_window_bounds"]["status"], "fail")

    def test_native_sidebar_rows_and_cells_keep_bounds_and_overlap_checks(self):
        for kind in ["TableRow", "OutlineRow", "Row", "Cell"]:
            with self.subTest(kind=kind):
                capture = copy.deepcopy(self.capture)
                capture["surface"] = "Settings"
                capture["elements"] = [
                    dict(action("settings-tab-general", 20, 20, 160, 30,
                                ancestorIdentifiers=[]), elementType=kind, label="작업 유지"),
                    dict(action("settings-tab-safety", 20, 60, 160, 30,
                                ancestorIdentifiers=[]), elementType=kind, label="기기 보호")]
                self.assertEqual(self.measure(capture)["rules"]["actionable_window_bounds"]["status"], "pass")
                capture["elements"][0]["frame"] = bounds(330, 20, 160, 30)
                self.assertEqual(self.measure(capture)["rules"]["actionable_window_bounds"]["status"], "fail")
                capture["elements"][0]["frame"] = bounds(20, 20, 160, 30)
                capture["elements"][1]["frame"] = bounds(20, 25, 160, 30)
                self.assertEqual(self.measure(capture)["rules"]["independent_action_overlap"]["status"], "fail")

    def test_sidebar_outline_is_not_an_independent_action(self):
        capture = copy.deepcopy(self.capture)
        capture["surface"] = "Settings"
        capture["elements"] = [action("settings-tab-general", 20, 20, 160, 30,
                                       ancestorIdentifiers=[])]
        capture["compositeElements"] = [dict(
            action("settings-navigation", 10, 10, 180, 300, ancestorIdentifiers=[]),
            elementType="Outline", composite=True)]
        self.assertEqual(self.measure(capture)["rules"]["independent_action_overlap"]["status"], "unknown")
        self.assertFalse(any(item["hardFailure"] for item in self.measure(capture)["findings"]))

    def test_compact_menu_width_has_inclusive_one_point_tolerance(self):
        for width, expected in [(299, "pass"), (300, "pass"), (301, "pass"),
                                (298.99, "fail"), (301.01, "fail"), (360, "fail")]:
            with self.subTest(width=width):
                capture = copy.deepcopy(self.capture)
                capture["window"]["frame"]["width"] = width
                self.assertEqual(self.measure(capture)["rules"]["menu_width"]["status"], expected)

    def test_menu_width_rule_does_not_assume_settings_is_menu(self):
        self.capture["window"]["frame"]["width"] = 800
        self.assertEqual(self.measure()["rules"]["menu_width"]["status"], "fail")
        self.capture["surface"] = "Settings"
        self.assertEqual(self.measure()["rules"]["menu_width"]["status"], "unknown")

    def test_invalid_window_frames_cannot_generate_passes(self):
        for invalid in [bounds(width=0), bounds(height=-1), bounds(x=float("nan")), bounds(x=True), {}]:
            with self.subTest(frame=invalid):
                capture = copy.deepcopy(self.capture)
                capture["window"]["frame"] = invalid
                report = self.report([capture])
                self.assertEqual(report["status"], "incomplete")
                self.assertEqual(report["score"]["totalVerifiedPoints"], 0)
                self.assertEqual(report["captures"][0]["rules"]["finite_positive_frames"]["status"], "fail")

    def test_missing_capture_never_inflates_score(self):
        report = self.report([])
        self.assertEqual(report["status"], "incomplete")
        self.assertIsNone(report["score"]["partialScore"])
        self.assertEqual(report["score"]["totalVerifiedPoints"], 0)
        self.assertEqual(report["coverage"]["weightedPercent"], 0)

    def test_invalid_element_frames_do_not_accept_remaining_geometry(self):
        self.capture["elements"][0]["frame"]["width"] = 0
        report = self.report([self.capture])
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["score"]["totalVerifiedPoints"], 0)
        self.assertEqual(report["captures"][0]["rules"]["actionable_window_bounds"]["status"], "unknown")

    def test_unknown_screens_reduce_coverage_without_becoming_passed(self):
        invalid = {"schemaVersion": 999, "step": "unsupported", "surface": "Settings", "elements": []}
        report = self.report([self.capture, invalid], recommend=True)
        self.assertLess(report["score"]["totalVerifiedPoints"], 60)
        self.assertLess(report["coverage"]["weightedPercent"], 60)

    def test_partial_measurement_cannot_award_whole_screen_geometry_or_control_points(self):
        self.capture["measurementCompleteness"] = "partial"
        self.capture["unmeasuredElements"] = [{"identifier": "heading", "elementType": "AXHeading"}]
        report = self.report([self.capture], recommend=True)
        for rule, group, _ in quality.RULES:
            if group in {"geometry", "control"}:
                self.assertEqual(report["captures"][0]["rules"][rule]["status"], "unknown")
        self.assertEqual(report["score"]["totalVerifiedPoints"], 0)
        self.assertEqual(report["score"]["knownWeight"], 0)
        self.assertEqual(report["coverage"]["weightedPercent"], 0)
        self.capture["measurementCompleteness"] = "complete"
        contradictory = self.report([self.capture], recommend=True)
        for rule, group, _ in quality.RULES:
            if group in {"geometry", "control"}:
                self.assertEqual(contradictory["captures"][0]["rules"][rule]["status"], "unknown")
        self.assertEqual(contradictory["score"]["totalVerifiedPoints"], 0)
        self.assertEqual(contradictory["score"]["knownWeight"], 0)
        self.assertEqual(contradictory["coverage"]["weightedPercent"], 0)
        self.capture["elements"][0]["frame"] = bounds(340, 20, 80, 24)
        clipped = self.report([self.capture], recommend=True)
        self.assertEqual(clipped["status"], "failed")
        self.assertEqual(clipped["captures"][0]["rules"]["actionable_window_bounds"]["status"], "fail")
        self.assertGreater(clipped["coverage"]["hardFailures"], 0)
        self.assertEqual(clipped["score"]["totalVerifiedPoints"], 0)

    def test_unreadable_capture_reports_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "broken-layout.json").write_text("not json")
            report = quality.evaluate_directory(directory)
            self.assertEqual(report["status"], "incomplete")
            self.assertEqual(report["score"]["knownWeight"], 0)
            self.assertIsNone(report["score"]["partialScore"])

    def test_native_interaction_requires_clean_result_and_matching_provenance(self):
        native = {"status": "passed", "sourceExecutableSHA256": "a" * 64,
                  "xcodebuild_started": True, "test_execution_started": True,
                  "xcodebuild_returncode": 0, "runtimeWarningCount": 0,
                  "runtimeWarningLogCount": 0, "runtimeWarnings": [],
                  "counts": {"totalTestCount": 9, "passedTests": 9, "failedTests": 0,
                             "skippedTests": 0, "expectedFailures": 0}}
        self.assertEqual(self.measure(native=native)["rules"]["keyboard_activation"]["status"], "unknown")
        self.capture["provenance"] = {"sourceExecutableSHA256": "a" * 64}
        measured = self.measure(native=native)
        self.assertEqual(measured["rules"]["keyboard_activation"]["status"], "pass")
        self.assertEqual(measured["rules"]["pointer_activation"]["status"], "pass")
        self.capture["meta"] = {"provenance": self.capture.pop("provenance")}
        self.assertEqual(self.measure(native=native)["rules"]["keyboard_activation"]["status"], "pass")
        self.capture["meta"]["provenance"]["sourceExecutableSHA256"] = ""
        self.assertEqual(self.measure(native=native)["rules"]["keyboard_activation"]["status"], "unknown")
        self.capture["meta"]["provenance"]["sourceExecutableSHA256"] = "a" * 64
        invalid_results = [dict(native, runtimeWarningCount=1), dict(native, xcodebuild_returncode=65),
                           dict(native, sourceExecutableSHA256="b" * 64), dict(native, status="failed")]
        for field in ["skippedTests", "expectedFailures", "failedTests"]:
            invalid_results.append(dict(native, counts=dict(native["counts"], **{field: 1})))
        invalid_results.append(dict(native, counts=dict(native["counts"], totalTestCount=0, passedTests=0)))
        for invalid in invalid_results:
            with self.subTest(result=invalid):
                self.assertEqual(self.measure(native=invalid)["rules"]["keyboard_activation"]["status"], "unknown")

    def test_window_frame_capture_key_is_supported_and_changed_window_is_unknown(self):
        self.capture["windowFrame"] = self.capture.pop("window")["frame"]
        self.capture["sameWindowFrame"] = True
        self.assertEqual(self.measure()["rules"]["actionable_window_bounds"]["status"], "pass")
        self.capture["sameWindowFrame"] = False
        self.capture["elements"][0]["frame"] = bounds(500, 20, 80, 24)
        measured = self.measure()
        for rule, group, _ in quality.RULES:
            if group in {"geometry", "control"}:
                self.assertEqual(measured["rules"][rule]["status"], "unknown")
        self.assertFalse(any(f["hardFailure"] for f in measured["findings"]))

    def test_text_visibility_requires_matched_screenshot_and_high_confidence_ocr(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            screenshot = directory / "capture.png"
            screenshot.write_bytes(b"\x89PNG\r\n\x1a\nsynthetic screenshot bytes")
            digest = hashlib.sha256(screenshot.read_bytes()).hexdigest()
            evidence_path = directory / "ocr.json"
            evidence = {"source": str(screenshot), "screenshotSHA256": digest,
                        "method": "Apple Vision VNRecognizeTextRequest accurate",
                        "lines": [{"text": "복구 상태를 확인하세요.", "confidence": 0.95}],
                        "absenceProvesClipping": False}
            evidence_path.write_text(json.dumps(evidence))
            self.capture["textChecks"] = [{"id": "recovery-footer", "status": "pass",
                                           "expectedSnippet": "복구상태를 확인하세요",
                                           "screenshotSHA256": digest, "ocrEvidencePath": str(evidence_path),
                                           "method": "derived screenshot audit"}]
            self.assertEqual(self.measure()["rules"]["essential_text_visibility"]["status"], "pass")
            self.capture["textChecks"][0]["expectedSnippet"] = "없는 안내문"
            self.assertEqual(self.measure()["rules"]["essential_text_visibility"]["status"], "unknown")
            self.capture["textChecks"][0]["status"] = "fail"
            self.assertEqual(self.measure()["rules"]["essential_text_visibility"]["status"], "unknown")
            self.capture["textChecks"][0]["visualConfirmedClipping"] = True
            self.assertEqual(self.measure()["rules"]["essential_text_visibility"]["status"], "fail")
            evidence["lines"][0]["confidence"] = 0.2
            evidence_path.write_text(json.dumps(evidence))
            self.assertEqual(self.measure()["rules"]["essential_text_visibility"]["status"], "unknown")
            evidence["lines"][0]["confidence"] = 0.95
            evidence["screenshotSHA256"] = "f" * 64
            evidence_path.write_text(json.dumps(evidence))
            self.assertEqual(self.measure()["rules"]["essential_text_visibility"]["status"], "unknown")

    def test_palette_constants_do_not_accept_measured_contrast(self):
        for scheme, graphite in [("light", [242, 242, 247]), ("dark", [32, 32, 35])]:
            with self.subTest(scheme=scheme):
                self.capture["appearance"] = {"colorScheme": scheme, "palette": "adaptive-graphite"}
                self.capture["measuredColors"] = [{"id": "accent", "method": "sourcePalette",
                    "screenshotSHA256": "a" * 64,
                    "foregroundRGB": [0, 122, 255], "backgroundRGB": graphite}]
                self.assertEqual(self.measure()["rules"]["rendered_contrast"]["status"], "unknown")

    def test_claimed_pixel_colors_with_valid_screenshot_hash_cannot_earn_contrast_points(self):
        with tempfile.TemporaryDirectory() as temporary:
            screenshot = Path(temporary) / "capture.png"
            screenshot.write_bytes(b"\x89PNG\r\n\x1a\nsynthetic screenshot bytes")
            digest = hashlib.sha256(screenshot.read_bytes()).hexdigest()
            self.capture["measuredColors"] = [{
                "id": "body", "method": "screenshot-pixel-sampling", "trusted": True,
                "sourcePaletteOnly": False, "screenshotPath": str(screenshot),
                "screenshotSHA256": digest, "foregroundRGB": [255, 255, 255],
                "backgroundRGB": [0, 0, 0]}]
            rule = self.measure()["rules"]["rendered_contrast"]
            self.assertEqual(rule["status"], "unknown")
            self.assertIn("no pixel-sampling backend", rule["reason"])
            report = self.report([self.capture], recommend=True)
            self.assertEqual(report["groups"]["readability"]["knownWeight"], 0)
            self.assertEqual(report["score"]["totalVerifiedPoints"], 60)


if __name__ == "__main__":
    unittest.main()
