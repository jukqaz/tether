"""Analyze retained physical-test evidence without querying or changing the host."""
import math
from datetime import datetime, timedelta, timezone

EXPECTED_COORDINATOR = 7
FRESH_SECONDS = 10
MAXIMUM_GAP = 10
AC_MINIMUM_SECONDS = 80
OS_TIMESTAMP_RESOLUTION = 1


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _object(value):
    return value if isinstance(value, dict) else {}


def _text(value):
    return value if isinstance(value, str) and value and value != "unknown" else None


def _fresh(at, now, limit=FRESH_SECONDS):
    return _number(at) and _number(now) and 0 <= now - at <= limit


def _result(verdict, summary, **values):
    return dict(verdict=verdict, summary=summary, **values)


def _native(row):
    return _object(_object(row.get("evidence")).get("native"))


def _helper(row):
    return _object(_object(row.get("evidence")).get("helper"))


def _common(row):
    wrapper = _object(row.get("common"))
    return _object(wrapper.get("value")) if wrapper.get("available") is True else {}


def _settings(row):
    wrapper = _object(row.get("settings"))
    return _object(wrapper.get("value")) if wrapper.get("available") is True else {}


def _error_present(value):
    value = _object(value)
    return (any(value.get(key) is not None for key in ("error", "lastError", "lastApplyError", "lidError"))
            or any(value.get(key) is not None and value[key] is not False
                   for key in ("errorPresent", "lastErrorPresent", "lastApplyErrorPresent", "lidErrorPresent")))


def _helper_fresh(row, build):
    helper = _helper(row)
    status = _object(helper.get("status"))
    protection = _object(helper.get("protection"))
    return (helper.get("available") is True and helper.get("source") == "live"
            and _integer(status.get("build")) and status["build"] == build
            and protection.get("dryRun") is False and _integer(protection.get("protocolVersion")) and protection["protocolVersion"] == 2
            and not _error_present(helper)
            and _fresh(status.get("updatedAt"), row.get("completedAt")))


def _native_fresh(row, build):
    evidence = _object(row.get("evidence"))
    return (evidence.get("simulated") is False and _integer(evidence.get("build")) and evidence["build"] == build
            and evidence.get("bootID", row.get("bootID")) == row.get("bootID")
            and _number(evidence.get("continuous"))
            and _fresh(evidence.get("observedAt"), row.get("completedAt")))


def _native_at(row):
    return _object(row.get("evidence")).get("observedAt")


def _coverage(queries, start, end):
    """A query started after the interval can cover its whole past, never its future."""
    if not _number(start) or not _number(end):
        return None
    for index, query in enumerate(queries):
        query = _object(query)
        earliest, requested, finished = query.get("earliestAt"), query.get("startedAt"), query.get("endedAt")
        if (query.get("source") == "pmset" and _integer(query.get("exitCode")) and query["exitCode"] == 0
                and query.get("timedOut") is False and query.get("truncated") is False
                and query.get("chronological") is True and _integer(query.get("eventCount"))
                and query["eventCount"] >= 0 and all(_number(v) for v in (earliest, requested, finished))
                and earliest <= start <= end <= requested <= finished):
            return index
    return None


def _os_events(events, kind):
    return [event for event in events if event.get("source") == "pmset" and event.get("kind") == kind
            and _number(event.get("at"))]


def _sample_issues(row, boot, build):
    issues = []
    if row.get("bootID") != boot or not _text(boot):
        issues.append("부팅 식별 불일치 또는 미확인")
    if not _native_fresh(row, build):
        issues.append("native 근거가 누락·오래됨·다른 빌드 또는 시뮬레이션")
    native = _native(row)
    if native.get("power") != "ac" or native.get("lidClosed") is not True or native.get("fullWake") is not True:
        issues.append("AC·닫힌 덮개·Full Wake 관측 미확인")
    if native.get("sleepDisabled") is not True:
        issues.append("독립 OS SleepDisabled 유지 관측 미확인")
    if not _integer(native.get("thermal")) or native["thermal"] not in (0, 1):
        issues.append("보호가 필요하지 않은 OS thermal 관측 미확인")
    common = _common(row)
    state = _object(common.get("status"))
    if (common.get("ok") is not True or not _integer(common.get("build")) or common["build"] != build
            or not _integer(common.get("version")) or common["version"] != 1
            or not _text(common.get("epoch")) or not _integer(common.get("revision"))
            or not _fresh(common.get("observedAt"), row.get("completedAt"))
            or common.get("helperConnected") is not True or common.get("lidSupport") != "active"
            or state.get("power") != "ac"
            or state.get("enabled") is not True or state.get("holding") is not True
            or not (state.get("automaticActive") is True or state.get("manualActive") is True)):
        issues.append("현재 common 유지·덮개 승인 응답 미확인")
    if state.get("blockReason") is not None or _error_present(common) or _error_present(state):
        issues.append("common 보호 또는 오류 관측")
    helper = _helper(row)
    status = _object(helper.get("status"))
    if not _helper_fresh(row, build):
        issues.append("현재 live helper 응답 미확인")
    if (not _integer(status.get("workSessionCoordinatorVersion")) or status["workSessionCoordinatorVersion"] != EXPECTED_COORDINATOR
            or status.get("appConnected") is not True or status.get("guiSessionAuthority") != "confirmed"
            or status.get("power") != "ac" or status.get("fullWake") is not True
            or status.get("systemPowerObservationAvailable") is not True
            or status.get("lidObservationAvailable") is not True or status.get("lidClosed") is not True
            or status.get("sleepOverrideObservationAvailable") is not True
            or status.get("sleepDisabled") is not True or status.get("ownsOverride") is not True):
        issues.append("helper 승인·소유권·독립 관측 준비 미확인")
    protection = helper.get("protection")
    if (not isinstance(protection, dict) or protection.get("dryRun") is not False or protection.get("blockReason") is not None
            or _error_present(protection) or _error_present(status) or not isinstance(helper.get("bridge"), dict)
            or _object(helper.get("bridge")).get("lidProtection") is not None):
        issues.append("helper 보호 없음 또는 원복 오류 없음 미확인")
    lease = _object(status.get("workSession"))
    permit = _object(lease.get("lidPermit"))
    scopes, reasons = permit.get("powerScopes"), lease.get("reasons")
    clock, expiry = _object(row.get("evidence")).get("continuous"), lease.get("expiry")
    if (not _integer(lease.get("executionVersion")) or lease["executionVersion"] != 3 or lease.get("power") != "ac" or not _text(lease.get("sessionID"))
            or not _integer(lease.get("sequence")) or lease["sequence"] <= 0
            or not isinstance(scopes, list) or "ac" not in scopes
            or not isinstance(reasons, list) or not reasons or any(reason not in ("automatic", "manual") for reason in reasons)
            or not _number(clock) or not _number(expiry) or not clock < expiry <= clock + 90):
        issues.append("현재 유한 v3 AC 덮개 권한 미확인")
    watchdog = _object(row.get("watchdog"))
    receipt = _object(watchdog.get("value"))
    if (watchdog.get("available") is not True or receipt.get("boot") != boot
            or not _integer(receipt.get("exitStatus")) or receipt["exitStatus"] != 0
            or not _fresh(receipt.get("checkedAt"), row.get("completedAt"), 90)):
        issues.append("이번 부팅의 최근 watchdog 점검 미확인")
    if _settings(row).get("allowClosedLid") is not True:
        issues.append("덮개 유지 선택 미확인")
    return issues


