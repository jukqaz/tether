#!/usr/bin/env python3
"""Regression checks for native UI result acceptance; no external commands or UI."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location("native_ui_runner", Path(__file__).with_name("test-ui-native.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class NativeUIResultTests(unittest.TestCase):
    def setUp(self):
        self.summary = {"result": "Passed", "totalTestCount": 7, "passedTests": 7,
                        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                        "runtimeWarnings": []}

    def test_clean_actual_result_passes(self):
        self.assertEqual(runner.classify(0, self.summary, "** TEST SUCCEEDED **", False)[0], "passed")

    def test_failed_test_or_process_cannot_pass(self):
        with self.subTest("failed test"):
            summary = dict(self.summary, result="Failed", failedTests=1, passedTests=6)
            self.assertEqual(runner.classify(65, summary, "", False)[0], "failed")
        with self.subTest("failed process despite passed summary"):
            self.assertEqual(runner.classify(65, self.summary, "", False)[0], "failed")

    def test_skipped_or_expected_failure_cannot_pass(self):
        for field in ["skippedTests", "expectedFailures"]:
            with self.subTest(field=field):
                summary = dict(self.summary, passedTests=6, **{field: 1})
                self.assertEqual(runner.classify(0, summary, "", False)[0], "failed")

    def test_empty_or_missing_report_cannot_pass(self):
        for summary in [None, dict(self.summary, totalTestCount=0, passedTests=0)]:
            with self.subTest(summary=summary):
                self.assertEqual(runner.classify(0, summary, "** TEST SUCCEEDED **", False)[0], "failed")

    def test_xcresult_runtime_warning_overrides_seven_passed_tests(self):
        warning = {"issueType": "Runtime Warning", "message": "Publishing changes from within view updates is not allowed, this will cause undefined behavior."}
        summary = dict(self.summary, runtimeWarnings=[dict(warning) for _ in range(3)])
        status, reason = runner.classify(0, summary, "** TEST SUCCEEDED **", False)
        self.assertEqual(status, "failed")
        self.assertIn("xcresult=3", reason)
        evidence = runner.runtime_warning_evidence(summary, "")
        self.assertEqual(evidence["runtimeWarningCount"], 3)
        self.assertEqual(evidence["runtimeWarnings"], summary["runtimeWarnings"])
        self.assertEqual(evidence["runtimeWarningLogCount"], 0)

    def test_count_only_runtime_warning_cannot_pass(self):
        summary = dict(self.summary, runtimeWarningCount=2)
        self.assertEqual(runner.classify(0, summary, "", False)[0], "failed")
        self.assertEqual(runner.runtime_warning_evidence(summary, "")["runtimeWarningCount"], 2)

    def test_log_only_view_update_warning_cannot_pass_and_retains_lines(self):
        warning = "[SwiftUI] Publishing changes from within view updates is not allowed, this will cause undefined behavior."
        log = "Test Suite started\n" + warning + "\n" + warning + "\n** TEST SUCCEEDED **\n"
        status, reason = runner.classify(0, self.summary, log, False)
        self.assertEqual(status, "failed")
        self.assertIn("log lines=2", reason)
        evidence = runner.runtime_warning_evidence(self.summary, log)
        self.assertEqual(evidence["runtimeWarningLogCount"], 2)
        self.assertEqual(evidence["runtimeWarningLogEvidence"], [warning, warning])
        self.assertEqual(evidence["runtimeWarningCount"], 0)

    def test_permission_failure_and_timeout_remain_blocked(self):
        self.assertEqual(runner.classify(65, None, "Not authorized for Accessibility", False)[0], "blocked")
        self.assertEqual(runner.classify(-15, None, "", True)[0], "blocked")

    def test_exact_ui_testing_authorization_is_environment_blocker_with_raw_failures(self):
        message = "Failed to load AX for private.fixture: Not authorized for performing UI testing actions."
        failures = [{"failureText": message, "testName": "testExample()"}]
        summary = dict(self.summary, result="Failed", totalTestCount=1, passedTests=0,
                       failedTests=1, testFailures=failures)
        for log in [message, ""]:
            with self.subTest(log=log):
                status, reason = runner.classify(65, summary, log, False)
                self.assertEqual(status, "blocked")
                self.assertIn("macOS denied UI testing actions", reason)
                evidence = runner.ui_testing_authorization_evidence(summary, log)
                self.assertEqual(evidence["uiTestingAuthorizationFailures"], failures)
                self.assertEqual(evidence["otherTestFailures"], [])
                self.assertTrue(runner.test_execution_started(summary, log))
        self.assertEqual(summary["failedTests"], 1)
        self.assertEqual(summary["testFailures"], failures)

    def test_authorization_cannot_conceal_lost_connection_assertion_or_partial_report(self):
        permission = {"failureText": "Not authorized for performing UI testing actions.", "testName": "testDenied()"}
        other_messages = ["Failed to get matching snapshots: Lost connection to the application (pid 123).",
                          "XCTAssertTrue failed - missing duration picker", "Application crashed"]
        for message in other_messages:
            other = {"failureText": message, "testName": "testOther()"}
            summary = dict(self.summary, result="Failed", totalTestCount=2, passedTests=0, failedTests=2,
                           testFailures=[permission, other])
            with self.subTest(message=message):
                self.assertEqual(runner.classify(65, summary, "", False)[0], "failed")
                evidence = runner.ui_testing_authorization_evidence(summary, "")
                self.assertEqual(evidence["uiTestingAuthorizationFailures"], [permission])
                self.assertEqual(evidence["otherTestFailures"], [other])
        all_denied = dict(self.summary, result="Failed", totalTestCount=1, passedTests=0, failedTests=1,
                          testFailures=[permission])
        for candidate in [None, dict(all_denied, failedTests=2), dict(all_denied, testFailures=[])]:
            with self.subTest(summary=candidate):
                self.assertEqual(runner.classify(65, candidate, permission["failureText"], False)[0], "failed")
        for message in other_messages:
            with self.subTest(log=message):
                self.assertEqual(runner.classify(65, all_denied, message, False)[0], "failed")
        warned = dict(all_denied, runtimeWarnings=[{"message": "SwiftUI warning"}])
        self.assertEqual(runner.classify(65, warned, "", False)[0], "failed")

    def test_authentication_runner_failure_is_not_an_executed_ui_test(self):
        failure = "The test runner failed to initialize for UI testing. (Underlying Error: 인증이 취소되었습니다. System authentication is running.)"
        summary = dict(self.summary, result="Failed", totalTestCount=1, passedTests=0, failedTests=1,
                       testFailures=[{"failureText": failure}])
        self.assertEqual(runner.classify(65, summary, failure, False)[0], "blocked")
        self.assertFalse(runner.test_execution_started(summary))
        self.assertEqual(summary["failedTests"], 1, "Retain the raw xcresult count as evidence")

    def test_automation_mode_initialization_timeout_is_blocked_and_retains_raw_failure(self):
        failure = "The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.)"
        summary = dict(self.summary, result="Failed", totalTestCount=1, passedTests=0, failedTests=1,
                       testFailures=[{"failureText": failure}])
        for log in [failure, ""]:
            with self.subTest(log=log):
                self.assertEqual(runner.classify(65, summary, log, False)[0], "blocked")
                self.assertFalse(runner.test_execution_started(summary, log))
        self.assertEqual(summary["totalTestCount"], 1)
        self.assertEqual(summary["failedTests"], 1, "Retain the raw xcresult count as evidence")
        self.assertEqual(summary["testFailures"][0]["failureText"], failure)
        unrelated = dict(summary, testFailures=[{"failureText": "A UI test timed out while enabling automation mode."}])
        self.assertEqual(runner.classify(65, unrelated, "", False)[0], "failed")

    def test_method_start_log_recovers_execution_without_promoting_missing_summary(self):
        log = "Test Case '-[TetherNativeUITests.TetherNativeUITests testActualMenuManualAutomaticAndPauseTransitions]' started.\n"
        self.assertTrue(runner.test_execution_started(None, log))
        self.assertEqual(runner.classify(0, None, log + "** TEST SUCCEEDED **", False)[0], "failed")
        self.assertEqual(runner.classify(-15, None, log, True)[0], "blocked")

    def test_suite_start_and_runner_error_are_not_method_start_evidence(self):
        failure = "The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.)"
        log = ("Test Suite 'TetherNativeUITests' started at 2026-10-12 09:01:03.\n"
               "Test Case 'TetherNativeUITests-Runner (47997) encountered an error' started.\n"
               + failure + "\n")
        self.assertIsNone(runner.test_execution_started(None, log))
        self.assertEqual(runner.classify(65, None, log, False)[0], "blocked")

    def test_runner_failure_after_a_real_test_keeps_execution_evidence(self):
        summary = dict(self.summary, result="Failed", totalTestCount=2, passedTests=1, failedTests=1,
                       testFailures=[{"failureText": "The test runner failed to initialize for UI testing."}])
        self.assertTrue(runner.test_execution_started(summary))
        self.assertTrue(runner.test_execution_started(self.summary))
        self.assertIsNone(runner.test_execution_started(None))

    def test_missing_ui_snapshot_is_a_regression_failure(self):
        summary = dict(self.summary, result="Failed", failedTests=1, passedTests=6)
        for log in ["Failed to get matching snapshot: No matches found for query: Descendants matching type TextField",
                    "No matches found for query: identifier == custom-duration-input",
                    "Failed to establish communication with an app that exited"]:
            with self.subTest(log=log):
                self.assertEqual(runner.classify(65, summary, log, False)[0], "failed")

    def test_only_screenshot_creation_failures_are_blocked_with_raw_execution_evidence(self):
        failure = ("Failed to get screenshot: Failed to create screenshot. Image creation failed. "
                   "Disable automatic screenshots in your test plan's configuration and avoid taking manual screenshots.")
        summary = dict(self.summary, result="Failed", totalTestCount=18, passedTests=0, failedTests=18,
                       testFailures=[{"failureText": failure} for _ in range(18)])
        log = ("Test Case '-[TetherNativeUITests.TetherNativeUITests testLaunch]' started.\n"
               "TetherNativeUITests.swift:901: error: -[TetherNativeUITests.TetherNativeUITests testLaunch] : " + failure)
        for evidence in [log, ""]:
            with self.subTest(log=bool(evidence)):
                self.assertEqual(runner.classify(65, summary, evidence, False)[0], "blocked")
                self.assertTrue(runner.test_execution_started(summary, evidence))
        self.assertEqual(summary["failedTests"], 18)
        self.assertEqual(summary["testFailures"], [{"failureText": failure} for _ in range(18)])

    def test_screenshot_creation_failure_mixed_with_assertion_or_runtime_defect_stays_failed(self):
        failure = "Failed to get screenshot: Failed to create screenshot. Image creation failed."
        summary = dict(self.summary, result="Failed", totalTestCount=2, passedTests=0, failedTests=2,
                       testFailures=[{"failureText": failure}, {"failureText": failure}])
        mixed = dict(summary, testFailures=[{"failureText": failure}, {"failureText": "XCTAssertTrue failed - duration menu missing"}])
        self.assertEqual(runner.classify(65, mixed, "", False)[0], "failed")
        warning = dict(summary, runtimeWarnings=[{"issueType": "Runtime Warning", "message": "A SwiftUI runtime warning"}])
        self.assertEqual(runner.classify(65, warning, "", False)[0], "failed")
        for log in ["TetherNativeUITests.swift:32: error: -[TetherNativeUITests.TetherNativeUITests testLaunch] : XCTAssertTrue failed",
                    "Tether/View.swift:12: Fatal error: invalid state",
                    "[SwiftUI] Publishing changes from within view updates is not allowed",
                    "Main Thread Checker: UI API called on a background thread"]:
            with self.subTest(log=log):
                self.assertEqual(runner.classify(65, summary, log, False)[0], "failed")

    def test_screenshot_log_or_incomplete_report_cannot_prove_capture_only_blocker(self):
        failure = "Failed to get screenshot: Failed to create screenshot. Image creation failed."
        summary = dict(self.summary, result="Failed", totalTestCount=2, passedTests=0, failedTests=2,
                       testFailures=[{"failureText": failure}, {"failureText": failure}])
        for candidate in [None, dict(summary, testFailures=None), dict(summary, testFailures=[]), dict(summary, testFailures=[{"failureText": failure}]),
                          dict(summary, failedTests=1, passedTests=1), dict(summary, skippedTests=1),
                          dict(summary, testFailures=[{"failureText": failure}, {"failureText": "Failed to get matching snapshot"}])]:
            with self.subTest(summary=candidate):
                self.assertEqual(runner.classify(65, candidate, failure, False)[0], "failed")


class NativeUIFixtureIdentityTests(unittest.TestCase):
    def test_every_run_uses_a_new_private_identifier(self):
        first, second = runner.fresh_fixture_bundle_id(), runner.fresh_fixture_bundle_id()
        self.assertNotEqual(first, second)
        for identifier in [first, second]:
            self.assertRegex(identifier, r"^io\.github\.jukqaz\.tether\.ui-tests\.[0-9a-f]{32}$")
            self.assertEqual(runner.require_fixture_bundle_id(identifier), identifier)

    def test_production_or_shared_identifier_is_rejected(self):
        for identifier in [None, "io.github.jukqaz.tether", runner.BUNDLE_ID_PREFIX,
                           runner.BUNDLE_ID_PREFIX + ".1234",
                           runner.BUNDLE_ID_PREFIX + "." + "A" * 32,
                           runner.BUNDLE_ID_PREFIX + "." + "a" * 32 + ".extra"]:
            with self.subTest(identifier=identifier):
                with self.assertRaises(runner.Blocked):
                    runner.require_fixture_bundle_id(identifier)

    def test_clone_and_generated_targets_share_unique_identity_and_exact_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, project = root / "Tether.app", root / "run" / "Project"
            contents = source / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            original_metadata = {"CFBundleIdentifier": "io.github.jukqaz.tether", "CFBundleExecutable": "Tether",
                                 "CFBundleURLTypes": [{"CFBundleURLSchemes": ["tether"]}],
                                 "SUFeedURL": "https://example.invalid/feed", "LSUIElement": True}
            (contents / "Info.plist").write_bytes(plistlib.dumps(original_metadata))
            (contents / "MacOS" / "Tether").write_bytes(b"TetherUIAutomationFixture TETHER_UI_TESTING")
            project.mkdir(parents=True)
            tests = root / "Tests" / "NativeUITests" / "TetherNativeUITests.swift"
            tests.parent.mkdir(parents=True)
            original_tests = ('let bundleID = "io.github.jukqaz.tether.ui-tests"\n'
                              'let expectedExecutablePath = "__TETHER_UI_EXPECTED_EXECUTABLE_PATH__"\n')
            tests.write_text(original_tests)
            identifier = runner.fresh_fixture_bundle_id()
            def copy_app(args, timeout):
                self.assertEqual(args[0], "/usr/bin/ditto")
                shutil.copytree(args[1], args[2])
                return ""
            with mock.patch.object(runner, "command", side_effect=copy_app), mock.patch.object(runner, "ROOT", root):
                executable, metadata, _ = runner.prepare_app(source, project, identifier)
                xcodeproject = runner.write_project(project, executable, metadata)
            cloned = plistlib.loads((project / "Fixture" / "TetherUIFixture.app" / "Contents" / "Info.plist").read_bytes())
            self.assertEqual(cloned["CFBundleIdentifier"], identifier)
            self.assertTrue(cloned["TetherUIAutomationFixture"])
            self.assertFalse(cloned["LSUIElement"])
            self.assertNotIn("CFBundleURLTypes", cloned)
            self.assertNotIn("SUFeedURL", cloned)
            self.assertEqual(plistlib.loads((contents / "Info.plist").read_bytes()), original_metadata)
            generated = (project / "Sources" / tests.name).read_text()
            self.assertIn('let bundleID = "' + identifier + '"', generated)
            expected = project.parent / "DerivedData" / "Build" / "Products" / "Debug" / "TetherUIFixture.app" / "Contents" / "MacOS" / executable
            self.assertIn('let expectedExecutablePath = "' + str(expected) + '"', generated)
            self.assertNotIn("__TETHER_UI_EXPECTED_EXECUTABLE_PATH__", generated)
            self.assertEqual(tests.read_text(), original_tests)
            pbxproj = (xcodeproject / "project.pbxproj").read_text()
            self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "' + identifier + '";', pbxproj)
            self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "' + identifier + '.runner-tests";', pbxproj)

    def test_missing_or_ambiguous_identity_placeholder_cannot_prepare_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tests = root / "Tests" / "NativeUITests" / "TetherNativeUITests.swift"
            tests.parent.mkdir(parents=True)
            project = root / "Project"
            project.mkdir()
            identifier = runner.fresh_fixture_bundle_id()
            for source in ['let bundleID = "io.github.jukqaz.tether.ui-tests"',
                           'let path = "__TETHER_UI_EXPECTED_EXECUTABLE_PATH__"',
                           '"io.github.jukqaz.tether.ui-tests" "io.github.jukqaz.tether.ui-tests" "__TETHER_UI_EXPECTED_EXECUTABLE_PATH__"']:
                with self.subTest(source=source), mock.patch.object(runner, "ROOT", root):
                    tests.write_text(source)
                    with self.assertRaises(runner.Blocked):
                        runner.write_project(project, "Tether", {"CFBundleIdentifier": identifier})
                    self.assertFalse((project / "Sources").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
