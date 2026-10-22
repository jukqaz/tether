#!/usr/bin/env python3
"""Prepare source-linked native design captures without scoring or changing originals.

Only exact test/step/device/configuration matches are joined. A prepared audit input
is not a passed native test, visual approval, OCR completeness or clipping verdict.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


class AuditError(RuntimeError):
    pass


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
UUID_PATTERN = r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}"
PNG_NAME = re.compile(r"(.+)_\d+_" + UUID_PATTERN + r"\.png")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def decode_json(data, description):
    def invalid_constant(value):
        raise ValueError("Nonfinite JSON number: " + value)
    try:
        return json.loads(data, parse_constant=invalid_constant)
    except (ValueError, UnicodeError) as error:
        raise AuditError(f"Invalid JSON in {description}: {error}") from error


def attachment_path(root, name):
    # Exported attachment names are basenames, never user-controlled paths.
    if not isinstance(name, str) or not name or name in (".", "..") or \
            "/" in name or "\\" in name or Path(name).is_absolute():
        raise AuditError(f"Unsafe exported attachment filename: {name!r}")
    path = root / name
    if path.is_symlink():
        raise AuditError(f"Symbolic-link attachment is not accepted: {name}")
    try:
        path.resolve(strict=True).relative_to(root)
    except (OSError, ValueError) as error:
        raise AuditError(f"Missing or escaped attachment: {name}") from error
    if not path.is_file():
        raise AuditError(f"Attachment is not a regular file: {name}")
    return path


def manifest_entries(manifest, root):
    if not isinstance(manifest, list):
        raise AuditError("Attachment manifest must be a list of test entries")
    entries = []
    for group in manifest:
        if not isinstance(group, dict) or not isinstance(group.get("testIdentifier"), str) or \
                not group["testIdentifier"] or not isinstance(group.get("attachments"), list):
            raise AuditError("Malformed attachment manifest test entry")
        for item in group["attachments"]:
            if not isinstance(item, dict):
                raise AuditError("Malformed attachment manifest attachment")
            path = attachment_path(root, item.get("exportedFileName"))
            entries.append({"path": path, "attachment": item,
                            "testIdentifier": group["testIdentifier"],
                            "testIdentifierURL": group.get("testIdentifierURL")})
    return entries


def valid_frame(value):
    if not isinstance(value, dict):
        return False
    values = [value.get(key) for key in ("x", "y", "width", "height")]
    return all(isinstance(item, (int, float)) and not isinstance(item, bool) and
               math.isfinite(item) for item in values) and values[2] > 0 and values[3] > 0


def test_identity(value):
    if not isinstance(value, str):
        return None
    # XCTestCase.name uses Objective-C notation; the export uses Class/method().
    objc = re.fullmatch(r"-\[([\w.]+) ([\w]+)(?:\(\))?\]", value)
    exported = re.fullmatch(r"([\w.]+)/([\w]+)(?:\(\))?", value)
    match = objc or exported
    return (match[1].split(".")[-1], match[2]) if match else None


def excluded_capture(step, entry):
    return "failure" in step.lower() or step.startswith(("launch-", "missing-", "not-hittable-")) or \
        entry["attachment"].get("isAssociatedWithFailure") is True


def provenance_for(capture, layout, screenshot, run, result_path, result_hash, manifest_path, manifest_hash):
    observed = capture.get("meta", {}).get("provenance") if isinstance(capture.get("meta"), dict) else None
    if not isinstance(observed, dict):
        raise AuditError("Capture lacks observed fixture provenance: " + str(layout["path"]))
    for observed_key, result_key in (("fixtureBundleIdentifier", "fixture_bundle_id"),
                                     ("fixtureExecutablePath", "fixtureExecutablePath")):
        expected = run.get(result_key)
        if not isinstance(expected, str) or not expected or observed.get(observed_key) != expected:
            raise AuditError(f"Fixture provenance mismatch ({observed_key}): {layout['path']}")
    observed_test = test_identity(observed.get("testName"))
    manifest_test = test_identity(layout["testIdentifier"])
    if observed_test is None or observed_test != manifest_test:
        raise AuditError("Capture testName differs from manifest testIdentifier: " + str(layout["path"]))
    source_hash = run.get("sourceExecutableSHA256")
    if not isinstance(source_hash, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", source_hash):
        raise AuditError("Native result has no valid sourceExecutableSHA256")
    already_observed = observed.get("sourceExecutableSHA256")
    if already_observed not in (None, "", source_hash):
        raise AuditError("Capture source hash contradicts its native result")
    return {"sourceExecutableSHA256": source_hash,
            "nativeResultSHA256": result_hash, "nativeResultPath": str(result_path),
            "nativeResultStatus": run.get("status", "unknown"),
            "nativeResultStartedAt": run.get("started_at"), "nativeResultFinishedAt": run.get("finished_at"),
            "fixtureBundleIdentifier": observed["fixtureBundleIdentifier"],
            "fixtureExecutablePath": observed["fixtureExecutablePath"],
            "fixtureExecutableSHA256": run.get("fixtureExecutableSHA256"),
            "rawLayoutSHA256": sha256(layout["raw"]), "rawLayoutSourcePath": str(layout["path"]),
            "screenshotSHA256": sha256(screenshot["raw"]), "screenshotSourcePath": str(screenshot["path"]),
            "manifestSHA256": manifest_hash, "manifestSourcePath": str(manifest_path),
            "layoutManifestSHA256": layout["manifestSHA256"],
            "layoutManifestSourcePath": str(layout["manifestPath"]),
            "screenshotManifestSHA256": screenshot["manifestSHA256"],
            "screenshotManifestSourcePath": str(screenshot["manifestPath"]),
            "manifestTestIdentifier": layout["testIdentifier"],
            "manifestTestIdentifierURL": layout.get("testIdentifierURL"),
            "captureTestName": observed["testName"],
            "layoutManifestAttachment": layout["attachment"],
            "screenshotManifestAttachment": screenshot["attachment"]}


def output_stem(test, step):
    def slug(value):
        return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip(".-")[:90] or "capture"
    identity = sha256((test + "\0" + step).encode())[:16]
    return f"{slug(test)}--{slug(step)}--{identity}"


def plan_captures(run, result_path, result_raw, manifest_path, manifest_raw, root, include_steps,
                  extra_manifests=()):
    entries = []
    for source_root, source_manifest, source_raw in [(root, manifest_path, manifest_raw), *extra_manifests]:
        # Each export retains its own filename boundary; neither directory can
        # redirect an exported basename into the other directory.
        for entry in manifest_entries(decode_json(source_raw, source_manifest), source_root):
            entries.append({**entry, "manifestPath": source_manifest,
                            "manifestSHA256": sha256(source_raw)})
    pngs = []
    for entry in entries:
        name = entry["attachment"].get("suggestedHumanReadableName", "")
        match = PNG_NAME.fullmatch(name) if isinstance(name, str) else None
        if match:
            pngs.append({**entry, "step": match[1]})
    selected, excluded, seen = [], [], set()
    for entry in entries:
        path = entry["path"]
        if path.suffix.lower() == ".png":
            continue
        suggested = str(entry["attachment"].get("suggestedHumanReadableName", ""))
        # The separate keyboard-layout attachment is plain text, not layout JSON.
        layout_hint = suggested.lower().endswith(".json") and \
            re.search(r"-layout(?:\.json)?_\d+_", suggested) is not None
        raw = path.read_bytes()
        try:
            capture = decode_json(raw, path)
        except AuditError:
            if layout_hint:
                raise
            continue
        if not isinstance(capture, dict) or capture.get("schemaVersion") != 1 or \
                not isinstance(capture.get("step"), str) or not isinstance(capture.get("surface"), str):
            if layout_hint:
                raise AuditError("Named layout attachment has an invalid capture schema: " + str(path))
            continue
        step, surface = capture["step"], capture["surface"]
        if surface not in ("settings", "menu") or excluded_capture(step, entry) or \
                (include_steps and step not in include_steps):
            excluded.append({"testIdentifier": entry["testIdentifier"], "step": step,
                             "surface": surface, "sourcePath": str(path)})
            continue
        identity = (entry["testIdentifier"], step)
        if identity in seen:
            raise AuditError("Duplicate test/step would overwrite a capture: " + repr(identity))
        seen.add(identity)
        if not step.endswith("-screenshot") or not valid_frame(capture.get("windowFrame")) or \
                not isinstance(capture.get("elements"), list) or not capture["elements"]:
            raise AuditError("Empty or invalid layout capture: " + str(path))
        if any(not isinstance(item, dict) or not valid_frame(item.get("frame"))
               for item in capture["elements"]):
            raise AuditError("Invalid leaf geometry in layout capture: " + str(path))
        matches = [png for png in pngs if png["testIdentifier"] == entry["testIdentifier"] and
                   png["step"] == step and
                   all(png["attachment"].get(key) == entry["attachment"].get(key)
                       for key in ("deviceId", "configurationName")) and
                   png["attachment"].get("isAssociatedWithFailure") is not True]
        if len(matches) != 1:
            raise AuditError(f"Expected one PNG for exact test/step; found {len(matches)}: {identity}")
        png = {**matches[0], "raw": matches[0]["path"].read_bytes()}
        if not png["raw"].startswith(PNG_SIGNATURE):
            raise AuditError("Matched screenshot is not PNG: " + str(png["path"]))
        layout = {**entry, "raw": raw}
        provenance = provenance_for(capture, layout, png, run, result_path, sha256(result_raw),
                                    layout["manifestPath"], layout["manifestSHA256"])
        selected.append({"capture": capture, "layout": layout, "png": png,
                         "provenance": provenance, "stem": output_stem(*identity)})
    if not selected:
        raise AuditError("No eligible source-linked settings/menu captures were selected")
    missing = include_steps - {item["capture"]["step"] for item in selected}
    if missing:
        raise AuditError("Requested steps were not found: " + ", ".join(sorted(missing)))
    return selected, excluded


def write_new(path, data):
    with path.open("xb") as stream:
        stream.write(data)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()


def run_ocr(binary, screenshot, screenshot_hash, output):
    # The recognizer receives a private new destination, never an original capture.
    with tempfile.TemporaryDirectory(prefix="ocr-", dir=output.parent) as temp:
        raw_output = Path(temp) / "recognition.json"
        try:
            completed = subprocess.run([str(binary), str(screenshot), str(raw_output)],
                                       capture_output=True, text=True, timeout=120, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise AuditError("OCR execution failed: " + str(error)) from error
        if completed.returncode or not raw_output.is_file():
            raise AuditError(f"OCR failed ({completed.returncode}): {completed.stderr.strip()}")
        result = decode_json(raw_output.read_bytes(), raw_output)
        if not isinstance(result, dict):
            raise AuditError("OCR output must be a JSON object")
        result["screenshotSHA256"] = screenshot_hash
        result["absenceProvesClipping"] = False
        write_new(output, json_bytes(result))


def prepare(native_result, attachments, output, ocr=None, include_steps=(), layout_attachments=None):
    result_path = Path(native_result).resolve(strict=True)
    root = Path(attachments).resolve(strict=True)
    destination = Path(output).absolute()
    if not root.is_dir():
        raise AuditError("Attachments must be an exported attachment directory")
    if destination.is_symlink() or (destination.exists() and
                                  (not destination.is_dir() or any(destination.iterdir()))):
        raise AuditError("Output must be a new or empty regular directory")
    result_raw = result_path.read_bytes()
    run = decode_json(result_raw, result_path)
    if not isinstance(run, dict):
        raise AuditError("Native result must be a JSON object")
    manifest_path = attachment_path(root, "manifest.json")
    manifest_raw = manifest_path.read_bytes()
    extra_manifests = []
    manifest_sources = [{"role": "attachments", "path": str(manifest_path), "sha256": sha256(manifest_raw)}]
    if layout_attachments is not None:
        layout_root = Path(layout_attachments).resolve(strict=True)
        if not layout_root.is_dir() or layout_root == root:
            raise AuditError("Layout attachments must be a distinct exported attachment directory")
        layout_manifest_path = attachment_path(layout_root, "manifest.json")
        layout_manifest_raw = layout_manifest_path.read_bytes()
        extra_manifests.append((layout_root, layout_manifest_path, layout_manifest_raw))
        manifest_sources.append({"role": "layoutAttachments", "path": str(layout_manifest_path),
                                 "sha256": sha256(layout_manifest_raw)})
    selected, excluded = plan_captures(run, result_path, result_raw, manifest_path, manifest_raw,
                                       root, set(include_steps), extra_manifests)
    ocr_binary = Path(ocr).resolve(strict=True) if ocr else None
    if ocr_binary and (not ocr_binary.is_file() or not os.access(ocr_binary, os.X_OK)):
        raise AuditError("OCR must name an existing executable binary")
    destination.mkdir(parents=True, exist_ok=True)
    write_new(destination / "native-result.json", result_raw)
    write_new(destination / "attachment-manifest.json", manifest_raw)
    if extra_manifests:
        write_new(destination / "layout-attachment-manifest.json", extra_manifests[0][2])
    captures = []
    for item in selected:
        stem, capture = item["stem"], item["capture"]
        png_path = destination / (stem + ".png")
        layout_path = destination / (stem + ".layout.json")
        write_new(png_path, item["png"]["raw"])
        capture = {**capture, "provenance": item["provenance"], "screenshotPath": str(png_path)}
        write_new(layout_path, json_bytes(capture))
        ocr_path = destination / (stem + ".ocr.json") if ocr_binary else None
        if ocr_path:
            run_ocr(ocr_binary, png_path, item["provenance"]["screenshotSHA256"], ocr_path)
        captures.append({"testIdentifier": item["layout"]["testIdentifier"], "step": capture["step"],
                         "surface": capture["surface"], "layout": str(layout_path),
                         "screenshot": str(png_path), "ocr": str(ocr_path) if ocr_path else None,
                         "provenance": item["provenance"]})
    summary = {"schemaVersion": 1, "status": "prepared", "nativeResultStatus": run.get("status", "unknown"),
               "preparedAt": datetime.now(timezone.utc).isoformat(), "nativeResultPath": str(result_path),
               "nativeResultSHA256": sha256(result_raw), "manifestPath": str(manifest_path),
               "manifestSHA256": sha256(manifest_raw), "output": str(destination),
               "manifests": manifest_sources,
               "requestedSteps": sorted(set(include_steps)), "selected": captures, "excluded": excluded,
               "coverage": {"captureCount": len(captures),
                            "surfaces": sorted({item["surface"] for item in captures}),
                            "tests": sorted({item["testIdentifier"] for item in captures}),
                            "steps": sorted({item["step"] for item in captures}),
                            "ocrCount": sum(item["ocr"] is not None for item in captures)},
               "notInferred": ["testPass", "textChecks", "visualConfirmedClipping", "visualApproval"]}
    write_new(destination / "summary.json", json_bytes(summary))
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-result", required=True, type=Path)
    parser.add_argument("--attachments", required=True, type=Path)
    parser.add_argument("--layout-attachments", type=Path,
                        help="Optional separate JSON attachment export; PNG export stays in --attachments")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ocr", type=Path, help="Existing compiled recognize-ui-text binary")
    parser.add_argument("--include-step", action="append", default=[])
    args = parser.parse_args(argv)
    try:
        summary = prepare(args.native_result, args.attachments, args.output, args.ocr, args.include_step,
                          layout_attachments=args.layout_attachments)
    except (AuditError, OSError, ValueError) as error:
        print("Design audit preparation failed: " + str(error), file=sys.stderr)
        return 1
    print(f"Prepared {summary['coverage']['captureCount']} captures: {args.output / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