def _ac_check(samples, queries, events, boot, build, blocking):
    intervals, pending = [], []

    def finish():
        if not pending:
            return
        first, last = pending[0], pending[-1]
        start, end = first.get("capturedAt"), last.get("completedAt")
        elapsed = last.get("continuous") - first.get("continuous") if all(
            _number(v) for v in (first.get("continuous"), last.get("continuous"))) else None
        missing = []
        for row in pending:
            missing.extend(_sample_issues(row, boot, build))
        for before, after in zip(pending, pending[1:]):
            if (_number(before.get("continuous")) and _number(after.get("continuous"))
                    and after["continuous"] - before["continuous"] > MAXIMUM_GAP):
                missing.append("연속 구간의 표본 간격이 10초 초과")
            if _integer(before.get("sequence")) and after.get("sequence") != before["sequence"] + 1:
                missing.append("연속 구간 표본 누락")
        missing = list(dict.fromkeys(missing))
        coverage = _coverage(queries, start, end) if all(_number(v) for v in (start, end)) else None
        sleeps = [event["at"] for event in _os_events(events, "sleep") if _number(start) and _number(end) and start <= event["at"] <= end]
        value = dict(startedAt=start, endedAt=end, durationSeconds=elapsed,
                     firstSequence=first.get("sequence"), lastSequence=last.get("sequence"),
                     samples=len(pending), coverageQuery=coverage, sleepEvents=sleeps, missing=missing)
        if blocking or missing:
            value.update(_result("unknown", "근거의 신선도·승인·연속성을 확인할 수 없습니다."))
        elif coverage is None:
            value.update(_result("unknown", "구간 전체를 포함한 성공 OS 로그 조회가 없어 Sleep 여부를 판정할 수 없습니다."))
        elif sleeps:
            value.update(_result("fail", "덮개 유지 승인과 연속 관측 구간 안에서 실제 OS Sleep이 기록됐습니다."))
        elif elapsed is None or elapsed < AC_MINIMUM_SECONDS:
            value.update(_result("unknown", "닫힌 AC 유지의 연속 80초 근거가 부족합니다."))
        else:
            value.update(_result("pass", "연속 80초 이상 자체 덮개 유지와 OS 관측을 확인했으며 해당 로그 범위에 Sleep이 없습니다."))
        intervals.append(value)
        pending.clear()

    for row in samples:
        native = _native(row)
        if native.get("power") == "ac" and native.get("lidClosed") is True:
            pending.append(row)
        else:
            finish()
    finish()
    verdict = "fail" if any(v["verdict"] == "fail" for v in intervals) else "unknown"
    if intervals and all(v["verdict"] == "pass" for v in intervals):
        verdict = "pass"
    return _result(verdict, {"pass": "닫힌 AC 유지 근거가 충족됐습니다.", "fail": "유지 승인 중 실제 Sleep이 관측됐습니다.",
                   "unknown": "닫힌 AC 유지 결과를 확정할 근거가 부족합니다."}[verdict], intervals=intervals)


def _release_candidates(samples, index, before, boot, build):
    candidates = []
    previous_lease = _object(_object(_helper(before).get("status")).get("workSession"))
    session_id = _text(previous_lease.get("sessionID"))
    previous_sequence = previous_lease.get("sequence")
    first_clock = _object(before.get("evidence")).get("continuous")
    for row in samples[index:]:
        if row.get("bootID") != boot or not _native_fresh(row, build):
            continue
        native, helper = _native(row), _helper(row)
        status = _object(helper.get("status"))
        if _helper_fresh(row, build) and native.get("sleepDisabled") is False and status.get("ownsOverride") is False:
            candidates.append(dict(at=_native_at(row), source="sample", sequence=row.get("sequence"),
                                   timestampMeaning="자체 해제와 독립 OS 해제의 표본 관측 시각"))
        receipt = _object(_object(helper.get("bridge")).get("lidEndReceipt"))
        observed, now = receipt.get("observedAt"), _object(row.get("evidence")).get("continuous")
        if (not _helper_fresh(row, build) or not session_id or receipt.get("sessionID") != session_id
                or receipt.get("bootID") != boot or not _text(receipt.get("id"))
                or not _integer(previous_sequence) or not _integer(receipt.get("sequence"))
                or receipt["sequence"] < previous_sequence or receipt.get("kind") != "disconnect"
                or receipt.get("phase") not in ("restored", "consumed")
                or (receipt.get("phase") == "consumed" and receipt.get("outcome") not in
                    ("requestCommitted", "commandAccepted", "commandRejected", "cancelled"))
                or not all(_number(v) for v in (observed, first_clock, now)) or not first_clock <= observed <= now):
            continue
        at = _native_at(row) + observed - now
        candidates.append(dict(at=at, source="endReceipt", sequence=row.get("sequence"), id=receipt["id"],
                               sessionID=session_id, outcome=receipt.get("outcome"),
                               timestampMeaning="원복 완료 시각이 아닌 동일 세션 분리 사건의 포착 시각"))
    return candidates


