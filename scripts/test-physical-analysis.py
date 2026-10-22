#!/usr/bin/env python3
"""Pure, retained-data regressions. No service, shell or host power interaction."""
import copy
import importlib.util
import math
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("physical_test_analysis", Path(__file__).with_name("physical_test_analysis.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)

BOOT = "physical-boot"
WALL = 1000
CLOCK = 10000


def row(sequence, elapsed, power="ac", closed=True, owned=True):
    at = WALL + elapsed
    lease = dict(executionVersion=3, sessionID="work-session", sequence=sequence,
                 power=power, expiry=CLOCK + elapsed + 90, reasons=["automatic"],
                 lidPermit=dict(powerScopes=["ac"]))
    return dict(sequence=sequence, capturedAt=at, continuous=CLOCK + elapsed,
                completedAt=at + .1, completedContinuous=CLOCK + elapsed + .1, bootID=BOOT,
                evidence=dict(build=51, simulated=False, observedAt=at + .05, continuous=CLOCK + elapsed + .05,
                    native=dict(power=power, lidClosed=closed, sleepDisabled=owned, fullWake=True,
                                displaySleeping=None, displayTopology="none", batteryPercent=80, thermal=0),
                    helper=dict(available=True, source="live", status=dict(updatedAt=at + .02, build=51,
                        power=power, fullWake=True,
                        lidClosed=closed, lidObservationAvailable=True, sleepDisabled=owned,
                        sleepOverrideObservationAvailable=True, ownsOverride=owned, appConnected=True,
                        guiSessionAuthority="confirmed", systemPowerObservationAvailable=True,
                        displaySleeping=None,
                        workSessionCoordinatorVersion=7, workSession=lease if owned else None),
                        protection=dict(protocolVersion=2, dryRun=False),
                        bridge=dict(lidEndReceipt=None, sleepConsumption=None, batteryPermitReceipts=[], lidProtection=None))),
                common=dict(available=True, value=dict(version=1, observedAt=at + .07, build=51,
                    epoch="common-epoch", revision=sequence, ok=True, helperConnected=True,
                    lidSupport="active" if owned else "inactive",
                    status=dict(enabled=True, holding=owned, automaticActive=owned, manualActive=False,
                                power=power,
                                blockReason=None, error=None))),
                watchdog=dict(available=True, value=dict(checkedAt=at - 5, boot=BOOT, exitStatus=0)),
                settings=dict(available=True, value=dict(allowClosedLid=True, automaticEnabled=True,
                    powerCondition="ac", disconnectAction="sleepIfClosed", lockOnClose=False)),
                assertions=dict(available=True, owners=[dict(pid=111, type="PreventUserIdleSystemSleep")], counts={}))


def session(rows):
    return dict(schemaVersion=1, mode="physical", phase="complete", startedAt=WALL,
                endedAt=rows[-1]["completedAt"] + 2, startedContinuous=CLOCK,
                endedContinuous=rows[-1]["completedContinuous"] + 2, sampleIntervalSeconds=3,
                maximumGapSeconds=10, appBuild=51, host=dict(bootID=BOOT))


def query(rows, count=0):
    return dict(source="pmset", startedAt=rows[-1]["completedAt"] + 1,
                endedAt=rows[-1]["completedAt"] + 1.5, exitCode=0, timedOut=False,
                truncated=False, earliestAt=WALL - 30, chronological=True, eventCount=count)


def happy_ac():
    rows = [row(index + 1, index * 3) for index in range(29)]
    return session(rows), rows, [query(rows)], []


def unplug(receipt_only=False):
    rows = [row(1, 0), row(2, 3, power="battery", owned=False), row(3, 18, power="battery", closed=False, owned=False)]
    if receipt_only:
        rows[1]["evidence"]["native"]["sleepDisabled"] = None
        rows[1]["evidence"]["helper"]["status"]["ownsOverride"] = None
        rows[1]["evidence"]["helper"]["bridge"]["lidEndReceipt"] = dict(
            id="end-receipt", bootID=BOOT, sessionID="work-session", sequence=1,
            kind="disconnect", observedAt=CLOCK + 3, phase="consumed", outcome="commandAccepted")
    events = [dict(at=WALL + 5, kind="sleep", source="pmset"), dict(at=WALL + 17, kind="wake", source="pmset")]
    return session(rows), rows, [query(rows, 2)], events


def fast_unplug():
    rows = [row(1, 0), row(2, 63, power="battery", closed=False, owned=False)]
    rows[1]["evidence"]["helper"]["bridge"]["lidEndReceipt"] = dict(
        id="fast-end", bootID=BOOT, sessionID="work-session", sequence=1,
        kind="disconnect", action="sleepIfClosed", observedAt=CLOCK + 1,
        phase="consumed", outcome="commandAccepted")
    events = [dict(at=WALL + 2, kind="sleep", source="pmset"), dict(at=WALL + 62, kind="wake", source="pmset")]
    return session(rows), rows, [query(rows, 2)], events


class AnalysisTests(unittest.TestCase):
    def check_unknown(self, fixture, name="acClosedLid"):
        report = analysis.analyze(*fixture)
        self.assertEqual("unknown", report["checks"][name]["verdict"], report)
        self.assertNotEqual("pass", report["verdict"], report)
        return report

    def test_happy_ac_continuous_native_common_helper_os_coverage(self):
        report = analysis.analyze(*happy_ac())
        self.assertEqual("pass", report["verdict"])
        interval = report["checks"]["acClosedLid"]["intervals"][0]
        self.assertEqual("pass", interval["verdict"])
        self.assertEqual(84, interval["durationSeconds"])
        self.assertEqual(0, interval["coverageQuery"])
        self.assertEqual("unknown", report["checks"]["timerProtection"]["verdict"])

    def test_actual_sleep_during_verified_ac_is_failure(self):
        fixture = happy_ac()
        fixture[3].extend([dict(at=WALL + 40, kind="sleep", source="pmset"), dict(at=WALL + 45, kind="wake", source="pmset")])
        fixture[2][0]["eventCount"] = 2
        report = analysis.analyze(*fixture)
        self.assertEqual("fail", report["verdict"])
        self.assertEqual([WALL + 40], report["checks"]["acClosedLid"]["intervals"][0]["sleepEvents"])

    def test_short_or_absent_physical_interval_is_unknown(self):
        self.check_unknown((session([row(1, 0)]), [row(1, 0)], [], []))
        self.check_unknown(({}, [], [], []))

    def test_sample_gap_does_not_prove_sleep_or_continuity(self):
        fixture = happy_ac()
        del fixture[1][8:12]
        result = self.check_unknown(fixture)
        self.assertTrue(result["integrity"]["gaps"])

    def test_missing_sequence_is_unknown_even_when_clocks_are_close(self):
        fixture = happy_ac()
        del fixture[1][12]
        self.check_unknown(fixture)

    def test_stale_or_future_native_common_helper_never_pass(self):
        for origin in ("native", "common", "helper"):
            for difference in (-11, 30):
                with self.subTest(origin=origin, difference=difference):
                    fixture = happy_ac()
                    affected = fixture[1][14]
                    if origin == "native": affected["evidence"]["observedAt"] = affected["completedAt"] + difference
                    elif origin == "common": affected["common"]["value"]["observedAt"] = affected["completedAt"] + difference
                    else: affected["evidence"]["helper"]["status"]["updatedAt"] = affected["completedAt"] + difference
                    self.check_unknown(fixture)

    def test_missing_native_fact_or_helper_availability_is_unknown(self):
        for path in ("fullWake", "sleepDisabled", "helperObservation"):
            with self.subTest(path=path):
                fixture = happy_ac()
                if path == "helperObservation": fixture[1][10]["evidence"]["helper"]["status"]["sleepOverrideObservationAvailable"] = None
                else: fixture[1][10]["evidence"]["native"][path] = None
                self.check_unknown(fixture)

    def test_file_only_helper_is_not_a_live_ack(self):
        fixture = happy_ac()
        fixture[1][5]["evidence"]["helper"]["source"] = "file"
        self.check_unknown(fixture)

    def test_build_contract_gui_watchdog_and_lid_choice_must_match(self):
        mutators = [
            lambda f: f[0].update(appBuild=50),
            lambda f: f[1][10]["evidence"].update(build=50),
            lambda f: f[1][10]["common"]["value"].update(build=50),
            lambda f: f[1][10]["evidence"]["helper"]["status"].update(build=50),
            lambda f: f[1][10]["evidence"]["helper"]["status"].update(workSessionCoordinatorVersion=2),
            lambda f: f[1][10]["evidence"]["helper"]["status"].update(guiSessionAuthority="unavailable"),
            lambda f: f[1][10]["watchdog"]["value"].update(boot="old-boot"),
            lambda f: f[1][10]["watchdog"]["value"].update(checkedAt=WALL - 100),
            lambda f: f[1][10]["watchdog"]["value"].update(exitStatus=1),
            lambda f: f[1][10]["settings"]["value"].update(allowClosedLid=False),
            lambda f: f[1][10]["common"]["value"].update(version=True),
            lambda f: f[1][10]["evidence"]["helper"]["protection"].update(protocolVersion=2.0),
            lambda f: f[1][10]["evidence"]["helper"]["status"]["workSession"].update(executionVersion=3.0),
        ]
        for index, mutate in enumerate(mutators):
            with self.subTest(index=index):
                fixture = happy_ac(); mutate(fixture); self.check_unknown(fixture)

    def test_clock_or_row_reversal_never_sorts_into_success(self):
        for key in ("capturedAt", "continuous", "sequence"):
            with self.subTest(key=key):
                fixture = happy_ac(); fixture[1][10][key] = fixture[1][9][key] - 1
                report = self.check_unknown(fixture)
                self.assertTrue(report["integrity"]["issues"])
        fixture = happy_ac(); fixture[1][5], fixture[1][6] = fixture[1][6], fixture[1][5]
        self.check_unknown(fixture)

    def test_os_failure_truncation_or_inadequate_coverage_never_pass(self):
        for changes in (dict(exitCode=1), dict(timedOut=True), dict(truncated=True), dict(chronological=False),
                        dict(earliestAt=WALL + 1), dict(startedAt=WALL + 50), dict(eventCount=None)):
            with self.subTest(changes=changes):
                fixture = happy_ac(); fixture[2][0].update(changes)
                self.check_unknown(fixture)

    def test_simulated_other_mode_incomplete_or_other_boot_never_pass(self):
        for change in ("simulated", "mode", "phase", "boot"):
            with self.subTest(change=change):
                fixture = happy_ac()
                if change == "simulated": fixture[1][10]["evidence"]["simulated"] = True
                elif change == "mode": fixture[0]["mode"] = "dry-run"
                elif change == "phase": fixture[0]["phase"] = "interrupted"
                else: fixture[1][10]["bootID"] = "other-boot"
                self.check_unknown(fixture)

    def test_unknown_and_nonfinite_clock_do_not_crash_or_pass(self):
        for value in (None, "1000", math.nan, math.inf):
            with self.subTest(value=value):
                fixture = happy_ac(); fixture[1][14]["capturedAt"] = value
                self.check_unknown(fixture)

    def test_native_clock_lease_thermal_and_dry_run_flags_cannot_be_omitted(self):
        for change in ("nativeClock", "expiredLease", "missingLease", "thermal", "dryRun", "bridge"):
            with self.subTest(change=change):
                fixture = happy_ac(); evidence = fixture[1][10]["evidence"]
                if change == "nativeClock": evidence["continuous"] = None
                elif change == "expiredLease": evidence["helper"]["status"]["workSession"]["expiry"] = CLOCK
                elif change == "missingLease": evidence["helper"]["status"]["workSession"] = None
                elif change == "thermal": evidence["native"]["thermal"] = 2
                elif change == "dryRun": evidence["helper"]["protection"]["dryRun"] = True
                else: evidence["helper"].pop("bridge")
                self.check_unknown(fixture)

    def test_session_bounds_and_boolean_schema_do_not_approve_unrelated_rows(self):
        for changes in (dict(startedAt=WALL + 10), dict(endedAt=WALL + 60),
                        dict(startedContinuous=CLOCK + 10), dict(endedContinuous=CLOCK + 60), dict(schemaVersion=True)):
            with self.subTest(changes=changes):
                fixture = happy_ac(); fixture[0].update(changes); self.check_unknown(fixture)

    def test_unplug_malformed_native_timestamps_remain_unknown_without_exception(self):
        for value in (None, "1000", math.nan):
            with self.subTest(value=value):
                fixture = unplug(); fixture[1][0]["evidence"]["observedAt"] = value
                self.check_unknown(fixture, "closedLidUnplug")

    def test_os_event_without_timestamp_cannot_be_treated_as_no_sleep(self):
        fixture = happy_ac(); fixture[3].append(dict(source="pmset", kind="sleep", at=None))
        self.check_unknown(fixture)

    def test_unplug_release_sleep_wake_open_has_ordered_evidence(self):
        report = analysis.analyze(*unplug())
        self.assertEqual("pass", report["checks"]["closedLidUnplug"]["verdict"], report)
        incident = report["checks"]["closedLidUnplug"]["incidents"][0]
        self.assertEqual("sample", incident["release"]["source"])
        self.assertEqual(12, incident["latencies"]["sleepToWakeSeconds"])
        self.assertEqual(3, incident["openedSequence"])

    def test_same_session_boot_terminal_receipt_can_preserve_missed_release(self):
        report = analysis.analyze(*unplug(receipt_only=True))
        self.assertEqual("pass", report["checks"]["closedLidUnplug"]["verdict"], report)
        incident = report["checks"]["closedLidUnplug"]["incidents"][0]
        self.assertEqual("endReceipt", incident["release"]["source"])
        self.assertIn("원복 완료 시각이 아닌", incident["release"]["timestampMeaning"])

    def test_unplug_command_accepted_will_sleep_and_gap_are_not_actual_sleep(self):
        for replacement in ([], [dict(at=WALL + 5, source="helper", kind="helper", event="single Sleep result: commandAccepted")],
                            [dict(at=WALL + 5, source="helper", kind="helper", event="system power: will sleep")]):
            with self.subTest(events=replacement):
                fixture = unplug(); fixture[3][:] = replacement
                self.check_unknown(fixture, "closedLidUnplug")

    def test_unplug_sleep_without_wake_open_or_before_release_is_unknown(self):
        for change in ("wake", "open", "earlySleep", "coverage", "release"):
            with self.subTest(change=change):
                fixture = unplug()
                if change == "wake": fixture[3].pop()
                elif change == "open": fixture[1][-1]["evidence"]["native"]["lidClosed"] = True
                elif change == "earlySleep": fixture[3][0]["at"] = WALL + 1
                elif change == "coverage": fixture[2][0]["earliestAt"] = WALL + 2
                else: fixture[1][1]["evidence"]["helper"]["status"]["ownsOverride"] = True
                self.check_unknown(fixture, "closedLidUnplug")

    def test_wrong_or_stale_terminal_receipt_is_not_release_proof(self):
        for changes in (dict(bootID="old-boot"), dict(sessionID="different-session"), dict(id=None),
                        dict(sequence=0), dict(kind="user"), dict(phase="captured"), dict(observedAt=CLOCK - 1),
                        dict(observedAt=CLOCK + 40), dict(outcome="restoreUnverified"),
                        dict(outcome="foreignGlobalOverride"), dict(outcome=None)):
            with self.subTest(changes=changes):
                fixture = unplug(receipt_only=True)
                fixture[1][1]["evidence"]["helper"]["bridge"]["lidEndReceipt"].update(changes)
                self.check_unknown(fixture, "closedLidUnplug")

    def test_unplug_row_order_is_not_repaired_to_manufacture_causality(self):
        fixture = unplug(); fixture[1][0], fixture[1][1] = fixture[1][1], fixture[1][0]
        self.check_unknown(fixture, "closedLidUnplug")
        fixture = unplug(); fixture[3][1]["at"] = WALL + 4
        self.check_unknown(fixture, "closedLidUnplug")

    def test_other_app_screen_lock_and_timer_protection_are_observations_only(self):
        fixture = happy_ac()
        fixture[1][0]["evidence"]["native"]["displaySleeping"] = True
        fixture[1][0]["settings"]["value"]["lockOnClose"] = True
        fixture[1][0]["common"]["value"]["status"]["manualContinuousDeadline"] = CLOCK + 60
        report = analysis.analyze(*fixture)
        self.assertEqual("unknown", report["observations"]["lock"]["verdict"])
        self.assertEqual("unknown", report["checks"]["timerProtection"]["verdict"])
        self.assertTrue(report["observations"]["timers"])
        self.assertEqual([dict(pid=111, type="PreventUserIdleSystemSleep")], report["observations"]["otherAppOwners"]["candidates"])
        output = analysis.markdown(report)
        self.assertIn("패널 전력 0", output)
        self.assertIn("원격", output)
        self.assertIn("타이머·보호: 미확인", output)
        self.assertIn("잠금", output)

    def test_analysis_is_pure_and_does_not_mutate_retained_input(self):
        fixture = unplug(receipt_only=True); retained = copy.deepcopy(fixture)
        analysis.analyze(*fixture)
        self.assertEqual(retained, fixture)

    def test_actual_scrubbed_protection_shape_and_error_presence(self):
        self.assertEqual("pass", analysis.analyze(*happy_ac())["verdict"])
        for owner, key in (("helper", "errorPresent"), ("protection", "lastErrorPresent"),
                           ("common", "errorPresent"), ("common", "lidErrorPresent"),
                           ("status", "errorPresent")):
            with self.subTest(owner=owner, key=key):
                fixture = happy_ac(); row_value = fixture[1][10]
                targets = dict(helper=row_value["evidence"]["helper"],
                               protection=row_value["evidence"]["helper"]["protection"],
                               common=row_value["common"]["value"], status=row_value["common"]["value"]["status"])
                targets[owner][key] = True
                self.check_unknown(fixture)

    def test_later_build_must_match_session_not_a_fixed_build(self):
        fixture = happy_ac(); fixture[0]["appBuild"] = 52
        for value in fixture[1]:
            value["evidence"]["build"] = 52
            value["evidence"]["helper"]["status"]["build"] = 52
            value["common"]["value"]["build"] = 52
        self.assertEqual("pass", analysis.analyze(*fixture)["verdict"])
        fixture[1][10]["evidence"]["helper"]["status"]["build"] = 51
        self.check_unknown(fixture)

    def test_damaged_jsonl_or_unfinished_query_never_passes(self):
        for changes in (dict(invalidJSONLines=1), dict(invalidJSONLines=True), dict(invalidJSONLines="1"),
                        dict(backgroundQueryIncomplete=True), dict(backgroundQueryIncomplete="false"),
                        dict(partialFinalLine=True)):
            with self.subTest(changes=changes):
                fixture = happy_ac(); fixture[0].update(changes)
                report = self.check_unknown(fixture)
                self.assertTrue(report["integrity"]["issues"])
        fixture = happy_ac(); fixture[0].update(invalidJSONLines=0, backgroundQueryIncomplete=False, partialFinalLine=False)
        self.assertEqual("pass", analysis.analyze(*fixture)["verdict"])

    def test_preflight_installation_queries_and_human_times_are_visible(self):
        fixture = happy_ac()
        fixture[0]["preflight"] = dict(appBuild=51, probeBuild=51, helperBuild=50, closedLidEnabled=False,
                                       nativeAvailable=True, commonAvailable=True, helperLive=True)
        fixture[0]["helperFiles"] = dict(helperRegistration=dict(present=False, errorClass="FileNotFoundError"),
                                          helper=dict(present=True, executable=True))
        fixture[2].extend([dict(source="helperLogs", queriedAt=WALL + 1,
                               files=[dict(available=False, errorClass="PermissionError")]),
                          dict(source="commonOSLog", startedAt=WALL, endedAt=WALL + 1,
                               exitCode=1, timedOut=False, truncated=True)])
        fixture[1][0]["common"]["query"] = dict(exitCode=1, timedOut=False, truncated=False)
        report = analysis.analyze(*fixture)
        self.assertEqual(50, report["readiness"]["preflight"]["helperBuild"])
        self.assertEqual(["helperRegistration"], report["readiness"]["missingHelperFiles"])
        stats = {value["source"]: value for value in report["querySummary"]}
        self.assertEqual(1, stats["helperLogs"]["failed"])
        self.assertEqual(1, stats["commonOSLog"]["limited"])
        self.assertEqual(1, stats["common"]["failed"])
        output = analysis.markdown(report)
        for needle in ("51", "50", "도우미 등록", "PermissionError", "helperLogs", "KST", "UTC", "1970-01-01", "미확인 2"):
            self.assertIn(needle, output)
        self.assertFalse(report["scope"]["completeAcceptance"])

    def test_remaining_timer_and_temperature_observations_do_not_become_physical_passes(self):
        fixture = happy_ac(); value = fixture[1][0]
        value["common"]["value"]["status"].update(manualActive=False, manualRemaining=30,
                                                   batteryRemaining=1800, manualBatteryRemaining=7200)
        value["evidence"]["native"]["batteryTemperature"] = 35.89
        report = analysis.analyze(*fixture)
        self.assertEqual(30, report["observations"]["timers"][0]["manualRemaining"])
        self.assertFalse(report["observations"]["timers"][0]["manualActive"])
        self.assertEqual(35.89, report["observations"]["protection"][0]["batteryTemperature"])
        self.assertEqual(dict(passCount=1, failCount=0, unknownCount=2, total=3), report["outcomeCounts"])
        output = analysis.markdown(report)
        self.assertIn("35.89", output)
        self.assertIn("7200", output)
        self.assertIn("열 압력", output)
        self.assertIn("남은 용량", output)
        self.assertIn("실행 중임을 뜻하지", output)

    def test_markdown_shows_ordered_os_events_and_korean_latency_labels(self):
        report = analysis.analyze(*unplug(receipt_only=True))
        output = analysis.markdown(report)
        self.assertIn("분리 표본→Sleep", output)
        self.assertIn("원복 완료 시각이 아닌", output)
        self.assertIn("초 단위", output)
        self.assertIn("pmset", output)
        self.assertIn("KST", output)
        self.assertLess(output.index("sleep |"), output.index("wake |"))

    def test_cached_query_metadata_is_not_counted_as_new_executions(self):
        fixture = happy_ac()
        query_value = dict(startedAt=WALL, endedAt=WALL + .02, exitCode=1, timedOut=False, truncated=False)
        for value in fixture[1]:
            value["assertions"]["query"] = copy.deepcopy(query_value)
        report = analysis.analyze(*fixture)
        stats = next(value for value in report["querySummary"] if value["source"] == "assertions")
        self.assertEqual(1, stats["count"])
        self.assertEqual(1, stats["failed"])

    def test_absent_optional_rotations_do_not_fail_a_readable_active_log(self):
        fixture = happy_ac()
        baseline = analysis.analyze(*fixture)
        fixture[2].append(dict(source="helperLogs", queriedAt=WALL + 1, truncated=False,
            files=[dict(rotation=suffix, available=False, errorClass="FileNotFoundError")
                   for suffix in (".3", ".2", ".1")] + [dict(rotation="active", available=True)]))
        retained = copy.deepcopy(fixture)
        report = analysis.analyze(*fixture)
        stats = next(value for value in report["querySummary"] if value["source"] == "helperLogs")
        self.assertEqual((1, 0, 0, 3, []), (stats["succeeded"], stats["failed"],
            stats["unavailableFiles"], stats["missingOptionalRotations"], stats["errorClasses"]))
        self.assertEqual(retained, fixture)
        for key in ("verdict", "checks", "integrity", "scope", "outcomeCounts"):
            self.assertEqual(baseline[key], report[key])
        self.assertIn("선택 회전 부재", analysis.markdown(report))

    def test_required_active_and_real_archive_errors_preserve_query_failures(self):
        absent_rotations = [dict(rotation=suffix, available=False, errorClass="FileNotFoundError")
                            for suffix in (".1", ".2", ".3")]
        cases = [
            ("activeMissing", [dict(rotation="active", available=False, errorClass="FileNotFoundError"),
                                dict(rotation=".1", available=True)], "failed", "FileNotFoundError", 0),
            ("allMissing", absent_rotations + [dict(rotation="active", available=False,
                                                    errorClass="FileNotFoundError")], "failed", "FileNotFoundError", 3),
            ("archivePermission", [dict(rotation="active", available=True),
                                    dict(rotation=".1", available=False, errorClass="PermissionError")],
             "failed", "PermissionError", 0),
            ("archiveOtherError", [dict(rotation="active", available=True),
                                    dict(rotation=".2", available=False, errorClass="ValueError")],
             "failed", "ValueError", 0),
            ("activeNotRecorded", absent_rotations, "unknown", None, 3),
        ]
        for name, files, result, error, optional_count in cases:
            with self.subTest(name=name):
                rows = [row(1, 0, closed=False)]
                fixture = (session(rows), rows, [], [])
                baseline = analysis.analyze(*fixture)
                fixture[2].append(dict(source="helperLogs", queriedAt=WALL + 1, truncated=False, files=files))
                retained = copy.deepcopy(fixture)
                report = analysis.analyze(*fixture)
                stats = next(value for value in report["querySummary"] if value["source"] == "helperLogs")
                self.assertEqual(1, stats[result])
                self.assertEqual(0, stats["succeeded"])
                self.assertEqual(1 if error else 0, stats["unavailableFiles"])
                self.assertEqual([error] if error else [], stats["errorClasses"])
                self.assertEqual(optional_count, stats["missingOptionalRotations"])
                self.assertEqual(retained, fixture)
                for key in ("verdict", "checks", "integrity", "scope", "outcomeCounts"):
                    self.assertEqual(baseline[key], report[key])
                self.assertEqual("unknown", report["verdict"])

    def test_fast_unplug_uses_committed_final_predicate_with_actual_sleep_and_wake(self):
        for outcome in ("commandAccepted", "requestCommitted"):
            with self.subTest(outcome=outcome):
                fixture = fast_unplug()
                fixture[1][1]["evidence"]["helper"]["bridge"]["lidEndReceipt"]["outcome"] = outcome
                report = analysis.analyze(*fixture)
                self.assertEqual("pass", report["checks"]["closedLidUnplug"]["verdict"], report)
                incident = report["checks"]["closedLidUnplug"]["incidents"][0]
                self.assertEqual("helperFinalPredicate", incident["conditionEvidence"])
                self.assertIsNone(incident["batterySequence"])
                self.assertEqual("endReceipt", incident["release"]["source"])
                self.assertTrue(report["integrity"]["gaps"])
                output = analysis.markdown(report)
                self.assertIn("분리 직후 native 행 미수집", output)
                self.assertIn("helper 최종 승인 계약", output)

    def test_fast_unplug_rejects_uncommitted_foreign_expired_and_wrong_action_receipts(self):
        for changes in (dict(outcome="cancelled"), dict(outcome="restoreUnverified"),
                        dict(outcome="foreignGlobalOverride"), dict(outcome="executorInterrupted"),
                        dict(outcome="commandRejected"), dict(phase="restored"), dict(action="followOS"),
                        dict(sessionID="other-session"), dict(bootID="other-boot"), dict(sequence=0), dict(id=None),
                        dict(observedAt=CLOCK - 1), dict(observedAt=CLOCK + 91), dict(kind="protection")):
            with self.subTest(changes=changes):
                fixture = fast_unplug()
                fixture[1][1]["evidence"]["helper"]["bridge"]["lidEndReceipt"].update(changes)
                self.check_unknown(fixture, "closedLidUnplug")

    def test_fast_unplug_needs_finite_before_lease_live_after_and_os_causal_order(self):
        for change in ("sleep", "wake", "earlySleep", "open", "native", "helper", "boot", "lease", "expired", "coverage"):
            with self.subTest(change=change):
                fixture = fast_unplug()
                if change == "sleep": fixture[3].pop(0)
                elif change == "wake": fixture[3].pop()
                elif change == "earlySleep": fixture[3][0]["at"] = WALL - 1
                elif change == "open": fixture[1][1]["evidence"]["native"]["lidClosed"] = True
                elif change == "native": fixture[1][1]["evidence"]["observedAt"] -= 11
                elif change == "helper": fixture[1][1]["evidence"]["helper"]["source"] = "file"
                elif change == "boot": fixture[1][1]["bootID"] = "old-boot"
                elif change == "lease": fixture[1][0]["evidence"]["helper"]["status"]["workSession"] = None
                elif change == "expired": fixture[1][0]["evidence"]["helper"]["status"]["workSession"]["expiry"] = CLOCK + .5
                else: fixture[2][0]["earliestAt"] = WALL + 1
                self.check_unknown(fixture, "closedLidUnplug")

    def test_source_power_and_full_wake_disagreement_never_passes(self):
        for field in ("commonPower", "helperPower", "leasePower", "helperFullWake"):
            for value in (None, "battery", "unknown") if field != "helperFullWake" else (None, False):
                with self.subTest(field=field, value=value):
                    fixture = happy_ac()
                    item = fixture[1][10]
                    if field == "commonPower": item["common"]["value"]["status"]["power"] = value
                    elif field == "helperPower": item["evidence"]["helper"]["status"]["power"] = value
                    elif field == "leasePower": item["evidence"]["helper"]["status"]["workSession"]["power"] = value
                    else: item["evidence"]["helper"]["status"]["fullWake"] = value
                    self.check_unknown(fixture, "acClosedLid")


if __name__ == "__main__":
    unittest.main(verbosity=2)
