#!/usr/bin/env python3
"""Measure limited native AX layout evidence, without UI or production-state access.

This is a declared product rubric, not an aesthetics, WCAG or usability rating.
Unknown checks never contribute verified points or inflate the known denominator.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import unicodedata


RULES = [
    ("finite_positive_frames", "geometry", 10),
    ("actionable_window_bounds", "geometry", 15),
    ("menu_width", "geometry", 5),
    ("static_text_horizontal_bounds", "geometry", 10),
    ("independent_action_overlap", "control", 10),
    ("recommended_target_height", "control", 10),
    ("essential_text_visibility", "readability", 10),
    ("rendered_contrast", "readability", 10),
    ("keyboard_activation", "interaction", 10),
    ("pointer_activation", "interaction", 10),
]
ACTION_TYPES = {"button", "switch", "radiobutton", "popupbutton", "checkbox",
                "textfield", "searchfield", "slider", "stepper", "combobox",
                "menuitem", "disclosuretriangle", "segmentedcontrol", "toggle",
                "menubutton", "toolbarbutton", "securetextfield", "textview", "link", "tab",
                "row", "cell", "tablerow", "outlinerow"}
COMPOSITE_TYPES = {"segmentedcontrol", "combobox", "popupbutton"}
PROMINENT_TARGETS = {"panel-start-manual", "panel-pause-all"}
APP_CONTROL_PREFIXES = ("panel-", "custom-duration-", "settings-", "ui-fixture-")
TOLERANCE = 0.5
MENU_WIDTH_POINTS = 300
MENU_WIDTH_TOLERANCE_POINTS = 1


def frame(value):
    if isinstance(value, dict) and "frame" in value:
        value = value["frame"]
    if not isinstance(value, dict):
        return None
    numbers = [value.get(key) for key in ("x", "y", "width", "height")]
    if any(isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n)
           for n in numbers):
        return None
    if numbers[2] <= 0 or numbers[3] <= 0:
        return None
    return dict(zip(("x", "y", "width", "height"), numbers))


def element_type(element):
    value = element.get("elementType", "")
    if not isinstance(value, str):
        return ""
    return value.lower().replace("xcuielementtype", "").replace("ax", "").replace("_", "")


def contains(outer, inner, horizontal_only=False):
    horizontal = (inner["x"] >= outer["x"] - TOLERANCE and
                  inner["x"] + inner["width"] <= outer["x"] + outer["width"] + TOLERANCE)
    return horizontal and (horizontal_only or (
        inner["y"] >= outer["y"] - TOLERANCE and
        inner["y"] + inner["height"] <= outer["y"] + outer["height"] + TOLERANCE))


def intersects(first, second):
    return (min(first["x"] + first["width"], second["x"] + second["width"]) -
            max(first["x"], second["x"]) > TOLERANCE and
            min(first["y"] + first["height"], second["y"] + second["height"]) -
            max(first["y"], second["y"]) > TOLERANCE)


def observed_scroll_viewport(element, scrolls):
    """Accept only a collector-observed, exactly matched scroll descendant relation."""
    observed = element.get("observedScrollViewport")
    if observed is None:
        return None, None
    if not isinstance(observed, dict):
        return None, "observedScrollViewport must be an observed relationship or null"
    index = observed.get("queryIndex")
    viewport = frame(observed.get("frame"))
    if (observed.get("relationship") != "typed-descendant-exact-match" or
            type(index) is not int or not 0 <= index < len(scrolls) or viewport is None):
        return None, "Invalid observedScrollViewport relationship, queryIndex or frame"
    if viewport != frame(scrolls[index]):
        return None, "observedScrollViewport frame does not exactly match its captured scrollViews entry"
    return viewport, None


def disjoint(first, second):
    # No rounding tolerance here: a control intersecting even a fraction of its
    # viewport remains subject to the ordinary window-clipping check.
    return (first["x"] + first["width"] <= second["x"] or
            second["x"] + second["width"] <= first["x"] or
            first["y"] + first["height"] <= second["y"] or
            second["y"] + second["height"] <= first["y"])


def label(element, index):
    return element.get("identifier") or element.get("label") or (
        index if isinstance(index, str) else "element[" + str(index) + "]")


def ancestry_known(element):
    ancestors = element.get("ancestorIdentifiers")
    return (isinstance(ancestors, list) and all(isinstance(value, str) for value in ancestors) or
            isinstance(element.get("parentIdentifier"), str) and bool(element["parentIdentifier"]))


def related(first, second):
    first_id, second_id = first.get("identifier"), second.get("identifier")
    if first_id and first_id == second_id:
        return True
    if (first.get("duplicateOf") and first.get("duplicateOf") == second_id or
            second.get("duplicateOf") and second.get("duplicateOf") == first_id):
        return True
    for child, parent_id in ((first, second_id), (second, first_id)):
        ancestors = child.get("ancestorIdentifiers")
        if parent_id and (child.get("parentIdentifier") == parent_id or
                          isinstance(ancestors, list) and parent_id in ancestors):
            return True
    return False


def valid_sha256(value):
    return (isinstance(value, str) and len(value) == 64 and
            all(character in "0123456789abcdef" for character in value.lower()))


def normalized_text(value):
    # Korean OCR may insert/remove inter-word spaces; punctuation is not content.
    return "".join(character for character in unicodedata.normalize("NFKC", value).casefold()
                   if not character.isspace() and not unicodedata.category(character).startswith("P"))


def essential_text_evidence(capture, source):
    checks = capture.get("textChecks") if isinstance(capture, dict) else None
    if not isinstance(checks, list) or not checks:
        return "unknown", "No derived screenshot/OCR text audit; AX full strings cannot prove visible text", []
    statuses, issues = [], []
    for check in checks:
        name = str(check.get("id", "text-check")) if isinstance(check, dict) else "text-check"
        expected = check.get("expectedSnippet") if isinstance(check, dict) else None
        image_hash = check.get("screenshotSHA256") if isinstance(check, dict) else None
        evidence_path = check.get("ocrEvidencePath") if isinstance(check, dict) else None
        if not isinstance(expected, str) or not normalized_text(expected) or not valid_sha256(image_hash) or not isinstance(evidence_path, str):
            statuses.append("unknown"); issues.append(name + ": missing expected text, screenshot hash or OCR evidence path")
            continue
        try:
            path = Path(evidence_path)
            if not path.is_absolute():
                path = source.parent / path
            evidence = json.loads(path.read_text())
        except (OSError, ValueError, UnicodeError):
            evidence = None
        if (not isinstance(evidence, dict) or evidence.get("screenshotSHA256") != image_hash or
                not isinstance(evidence.get("method"), str) or "vision" not in evidence["method"].lower() or
                not isinstance(evidence.get("lines"), list)):
            statuses.append("unknown"); issues.append(name + ": matching Apple Vision screenshot evidence unavailable")
            continue
        image_path = evidence.get("source")
        if not isinstance(image_path, str):
            statuses.append("unknown"); issues.append(name + ": source screenshot path unavailable")
            continue
        image = Path(image_path)
        if not image.is_absolute():
            image = path.parent / image
        try:
            screenshot_verified = hashlib.sha256(image.read_bytes()).hexdigest() == image_hash
        except OSError:
            screenshot_verified = False
        if not screenshot_verified:
            statuses.append("unknown"); issues.append(name + ": source screenshot hash could not be verified")
            continue
        high_confidence = [line["text"] for line in evidence["lines"] if isinstance(line, dict) and
                           isinstance(line.get("text"), str) and type(line.get("confidence")) in (int, float) and
                           math.isfinite(line["confidence"]) and 0.8 <= line["confidence"] <= 1]
        if normalized_text(expected) in normalized_text(" ".join(high_confidence)):
            statuses.append("pass")
        elif check.get("status") == "fail" and check.get("visualConfirmedClipping") is True and high_confidence:
            statuses.append("fail"); issues.append(name + ": derived screenshot review confirms clipped essential text, corroborated by OCR")
        else:
            statuses.append("unknown"); issues.append(name + ": OCR absence/low confidence does not prove clipping")
    status = "fail" if "fail" in statuses else "unknown" if "unknown" in statuses else "pass"
    return status, "Derived screenshot audit, not native AX text; high-confidence OCR proves included snippets only", issues


def measured_contrast_evidence(capture, source):
    # A PNG hash binds a file, not caller-supplied foreground/background RGB to
    # its rendered pixels. Until an actual sampling backend exists, neither
    # measuredColors nor a claimed method/trusted flag can earn verified points.
    return ("unknown", "Rendered contrast is unmeasured: no pixel-sampling backend; "
            "JSON RGB, source palette and screenshot hashes cannot prove Glass or text contrast", [])


def native_interaction_evidence(capture, native_result):
    if not isinstance(native_result, dict):
        return False, "No matching native result; readonly AX flags do not prove activation"
    native_hash = native_result.get("sourceExecutableSHA256")
    provenance = capture.get("provenance", {}) if isinstance(capture, dict) else {}
    if not provenance and isinstance(capture, dict) and isinstance(capture.get("meta"), dict):
        provenance = capture["meta"].get("provenance", {})
    captured_hash = provenance.get("sourceExecutableSHA256") if isinstance(provenance, dict) else None
    if not valid_sha256(native_hash) or captured_hash != native_hash:
        return False, "Native result and capture must provide the same sourceExecutableSHA256"
    counts = native_result.get("counts", {})
    fields = ["totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"]
    if (not isinstance(counts, dict) or any(type(counts.get(field)) is not int for field in fields) or
            counts["totalTestCount"] <= 0 or counts["passedTests"] != counts["totalTestCount"] or
            any(counts[field] != 0 for field in fields[2:])):
        return False, "Native tests must execute and all pass, with zero failures, skips and expected failures"
    if (native_result.get("status") != "passed" or native_result.get("xcodebuild_returncode") != 0 or
            native_result.get("xcodebuild_started") is not True or
            native_result.get("test_execution_started") is not True or
            native_result.get("runtimeWarningCount") != 0 or
            native_result.get("runtimeWarningLogCount") != 0 or
            native_result.get("runtimeWarnings") != []):
        return False, "Native process/result must pass with no runtime warnings"
    return True, "Matching native UI suite passed; aggregate interaction evidence, not per-element, production pixels or physical power acceptance"


def evaluate_capture(capture, source, recommend_minimum_target=False, native_result=None):
    checks, findings = {}, []

    def result(rule, status, reason, issues=(), hard=False):
        checks[rule] = {"status": status, "reason": reason}
        for issue in issues:
            findings.append({"rule": rule, "status": status,
                             "severity": "error" if hard else "recommendation" if status == "fail" else "note",
                             "hardFailure": hard, "message": issue})

    step = capture.get("step") if isinstance(capture, dict) and isinstance(capture.get("step"), str) else source.name
    surface = capture.get("surface") if isinstance(capture, dict) and isinstance(capture.get("surface"), str) else "unknown"
    valid_schema = (isinstance(capture, dict) and type(capture.get("schemaVersion")) is int and capture["schemaVersion"] == 1 and
                    isinstance(capture.get("elements"), list) and
                    isinstance(capture.get("step"), str) and isinstance(capture.get("surface"), str))
    window = frame(capture.get("windowFrame", capture.get("window"))) if valid_schema else None
    coherent = capture.get("sameWindowFrame") is not False if valid_schema else False
    elements = capture.get("elements", []) if valid_schema else []
    scrolls = capture.get("scrollViews", []) if valid_schema else []
    composites = capture.get("compositeElements", []) if valid_schema else []
    if not isinstance(scrolls, list):
        scrolls = [None]
    if not isinstance(composites, list):
        composites = [None]
    invalid = []
    if not valid_schema:
        invalid.append("Missing or unsupported schemaVersion=1, step, surface or elements array")
    if window is None:
        invalid.append("Window frame must contain finite coordinates and positive width/height")
    for index, element in enumerate(elements):
        if not isinstance(element, dict) or frame(element.get("frame")) is None:
            invalid.append("Invalid frame: element[" + str(index) + "]")
    for index, scroll in enumerate(scrolls):
        if frame(scroll) is None:
            invalid.append("Invalid frame: scrollViews[" + str(index) + "]")
    for index, composite in enumerate(composites):
        if not isinstance(composite, dict) or frame(composite) is None:
            invalid.append("Invalid frame: compositeElements[" + str(index) + "]")
    viewports = {}
    for collection_name, collection in (("elements", elements), ("compositeElements", composites)):
        for index, element in enumerate(collection):
            if not isinstance(element, dict):
                continue
            viewport, error = observed_scroll_viewport(element, scrolls)
            key = index if collection_name == "elements" else "compositeElements[" + str(index) + "]"
            if error:
                invalid.append(collection_name + "[" + str(index) + "]: " + error)
            elif viewport is not None:
                viewports[key] = viewport
    result("finite_positive_frames", "fail" if invalid else "pass",
           "AX evidence validity, not a rendered-pixel quality judgment", invalid)

    usable = [(index, element, frame(element.get("frame"))) for index, element in enumerate(elements)
              if isinstance(element, dict) and frame(element.get("frame")) is not None]
    # A collector can keep composite native parents separate from leaf elements.
    # They still own real click/target bounds, even though overlap checks exclude them.
    for index, composite in enumerate(composites):
        if (isinstance(composite, dict) and frame(composite) is not None and
                not any(composite == element for _, element, _ in usable)):
            usable.append(("compositeElements[" + str(index) + "]", composite, frame(composite)))
    candidate_actions = [(i, e, f) for i, e, f in usable if element_type(e) in ACTION_TYPES and
                         (e.get("hittable") is True or e.get("visible") is True)]
    offscreen_scroll_actions = {i for i, _, f in candidate_actions if i in viewports and
                                disjoint(viewports[i], f)}
    actions = [(i, e, f) for i, e, f in candidate_actions if i not in offscreen_scroll_actions]
    if window is None:
        for rule in ("actionable_window_bounds", "menu_width", "independent_action_overlap",
                     "recommended_target_height", "static_text_horizontal_bounds"):
            result(rule, "unknown", "A valid window frame is required")
    else:
        clipped = [label(e, i) + " is outside the window bounds" for i, e, f in actions if not contains(window, f)]
        result("actionable_window_bounds", "fail" if clipped else "pass" if actions else "unknown",
               "Visible/hittable action bounds, with 0.5pt rounding tolerance; only fully offscreen controls with an exactly matched observed scroll descendant relation are excluded (" + str(len(offscreen_scroll_actions)) + ")",
               clipped, hard=bool(clipped))
        actual_menu = surface.lower() in {"menu", "menubarextra", "menu-bar-extra", "menu_panel"}
        menu_bad = actual_menu and abs(window["width"] - MENU_WIDTH_POINTS) > MENU_WIDTH_TOLERANCE_POINTS
        result("menu_width", "fail" if menu_bad else "pass" if actual_menu else "unknown",
               f"Tether's documented actual-menu width is {MENU_WIDTH_POINTS}±{MENU_WIDTH_TOLERANCE_POINTS}pt; it is not an Apple mandate",
               ["Actual menu window width is " + str(window["width"]) + "pt"] if menu_bad else [])

        overlap, uncertain, comparable_pairs = [], [], 0
        composite_ids = {element["identifier"] for element in composites if isinstance(element, dict) and
                         isinstance(element.get("identifier"), str) and element["identifier"]}
        for position, (i, first, first_frame) in enumerate(actions):
            for j, second, second_frame in actions[position + 1:]:
                if related(first, second) or first.get("composite") is True or second.get("composite") is True:
                    continue
                if element_type(first) in COMPOSITE_TYPES or element_type(second) in COMPOSITE_TYPES:
                    continue
                if first.get("identifier") in composite_ids or second.get("identifier") in composite_ids:
                    continue
                if first == second:
                    continue
                crossing = intersects(first_frame, second_frame)
                if not ancestry_known(first) or not ancestry_known(second):
                    if crossing:
                        uncertain.append(label(first, i) + " / " + label(second, j) +
                                         ": overlapping bounds, but AX ancestry is missing")
                    else:
                        comparable_pairs += 1
                    continue
                comparable_pairs += 1
                if crossing:
                    overlap.append(label(first, i) + " overlaps independent action " + label(second, j))
        status = "fail" if overlap else "unknown" if uncertain or not comparable_pairs else "pass"
        result("independent_action_overlap", status,
               "Parent/child, composite and duplicate AX controls are excluded; missing ancestry cannot prove a collision",
               overlap if overlap else uncertain, hard=bool(overlap))
        targets = [(i, e, f, 24 if e.get("identifier") in PROMINENT_TARGETS else 22)
                   for i, e, f in actions if e.get("identifier") in PROMINENT_TARGETS or
                   recommend_minimum_target and isinstance(e.get("identifier"), str) and
                   e["identifier"].startswith(APP_CONTROL_PREFIXES) and e.get("osStandard") is not True]
        small = [label(e, i) + " has " + str(f["height"]) + "pt height (<" + str(minimum) + "pt)"
                 for i, e, f, minimum in targets if f["height"] + TOLERANCE < minimum]
        result("recommended_target_height", "fail" if small else "pass" if targets else "unknown",
               "Prominent Start/Pause product contract is 24pt; optional other-app-control recommendation is 22pt. OS traffic-light controls are excluded; neither is WCAG conformance or a hard gate", small)
        texts = [(i, e, f) for i, e, f in usable if element_type(e) == "statictext"]
        text_clips = [label(e, i) + " extends horizontally beyond the window" for i, e, f in texts
                      if not contains(window, f, horizontal_only=True)]
        result("static_text_horizontal_bounds", "fail" if text_clips else "pass" if texts else "unknown",
               "AX text bounds only; vertical offscreen scroll text is expected, and intrinsic truncation is unmeasured",
               text_clips, hard=bool(text_clips))

    text_status, text_reason, text_issues = essential_text_evidence(capture, source)
    result("essential_text_visibility", text_status if not invalid else "unknown", text_reason,
           text_issues, hard=text_status == "fail" and not invalid)
    contrast_status, contrast_reason, contrast_issues = measured_contrast_evidence(capture, source)
    result("rendered_contrast", contrast_status if not invalid else "unknown", contrast_reason, contrast_issues)
    interaction_known, interaction_reason = native_interaction_evidence(capture, native_result)
    for rule in ["keyboard_activation", "pointer_activation"]:
        result(rule, "pass" if interaction_known and not invalid else "unknown", interaction_reason)
    if not coherent or invalid:
        geometry_rules = {rule for rule, group, _ in RULES if group in {"geometry", "control"} and
                          (not coherent or rule != "finite_positive_frames")}
        findings = [finding for finding in findings if finding["rule"] not in geometry_rules]
        for rule in geometry_rules:
            checks[rule] = {"status": "unknown", "reason": "Window frame changed or frame evidence is invalid; complete geometry cannot be verified"}
    if valid_schema and (capture.get("measurementCompleteness") == "partial" or
                         isinstance(capture.get("unmeasuredElements"), list) and
                         bool(capture["unmeasuredElements"])):
        # Remaining nodes cannot establish safety for nodes the collector could
        # not measure. Preserve confirmed observed failures, never award a
        # whole-screen geometry/control pass from an incomplete node set.
        for rule, group, _ in RULES:
            if group in {"geometry", "control"} and checks[rule]["status"] == "pass":
                checks[rule] = {"status": "unknown", "reason": "Partial element measurement; unmeasured nodes prevent complete geometry/control verification"}
    return {"source": str(source), "step": step, "surface": surface,
            "rules": checks, "findings": findings, "invalidEvidence": bool(invalid), "sameWindowFrame": coherent}


def evaluate_directory(directory, recommend_minimum_target=False, native_result=None):
    directory = Path(directory)
    captures = []
    for source in sorted(directory.rglob("*layout*.json")) if directory.is_dir() else []:
        try:
            raw = source.read_bytes()
            capture = json.loads(raw)
        except (OSError, ValueError, UnicodeError) as error:
            captures.append({"source": str(source), "step": source.name, "surface": "unknown",
                             "rules": {rule: {"status": "unknown", "reason": "Unreadable capture: " + str(error)}
                                       for rule, _, _ in RULES}, "findings": [], "invalidEvidence": True})
            continue
        measured = evaluate_capture(capture, source, recommend_minimum_target, native_result)
        measured["sha256"] = hashlib.sha256(raw).hexdigest()
        captures.append(measured)
    count = len(captures)
    passed_weight = known_weight = 0.0
    groups = {name: {"weight": weight, "verifiedPoints": 0.0, "knownWeight": 0.0}
              for name, weight in [("geometry", 40), ("control", 20), ("readability", 20), ("interaction", 20)]}
    findings = []
    for capture in captures:
        for rule, group, weight in RULES:
            status = capture["rules"][rule]["status"]
            contribution = weight / count
            if status != "unknown":
                known_weight += contribution
                groups[group]["knownWeight"] += contribution
            if status == "pass":
                passed_weight += contribution
                groups[group]["verifiedPoints"] += contribution
        for finding in capture["findings"]:
            findings.append(dict(finding, source=capture["source"], step=capture["step"]))
    if not count:
        findings.append({"rule": "capture_presence", "status": "unknown", "severity": "note",
                         "hardFailure": False, "message": "No *layout*.json captures; no verified points"})
    hard_failures = sum(f.get("hardFailure", False) for f in findings)
    valid_captures = sum(not c["invalidEvidence"] for c in captures)
    return {
        "schemaVersion": 1,
        "status": "failed" if hard_failures else "incomplete" if not valid_captures else "measured",
        "rubric": {"type": "declared_product_rubric", "notMeasured": "aesthetics, WCAG certification or overall usability",
                   "weights": {name: value["weight"] for name, value in groups.items()},
                   "aggregation": "Equal screen weights for each rule; unknown never counts as passed or known",
                   "boundsTolerancePoints": TOLERANCE, "menuWidthPoints": MENU_WIDTH_POINTS,
                   "menuWidthTolerancePoints": MENU_WIDTH_TOLERANCE_POINTS,
                   "minimumTargetRecommendationEnabled": recommend_minimum_target},
        "score": {"partialScore": round(100 * passed_weight / known_weight, 2) if known_weight else None,
                  "totalVerifiedPoints": round(passed_weight, 2), "maximumPoints": 100,
                  "knownWeight": round(known_weight, 2), "unknownWeight": round(100 - known_weight, 2)},
        "coverage": {"weightedPercent": round(known_weight, 2), "captures": count,
                     "validCaptures": valid_captures, "hardFailures": hard_failures},
        "acceptanceBoundary": "Readonly AX and optional matching native suite; not production pixels, physical lid/Sleep, remote-client or minimum-OS acceptance",
        "unmeasured": ["General intrinsic text truncation beyond explicit screenshot textChecks", "Visual aesthetics or preference", "Uncaptured screens and rendered backgrounds"],
        "groups": {name: {key: round(value, 2) for key, value in data.items()}
                   for name, data in groups.items()},
        "rules": [{"id": rule, "group": group, "weight": weight} for rule, group, weight in RULES],
        "captures": captures, "findings": findings,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Directory recursively containing *layout*.json captures")
    parser.add_argument("--report", type=Path, help="Optional JSON report path; input captures are read only")
    parser.add_argument("--native-result", type=Path,
                        help="Optional actual native runner result.json, matched to each capture's provenance hash")
    parser.add_argument("--recommend-minimum-target", action="store_true",
                        help="Measure the optional 22pt identified-control recommendation")
    args = parser.parse_args()
    native_result = None
    if args.native_result:
        try:
            native_result = json.loads(args.native_result.read_text())
        except (OSError, ValueError, UnicodeError) as error:
            native_result = {"loadError": str(error)}
    report = evaluate_directory(args.input, args.recommend_minimum_target, native_result)
    encoded = json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    if args.report:
        if "layout" in args.report.name.lower():
            parser.error("Report filename must not contain 'layout' and become a future input capture")
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(encoded)
    print(encoded, end="")
    return 1 if report["status"] == "failed" else 2 if report["status"] == "incomplete" else 0


if __name__ == "__main__":
    raise SystemExit(main())