def _unplug_check(samples, queries, events, boot, build, blocking):
    incidents = []
    sleep_events = _os_events(events, "sleep")
    wake_events = _os_events(events, "wake")
    for index in range(1, len(samples)):
        before, battery = samples[index - 1], samples[index]
        native_before, native_after = _native(before), _native(battery)
        if not (native_before.get("power") == "ac" and native_after.get("power") == "battery"
                and native_before.get("lidClosed") is True and native_after.get("lidClosed") is True):
            continue
        incident = dict(beforeSequence=before.get("sequence"), batterySequence=battery.get("sequence"),
                        powerObservedBetween=[_native_at(before), _native_at(battery)], release=None,
                        sleepAt=None, wakeAt=None, openedSequence=None, latencies={}, coverageQuery=None)
        missing = _sample_issues(before, boot, build)
        if not _native_fresh(battery, build) or battery.get("bootID") != boot:
            missing.append("배터리 전환의 독립 현재 표본 미확인")
        if _settings(before).get("disconnectAction") != "sleepIfClosed":
            missing.append("닫힌 전원 분리 잠자기 선택 미확인")
        if (not all(_number(v) for v in (before.get("continuous"), battery.get("continuous")))
                or battery["continuous"] - before["continuous"] > MAXIMUM_GAP):
            missing.append("전원 전환 사이 표본 공백")
        if blocking or missing:
            incident["missing"] = list(dict.fromkeys(missing))
            incident.update(_result("unknown", "전원 분리의 설정·부팅·시각 또는 선행 승인 근거가 부족합니다."))
            incidents.append(incident)
            continue
        releases = _release_candidates(samples, index, before, boot, build)
        for asleep in sleep_events:
            at = asleep["at"]
            if not _number(_native_at(battery)) or at + OS_TIMESTAMP_RESOLUTION < _native_at(battery):
                continue
            eligible = [r for r in releases if _native_at(before) <= r["at"] <= at + OS_TIMESTAMP_RESOLUTION]
            if not eligible:
                continue
            for wake in wake_events:
                if wake["at"] <= at:
                    continue
                opened = next((row for row in samples[index + 1:] if row.get("bootID") == boot
                               and _native_fresh(row, build) and _native(row).get("lidClosed") is False
                               and _native(row).get("fullWake") is True and _number(_native_at(row))
                               and _native_at(row) > at and _native_at(row) + OS_TIMESTAMP_RESOLUTION >= wake["at"]), None)
                if opened is None:
                    continue
                coverage = _coverage(queries, before["capturedAt"], opened["completedAt"])
                if coverage is None:
                    continue
                release = min(eligible, key=lambda r: r["at"])
                incident.update(release=release, sleepAt=at, wakeAt=wake["at"],
                                openedSequence=opened.get("sequence"), coverageQuery=coverage,
                                latencies=dict(powerSampleToSleepSeconds=at - _native_at(battery),
                                               releaseEvidenceToSleepSeconds=at - release["at"],
                                               sleepToWakeSeconds=wake["at"] - at,
                                               wakeToOpenSampleSeconds=_native_at(opened) - wake["at"]))
                break
            if incident["sleepAt"] is not None:
                break
        incident["missing"] = list(dict.fromkeys(missing))
        if blocking or missing:
            incident.update(_result("unknown", "전원 분리의 설정·부팅·시각 또는 선행 승인 근거가 부족합니다."))
        elif incident["sleepAt"] is not None:
            incident.update(_result("pass", "닫힌 전원 분리, 자체 해제, 실제 OS Sleep, 이후 열림·Full Wake 순서가 관측됐습니다. Wake 원인까지 증명한 것은 아닙니다."))
        else:
            incident.update(_result("unknown", "자체 해제와 실제 Sleep·열림/Wake의 순서 또는 OS 로그 범위를 확인할 수 없습니다. 명령 성공만으로 통과하지 않습니다."))
        incidents.append(incident)
    for fast in _fast_unplug_incidents(samples, queries, events, boot, build, blocking):
        prior = next((i for i in incidents if i.get("beforeSequence") == fast["beforeSequence"]), None)
        if prior and prior["verdict"] == "pass":
            continue
        if prior:
            fast["samplePathMissing"] = prior.get("missing", [])
            incidents[incidents.index(prior)] = fast
        else:
            incidents.append(fast)
    verdict = "pass" if incidents and all(i["verdict"] == "pass" for i in incidents) else "unknown"
    return _result(verdict, "닫힌 전원 분리의 관측 순서를 확인했습니다." if verdict == "pass" else
                   "닫힌 전원 분리 결과는 미확인입니다.", incidents=incidents)


def _fast_unplug_incidents(samples, queries, events, boot, build, blocking):
    """Bridge a missed battery/closed sample using the v3 final-predicate journal.

    A consumed, committed disconnect/sleepIfClosed receipt is written only after
    the same recovery transaction verifies restoration and its final closed,
    battery predicate. It proves that contract, never OS Sleep by itself.
    """
    if blocking:
        return []
    incidents, seen = [], set()
    for index, opened in enumerate(samples):
        native, helper = _native(opened), _helper(opened)
        status = _object(helper.get("status"))
        receipt = _object(_object(helper.get("bridge")).get("lidEndReceipt"))
        clock = _object(opened.get("evidence")).get("continuous")
        observed = receipt.get("observedAt")
        if (opened.get("bootID") != boot or not _native_fresh(opened, build) or not _helper_fresh(opened, build)
                or status.get("workSessionCoordinatorVersion") != EXPECTED_COORDINATOR
                or native.get("lidClosed") is not False or native.get("fullWake") is not True
                or not _text(receipt.get("id")) or receipt["id"] in seen
                or receipt.get("bootID") != boot or not _text(receipt.get("sessionID"))
                or not _integer(receipt.get("sequence")) or receipt["sequence"] <= 0
                or receipt.get("kind") != "disconnect" or receipt.get("action") != "sleepIfClosed"
                or receipt.get("phase") != "consumed" or receipt.get("outcome") not in ("commandAccepted", "requestCommitted")
                or not _number(observed) or not _number(clock) or observed > clock):
            continue
        before = None
        for row in reversed(samples[:index]):
            lease = _object(_object(_helper(row).get("status")).get("workSession"))
            start = _object(row.get("evidence")).get("continuous")
            expiry = lease.get("expiry")
            if (lease.get("sessionID") == receipt["sessionID"] and _integer(lease.get("sequence"))
                    and receipt["sequence"] >= lease["sequence"]
                    and all(_number(v) for v in (start, expiry)) and start <= observed <= expiry
                    and not _sample_issues(row, boot, build) and _settings(row).get("disconnectAction") == "sleepIfClosed"):
                before = row
                break
        if before is None:
            continue
        # Only the source evidence's own wall/continuous pair projects its
        # journal timestamp. The recorder's continuous clock is not substituted.
        incident_at = _native_at(opened) + observed - clock
        if not _native_at(before) <= incident_at <= _native_at(opened):
            continue
        coverage = _coverage(queries, before.get("capturedAt"), opened.get("completedAt"))
        if coverage is None:
            continue
        for asleep in _os_events(events, "sleep"):
            at = asleep["at"]
            if at + OS_TIMESTAMP_RESOLUTION < incident_at or at >= _native_at(opened):
                continue
            wake = next((event for event in _os_events(events, "wake")
                         if at < event["at"] <= _native_at(opened) + OS_TIMESTAMP_RESOLUTION), None)
            if wake is None:
                continue
            release = dict(at=incident_at, source="endReceipt", id=receipt["id"], sequence=receipt["sequence"],
                           sessionID=receipt["sessionID"], outcome=receipt["outcome"],
                           timestampMeaning="원복 완료 시각이 아닌 동일 세션 분리 사건의 포착 시각")
            incidents.append(_result("pass", "분리 직후 native 행 미수집: 닫힘·배터리 조건은 helper 최종 승인 계약 근거입니다. 이후 실제 OS Sleep·Wake와 독립 열림/Full Wake를 확인했습니다.",
                                     beforeSequence=before.get("sequence"), batterySequence=None,
                                     conditionEvidence="helperFinalPredicate", powerObservedBetween=[_native_at(before), None],
                                     sourceLeaseSequence=_object(_object(_helper(before).get("status")).get("workSession")).get("sequence"),
                                     sourceLeaseExpiry=_object(_object(_helper(before).get("status")).get("workSession")).get("expiry"),
                                     receiptAction=receipt["action"], receiptPhase=receipt["phase"],
                                     disconnectObservedAt=incident_at, release=release, sleepAt=at, wakeAt=wake["at"],
                                     openedSequence=opened.get("sequence"), coverageQuery=coverage, missing=[],
                                     latencies=dict(releaseEvidenceToSleepSeconds=at - incident_at,
                                                    sleepToWakeSeconds=wake["at"] - at,
                                                    wakeToOpenSampleSeconds=_native_at(opened) - wake["at"])))
            seen.add(receipt["id"])
            break
    return incidents


def _query_summary(queries, samples):
    grouped = {}
    seen = set()
    records = [(query.get("source", "unknown"), query) for query in queries]
    for row in samples:
        for source, query in (("native", row.get("evidenceQuery")),
                              ("common", _object(row.get("common")).get("query")),
                              ("assertions", _object(row.get("assertions")).get("query"))):
            if isinstance(query, dict):
                records.append((source, query))
    for source, query in records:
        source = source if isinstance(source, str) else "unknown"
        begin, end = query.get("startedAt", query.get("queriedAt")), query.get("endedAt", query.get("queriedAt"))
        # Assertions are cached by the recorder. Repeated snapshots of the same
        # timed query are evidence rows, not additional executions or failures.
        if _number(begin) and _number(end):
            key = (source, begin, end, str(query.get("exitCode")), str(query.get("timedOut")), str(query.get("truncated")))
            if key in seen:
                continue
            seen.add(key)
        summary = grouped.setdefault(source, dict(source=source, count=0, succeeded=0, failed=0,
                                                 limited=0, unknown=0, unavailableFiles=0,
                                                 missingOptionalRotations=0, errorClasses=[],
                                                 startedAt=None, endedAt=None))
        summary["count"] += 1
        if _number(begin):
            summary["startedAt"] = min(begin, summary["startedAt"]) if _number(summary["startedAt"]) else begin
        if _number(end):
            summary["endedAt"] = max(end, summary["endedAt"]) if _number(summary["endedAt"]) else end
        errors = []
        files = query.get("files")
        limited = query.get("timedOut") is True or query.get("truncated") is True
        if isinstance(files, list):
            # Rotation files are created only after the active log grows. Their
            # normal absence is not a read failure; the active log stays required.
            optional_missing = [file for file in files if source == "helperLogs"
                                and _object(file).get("rotation") in (".1", ".2", ".3")
                                and _object(file).get("available") is False
                                and _object(file).get("errorClass") == "FileNotFoundError"]
            required = [file for file in files if file not in optional_missing]
            bad = [file for file in required if _object(file).get("available") is False]
            summary["missingOptionalRotations"] += len(optional_missing)
            summary["unavailableFiles"] += len(bad)
            errors.extend(_object(file).get("errorClass") for file in bad)
            active_available = source != "helperLogs" or any(
                _object(file).get("rotation") == "active" and _object(file).get("available") is True
                for file in required)
            result = "failed" if bad else "succeeded" if active_available and required and all(
                _object(file).get("available") is True for file in required) else "unknown"
        elif query.get("timedOut") is True or (_integer(query.get("exitCode")) and query["exitCode"] != 0):
            result = "failed"
        elif (query.get("exitCode") == 0 and _integer(query.get("exitCode"))
              and query.get("timedOut") is False and query.get("truncated") is False):
            result = "succeeded"
        else:
            result = "unknown"
        summary[result] += 1
        summary["limited"] += int(limited)
        errors.append(query.get("errorClass"))
        for error in errors:
            if _text(error) and error not in summary["errorClasses"]:
                summary["errorClasses"].append(error[:80])
    return list(grouped.values())


def _readiness(session, samples):
    preflight = _object(session.get("preflight"))
    preflight = {key: preflight[key] for key in ("appBuild", "probeBuild", "helperBuild", "closedLidEnabled",
                                                "nativeAvailable", "commonAvailable", "helperLive") if key in preflight}
    missing, warnings = [], []
    files = {}
    for phase, key in (("start", "helperFiles"), ("end", "helperFilesAtEnd")):
        raw_files = _object(session.get(key))
        files[phase] = {name: {field: _object(value)[field] for field in ("present", "executable", "errorClass")
                              if field in _object(value)} for name, value in raw_files.items()
                        if name in ("helper", "helperRegistration", "watchdog", "watchdogRegistration", "recoveryLock", "recoveryExecutor")}
        for name, value in files[phase].items():
            if value.get("present") is False and name not in missing:
                missing.append(name)
    for key, name in (("probeBuild", "관측 도구"), ("helperBuild", "도우미")):
        if key in preflight and preflight[key] != session.get("appBuild"):
            warnings.append(f"{name} 빌드가 시험 앱과 다릅니다")
    for key, name in (("closedLidEnabled", "덮개 유지 선택"), ("nativeAvailable", "독립 OS 관측"),
                      ("commonAvailable", "공통 세션 응답"), ("helperLive", "live 도우미 응답")):
        if preflight.get(key) is False:
            warnings.append(f"시작 시 {name} 미준비")
    if missing:
        warnings.append("필수 설치 파일 누락: 현재 live 응답은 영구 설치 완전성을 증명하지 않습니다")
    observed = []
    for row in samples:
        helper, common = _helper(row), _common(row)
        status = _object(helper.get("status"))
        observed.append(dict(sequence=row.get("sequence"), at=row.get("capturedAt"),
                             nativeBuild=_object(row.get("evidence")).get("build"), commonBuild=common.get("build"),
                             helperBuild=status.get("build"), helperSource=helper.get("source"),
                             coordinator=status.get("workSessionCoordinatorVersion"),
                             appConnected=status.get("appConnected"), guiAuthority=status.get("guiSessionAuthority"),
                             lidSupport=common.get("lidSupport"), ownsOverride=status.get("ownsOverride"),
                             sleepDisabled=_native(row).get("sleepDisabled"), allowClosedLid=_settings(row).get("allowClosedLid")))
    return dict(preflight=preflight, missingHelperFiles=missing, helperFiles=files, warnings=warnings, observed=observed)


def analyze(session: dict, samples: list, queries: list, events: list) -> dict:
    """Return conservative physical-test verdicts from supplied evidence only."""
    session = _object(session)
    samples = [_object(row) for row in samples]
    queries = [_object(query) for query in queries]
    events = [_object(event) for event in events]
    boot = _object(session.get("host")).get("bootID")
    build = session.get("appBuild")
    issues, gaps = [], []
    if not _integer(session.get("schemaVersion")) or session["schemaVersion"] != 1 or session.get("mode") != "physical":
        issues.append("물리 시험 schema/mode 미확인")
    if not _integer(build) or build <= 0:
        issues.append("시험 앱 빌드 미확인")
    if not _text(boot):
        issues.append("시험 부팅 식별 미확인")
    if session.get("phase") != "complete":
        issues.append("수집이 완료되지 않았습니다")
    if not samples:
        issues.append("표본이 없습니다")
    invalid_lines = session.get("invalidJSONLines", 0)
    if not _integer(invalid_lines) or invalid_lines < 0:
        issues.append("손상된 JSONL 행 수 미확인")
    elif invalid_lines:
        issues.append(f"손상 또는 비객체 JSONL 행 {invalid_lines}개: 폐기된 근거가 있어 전체 통과 불가")
    for key, text in (("backgroundQueryIncomplete", "백그라운드 조회가 종료되지 않았습니다"),
                      ("partialFinalLine", "마지막 JSONL 행이 완성되지 않았습니다")):
        if session.get(key) is True:
            issues.append(text)
        elif key in session and session[key] is not False:
            issues.append(text + " (수집 상태 미확인)")
    if (not _number(session.get("sampleIntervalSeconds")) or session["sampleIntervalSeconds"] <= 0
            or session["sampleIntervalSeconds"] > MAXIMUM_GAP or session.get("maximumGapSeconds") != MAXIMUM_GAP):
        issues.append("표본 간격·최대 공백 설정 미확인")
    for key in ("startedAt", "endedAt", "startedContinuous", "endedContinuous"):
        if not _number(session.get(key)):
            issues.append("세션 시작·종료 시각 미확인")
            break
    if (all(_number(session.get(k)) for k in ("startedAt", "endedAt", "startedContinuous", "endedContinuous"))
            and (session["endedAt"] < session["startedAt"] or session["endedContinuous"] < session["startedContinuous"])):
        issues.append("세션 시계 역전")
    for index, row in enumerate(samples):
        clock_keys = ("capturedAt", "completedAt", "continuous", "completedContinuous")
        if (not _integer(row.get("sequence")) or row["sequence"] <= 0
                or not all(_number(row.get(k)) for k in clock_keys)
                or row.get("bootID") != boot):
            issues.append(f"표본 {index + 1}: 순서·시각·부팅 식별 미확인")
            continue
        if row["completedAt"] < row["capturedAt"] or row["completedContinuous"] < row["continuous"]:
            issues.append(f"표본 {row['sequence']}: 수집 중 시계 역전")
        if (all(_number(session.get(k)) for k in ("startedAt", "endedAt", "startedContinuous", "endedContinuous"))
                and not (session["startedAt"] <= row["capturedAt"] <= row["completedAt"] <= session["endedAt"]
                         and session["startedContinuous"] <= row["continuous"] <= row["completedContinuous"] <= session["endedContinuous"])):
            issues.append(f"표본 {row['sequence']}: 세션 범위를 벗어난 시각")
        if index:
            before = samples[index - 1]
            if not all(_number(before.get(k)) for k in clock_keys) or not _integer(before.get("sequence")):
                continue
            wall_gap = row["capturedAt"] - before["capturedAt"]
            continuous_gap = row["continuous"] - before["continuous"]
            if wall_gap < 0 or continuous_gap < 0 or row["sequence"] <= before["sequence"]:
                issues.append(f"표본 {row['sequence']}: 행 순서 또는 시계 역전")
            if wall_gap > MAXIMUM_GAP or continuous_gap > MAXIMUM_GAP or row["sequence"] != before["sequence"] + 1:
                gaps.append(dict(beforeSequence=before["sequence"], afterSequence=row["sequence"],
                                 wallSeconds=wall_gap, continuousSeconds=continuous_gap))
    if any(event.get("source") == "pmset" and not _number(event.get("at")) for event in events):
        issues.append("OS 사건 시각 미확인")
    issues = list(dict.fromkeys(issues))
    ac = _ac_check(samples, queries, events, boot, build, bool(issues))
    unplug = _unplug_check(samples, queries, events, boot, build, bool(issues))
    owners, display, timers, protection = [], [], [], []
    seen_owners = set()
    for row in samples:
        native, common, helper = _native(row), _common(row), _helper(row)
        state = _object(common.get("status"))
        bridge = _object(helper.get("bridge"))
        display.append(dict(sequence=row.get("sequence"), at=_native_at(row), fresh=_native_fresh(row, build),
                            lidClosed=native.get("lidClosed"), displaySleeping=native.get("displaySleeping"),
                            topology=native.get("displayTopology")))
        protection.append(dict(sequence=row.get("sequence"), at=_native_at(row), fresh=_native_fresh(row, build),
                               blockReason=state.get("blockReason"), thermal=native.get("thermal"),
                               batteryPercent=native.get("batteryPercent"), batteryTemperature=native.get("batteryTemperature"),
                               helperBlockReason=_object(helper.get("protection")).get("blockReason"),
                               errorPresent=_error_present(state) or _error_present(common) or _error_present(helper)
                                            or _error_present(_object(helper.get("protection"))),
                               latch=bridge.get("lidProtection")))
        receipts = bridge.get("batteryPermitReceipts")
        receipts = receipts if isinstance(receipts, list) and len(receipts) <= 128 else []
        if receipts or any(state.get(key) is not None for key in ("manualContinuousDeadline", "batteryHoldUntil", "until",
                                                                "manualRemaining", "batteryRemaining", "manualBatteryRemaining")):
            timers.append(dict(sequence=row.get("sequence"), at=row.get("capturedAt"),
                               fresh=common.get("ok") is True and common.get("build") == build
                                     and not _error_present(common) and not _error_present(state)
                                     and _fresh(common.get("observedAt"), row.get("completedAt")),
                               manualActive=state.get("manualActive"), automaticActive=state.get("automaticActive"),
                               manualRemaining=state.get("manualRemaining"), batteryRemaining=state.get("batteryRemaining"),
                               manualBatteryRemaining=state.get("manualBatteryRemaining"), until=state.get("until"),
                               manualDeadline=state.get("manualContinuousDeadline"), batteryUntil=state.get("batteryHoldUntil"),
                               batteryPermitReceipts=receipts))
        assertion = _object(row.get("assertions"))
        if assertion.get("available") is True and isinstance(assertion.get("owners"), list):
            for owner in assertion["owners"]:
                owner = _object(owner)
                if not _integer(owner.get("pid")) or not isinstance(owner.get("type"), str):
                    continue
                key = (owner["pid"], owner["type"])
                if key not in seen_owners:
                    seen_owners.add(key)
                    owners.append(dict(pid=owner["pid"], type=owner["type"][:80]))
    timeline = [dict(at=event.get("at"), source=event.get("source"), kind=event.get("kind"),
                     event=str(event.get("event", ""))[:160], fields=_object(event.get("fields")))
                for event in events if _number(event.get("at")) and event.get("source") in ("pmset", "helper", "common")]
    verdict = "fail" if ac["verdict"] == "fail" else "pass" if not issues and "pass" in (ac["verdict"], unplug["verdict"]) else "unknown"
    outcomes = [ac["verdict"], unplug["verdict"], "unknown"]
    counts = dict(passCount=outcomes.count("pass"), failCount=outcomes.count("fail"), unknownCount=outcomes.count("unknown"), total=len(outcomes))
    return dict(schemaVersion=1, verdict=verdict,
                summary={"pass": "검증한 항목의 물리 근거를 확인했습니다. 전체 물리 시험 완료를 뜻하지 않습니다.",
                         "fail": "유지 승인 중 실제 Sleep을 관측했습니다.", "unknown": "물리 시험 결과를 확정할 근거가 부족합니다."}[verdict],
                outcomeCounts=counts,
                scope=dict(mode=session.get("mode"), phase=session.get("phase"), appBuild=session.get("appBuild"),
                           bootID=boot, startedAt=session.get("startedAt"), endedAt=session.get("endedAt"), completeAcceptance=False),
                integrity=dict(issues=issues, gaps=gaps, sampleCount=len(samples)),
                readiness=_readiness(session, samples), querySummary=_query_summary(queries, samples),
                checks=dict(acClosedLid=ac, closedLidUnplug=unplug,
                            timerProtection=_result("unknown", "타이머 만료·보호 전이는 별도 시험 대상입니다. 미실시를 통과로 판정하지 않습니다.")),
                observations=dict(display=dict(samples=display, summary="화면 절전의 OS 관측만 표시합니다. 패널 전력 0이나 원격 성공을 뜻하지 않습니다."),
                                  lock=_result("unknown", "화면 꺼짐·잠금 선택·비밀번호 정책으로 현재 잠금 상태나 원격 입력 성공을 판정하지 않습니다."),
                                  protection=protection, timers=timers,
                                  otherAppOwners=dict(candidates=owners, summary="요청 보유 후보입니다. 자기 요청과 외부 요청의 구분이나 실제 충돌·Sleep 원인을 확정하지 않습니다.")),
                timeline=timeline)


def _cell(value):
    if value is None:
        return "미확인"
    if isinstance(value, bool):
        return "예" if value else "아니오"
    if _number(value):
        return str(round(value, 3))
    return str(value)[:300].replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def _stamp(value):
    if not _number(value):
        return "미확인"
    try:
        utc = datetime.fromtimestamp(value, timezone.utc)
        kst = utc.astimezone(timezone(timedelta(hours=9)))
        return (kst.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + " KST / "
                + utc.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + " UTC")
    except (ValueError, OverflowError, OSError):
        return "미확인"


def _table(lines, headers, rows):
    lines.extend(["", "| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"])
    for row in rows:
        lines.append("| " + " | ".join(_cell(value) for value in row) + " |")
    lines.append("")


def _visible(rows, maximum=20):
    """Keep original order, retaining both start and end of long sessions."""
    if len(rows) <= maximum:
        return rows
    return rows[:maximum // 2] + rows[-maximum // 2:]


def markdown(report: dict) -> str:
    """Render Korean evidence notes; a partial pass is never full acceptance."""
    report = _object(report)
    labels = {"pass": "통과", "fail": "실패", "unknown": "미확인"}
    counts, scope = _object(report.get("outcomeCounts")), _object(report.get("scope"))
    lines = [f"물리 시험 분석: {labels.get(report.get('verdict'), '미확인')}", "", report.get("summary", ""), "",
             f"판정 범위: {counts.get('total', 3)}항목 중 통과 {counts.get('passCount', 0)}, 실패 {counts.get('failCount', 0)}, 미확인 {counts.get('unknownCount', 3)}. 전체 기능의 승인·시험 완료 판정은 아닙니다.", "",
             f"시험 앱 빌드: {_cell(scope.get('appBuild'))} · mode={_cell(scope.get('mode'))} · phase={_cell(scope.get('phase'))}",
             f"시작: {_stamp(scope.get('startedAt'))}", f"종료: {_stamp(scope.get('endedAt'))}",
             "", "아래 표는 시작·종료를 포함한 최대 20개 표본을 표시합니다. 전체 근거는 원본 JSONL과 분석 JSON에 보존됩니다.", ""]
    checks = _object(report.get("checks"))
    latency_labels = {"powerSampleToSleepSeconds": "분리 표본→Sleep", "releaseEvidenceToSleepSeconds": "해제 근거→Sleep",
                      "sleepToWakeSeconds": "Sleep→Wake", "wakeToOpenSampleSeconds": "Wake→열림 표본"}
    for name, title in (("acClosedLid", "닫힌 AC 유지"), ("closedLidUnplug", "닫힌 전원 분리"), ("timerProtection", "타이머·보호")):
        result = _object(checks.get(name))
        lines.extend([f"- {title}: {labels.get(result.get('verdict'), '미확인')} — {result.get('summary', '')}"])
        for interval in result.get("intervals", []):
            lines.extend(["", f"표본 {interval.get('firstSequence')}~{interval.get('lastSequence')}, 연속 {_cell(interval.get('durationSeconds'))}초: {labels.get(interval.get('verdict'), '미확인')}",
                          f"구간: {_stamp(interval.get('startedAt'))} → {_stamp(interval.get('endedAt'))}",
                          f"OS 범위 조회 행: {_cell(interval.get('coverageQuery'))} · 실제 Sleep 기록: {len(interval.get('sleepEvents', []))}개"])
            if interval.get("missing"):
                lines.append("근거 공백: " + ", ".join(interval["missing"]))
            for at in interval.get("sleepEvents", []):
                lines.append("실제 Sleep: " + _stamp(at))
        for incident in result.get("incidents", []):
            lines.extend(["", f"전원 전환 표본 {incident.get('beforeSequence')}→{_cell(incident.get('batterySequence'))}: {labels.get(incident.get('verdict'), '미확인')}"])
            if incident.get("conditionEvidence") == "helperFinalPredicate":
                lines.extend(["분리 직후 native 행 미수집: 닫힘·배터리 조건은 helper 최종 승인 계약 근거이며 직접 표본 확인과 구분합니다.",
                              "분리 사건 포착 시각: " + _stamp(incident.get("disconnectObservedAt")),
                              f"선행 유한 lease sequence={_cell(incident.get('sourceLeaseSequence'))}, expiry(continuous)={_cell(incident.get('sourceLeaseExpiry'))}; 종료 action={_cell(incident.get('receiptAction'))}, phase={_cell(incident.get('receiptPhase'))}"])
            for index, at in enumerate(incident.get("powerObservedBetween", [])):
                lines.append(("AC 표본: " if index == 0 else "배터리 표본: ") + _stamp(at))
            lines.extend(["실제 Sleep: " + _stamp(incident.get("sleepAt")), "실제 Wake: " + _stamp(incident.get("wakeAt")),
                          f"이후 열림/Full Wake 표본: {_cell(incident.get('openedSequence'))}"])
            if incident.get("release"):
                receipt = incident["release"]
                lines.extend(["해제 근거: " + receipt["timestampMeaning"], "해제 근거 시각: " + _stamp(receipt.get("at"))])
            if incident.get("missing"):
                lines.append("근거 공백: " + ", ".join(incident["missing"]))
            if incident.get("latencies"):
                lines.append("관측 간격(초): " + ", ".join(f"{latency_labels.get(key, key)}={_cell(value)}" for key, value in incident["latencies"].items()))
                lines.append("pmset 사건은 초 단위이므로 최대 1초의 시각 반올림 차이가 있습니다. 분리 실제 시각과 원복 완료 지연은 표본·사건 포착 시각만으로 확정하지 않습니다.")
        lines.append("")
    readiness = _object(report.get("readiness"))
    lines.extend(["준비·설치 근거:", ""])
    lines.extend("- " + text for text in readiness.get("warnings", []))
    names = dict(appBuild="시험 앱 빌드", probeBuild="관측 도구 빌드", helperBuild="도우미 빌드",
                 closedLidEnabled="시작 시 덮개 유지 선택", nativeAvailable="독립 OS 관측", commonAvailable="공통 세션 응답", helperLive="live 도우미")
    preflight = _object(readiness.get("preflight"))
    if preflight:
        _table(lines, ["시작 전 준비", "관측 값"], [(names[key], value) for key, value in preflight.items() if key in names])
    else:
        lines.extend(["시작 전 준비 기록: 미확인", ""])
    file_names = dict(helper="도우미 실행 파일", helperRegistration="도우미 등록", watchdog="watchdog 실행 파일",
                      watchdogRegistration="watchdog 등록", recoveryLock="복구 잠금 실행 파일", recoveryExecutor="전원 복구 실행 파일")
    for phase, files in _object(readiness.get("helperFiles")).items():
        if files:
            lines.append("필수 파일 존재 근거 (" + ("시작" if phase == "start" else "종료") + "):")
            _table(lines, ["필수 구성", "존재", "실행 가능", "읽기 오류"],
                   [(file_names.get(name, name), _object(value).get("present"), _object(value).get("executable"),
                     _object(value).get("errorClass", "없음")) for name, value in files.items()])
    ready_rows = _visible(readiness.get("observed", []))
    if ready_rows:
        _table(lines, ["표본", "시각", "native/common/helper 빌드", "도우미/규약", "GUI 연결/권한", "덮개 승인", "덮개 선택", "자체 소유/OS SleepDisabled"],
               [(v.get("sequence"), _stamp(v.get("at")), "/".join(_cell(v.get(k)) for k in ("nativeBuild", "commonBuild", "helperBuild")),
                 f"{_cell(v.get('helperSource'))}/{_cell(v.get('coordinator'))}",
                 f"{_cell(v.get('appConnected'))}/{_cell(v.get('guiAuthority'))}", v.get("lidSupport"), v.get("allowClosedLid"),
                 f"{_cell(v.get('ownsOverride'))}/{_cell(v.get('sleepDisabled'))}") for v in ready_rows])
    lines.extend(["조회 성공·실패·제한:", "", "제한 횟수는 실패/미확인 횟수와 겹칠 수 있습니다. 로그 읽기 실패나 기록 없음은 사건이 없었다는 증명이 아닙니다."])
    _table(lines, ["source", "조회", "성공", "실패", "제한", "미확인", "읽기 불가 파일", "선택 회전 부재", "오류 분류"],
           [(v.get("source"), v.get("count"), v.get("succeeded"), v.get("failed"), v.get("limited"), v.get("unknown"),
             v.get("unavailableFiles"), v.get("missingOptionalRotations", 0),
             ", ".join(v.get("errorClasses", [])) or "없음") for v in report.get("querySummary", [])])
    for query in report.get("querySummary", []):
        lines.append(f"{_cell(query.get('source'))} 조회 범위: {_stamp(query.get('startedAt'))} → {_stamp(query.get('endedAt'))}")
    lines.extend(["", "수집의 시각·부팅·공백:", ""])
    integrity = _object(report.get("integrity"))
    lines.extend("- " + text for text in integrity.get("issues", []))
    for gap in integrity.get("gaps", []):
        lines.append(f"- 표본 {gap['beforeSequence']}→{gap['afterSequence']} 공백: wall={_cell(gap['wallSeconds'])}초, continuous={_cell(gap['continuousSeconds'])}초. 공백만으로 Sleep을 판정하지 않습니다.")
    if not integrity.get("issues") and not integrity.get("gaps"):
        lines.append("- 보관된 행의 시각·부팅 순서에서 공백을 발견하지 않았습니다.")
    observations = _object(report.get("observations"))
    lines.extend(["", "온도·보호 관측 근거:", "", "온도 값은 센서 관측입니다. 숫자만으로 보호 원인·발동·해제를 확정하지 않습니다. 열 압력은 OS thermal 원값(0 정상, 1 fair, 2 serious, 3 critical)입니다."])
    _table(lines, ["표본", "시각", "native 신선", "열 압력", "배터리 %", "배터리 °C", "common/helper 보호", "보호 latch", "오류 존재"],
           [(v.get("sequence"), _stamp(v.get("at")), v.get("fresh"), v.get("thermal"), v.get("batteryPercent"), v.get("batteryTemperature"),
             f"{_cell(v.get('blockReason'))}/{_cell(v.get('helperBlockReason'))}",
             _object(v.get("latch")).get("reason", "없음"), v.get("errorPresent")) for v in _visible(observations.get("protection", []))])
    lines.extend(["타이머 관측 근거:", "", "남은 용량·기한 필드는 실행 중임을 뜻하지 않습니다. active 상태와 함께 읽어야 하며, 타이머 만료·보호 후 실제 Sleep 시험은 미확인입니다. continuous 기한은 벽시계 시각과 분리해 표시합니다."])
    _table(lines, ["표본", "시각", "common 신선", "자동/수동 active", "수동 남음 초", "자동 배터리 남은 용량 초", "수동 배터리 남은 용량 초", "수동 continuous 기한", "수동 Until", "배터리 Until", "허가 ACK 수"],
           [(v.get("sequence"), _stamp(v.get("at")), v.get("fresh"),
             f"{_cell(v.get('automaticActive'))}/{_cell(v.get('manualActive'))}", v.get("manualRemaining"), v.get("batteryRemaining"),
             v.get("manualBatteryRemaining"), v.get("manualDeadline"), _stamp(v.get("until")), _stamp(v.get("batteryUntil")),
             len(v.get("batteryPermitReceipts", []))) for v in _visible(observations.get("timers", []))])
    lines.extend(["화면·잠금·외부 요청:", "", "- " + _object(observations.get("display")).get("summary", ""),
                  "- " + _object(observations.get("lock")).get("summary", ""),
                  "- " + _object(observations.get("otherAppOwners")).get("summary", "")])
    _table(lines, ["표본", "시각", "native 신선", "덮개 닫힘", "화면 절전", "displayTopology"],
           [(v.get("sequence"), _stamp(v.get("at")), v.get("fresh"), v.get("lidClosed"), v.get("displaySleeping"), v.get("topology"))
            for v in _visible(_object(observations.get("display")).get("samples", []))])
    _table(lines, ["후보 PID", "요청 type"], [(v.get("pid"), v.get("type"))
           for v in _visible(_object(observations.get("otherAppOwners")).get("candidates", []))])
    lines.extend(["허용된 OS/helper/common 사건 순서:", "", "보관된 사건 행 순서를 유지합니다. helper 명령 수락·willSleep ACK는 OS 실제 Sleep과 별도입니다."])
    allowed_fields = {"power", "lid", "fullWake", "enabled", "appConnected", "condition", "sleepDisabled", "owned",
                      "display", "displaySleeping", "hold", "thermal", "block", "systemPowerObservation", "nativeDisplay",
                      "displayRecovery", "displayRequests", "sleepDeferral", "manual", "guiAuthority", "event", "holding",
                      "automatic", "automaticEnabled", "manualRemaining", "batteryRemaining", "batteryPercent", "until",
                      "batteryUntil", "automaticMinutes", "pendingMinutes", "manualEnd", "canStart", "failed", "errorPresent"}
    _table(lines, ["시각", "source", "kind", "허용된 관측 값"],
           [(_stamp(v.get("at")), v.get("source"), v.get("kind"),
             ", ".join(f"{k}={_cell(value)}" for k, value in _object(v.get("fields")).items() if k in allowed_fields) or "없음")
            for v in _visible(report.get("timeline", []))])
    lines.append("명령 성공, SleepDisabled 해제, willSleep ACK와 watchdog 점검만으로 실제 Sleep을 통과시키지 않습니다.")
    return "\n".join(lines) + "\n"
