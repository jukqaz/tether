#!/usr/bin/env python3
"""XCUITest the actual SwiftUI scenes in an isolated copy of a built Tether.app.

No production app/helper, power setting, security permission or system UI is changed.
An unavailable AX element fails its test. Only a successful xcresult counts as passed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID_PREFIX = "io.github.jukqaz.tether.ui-tests"
HOST_ID = "A00000000000000000000001"
TEST_ID = "A00000000000000000000002"


class Blocked(RuntimeError):
    pass


def command(args, timeout=30):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout, check=False)
    if result.returncode:
        raise Blocked(f"{' '.join(args)} failed ({result.returncode}): {result.stdout.strip()}")
    return result.stdout.strip()


def fresh_fixture_bundle_id():
    # LaunchServices remembers previously tested app paths. Reusing an identifier
    # can launch an older product even when the generated test target is current.
    return BUNDLE_ID_PREFIX + "." + uuid.uuid4().hex


def require_fixture_bundle_id(bundle_id):
    if not isinstance(bundle_id, str) or not re.fullmatch(
            re.escape(BUNDLE_ID_PREFIX) + r"\.[0-9a-f]{32}", bundle_id):
        raise Blocked("The native UI fixture must use its unique private run identifier")
    return bundle_id


def prepare_app(source, project, bundle_id):
    require_fixture_bundle_id(bundle_id)
    contents = source / "Contents"
    metadata = plistlib.loads((contents / "Info.plist").read_bytes())
    executable = metadata.get("CFBundleExecutable")
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise Blocked("The source app has no valid CFBundleExecutable")
    binary = contents / "MacOS" / executable
    binary_data = binary.read_bytes()
    if not all(marker in binary_data for marker in [b"TetherUIAutomationFixture", b"TETHER_UI_TESTING"]):
        raise Blocked("The built executable lacks the guarded native UI fixture; rebuild the current source first")
    fixture = project / "Fixture" / "TetherUIFixture.app"
    fixture.parent.mkdir(parents=True)
    command(["/usr/bin/ditto", str(source), str(fixture)], timeout=120)
    metadata.update(CFBundleIdentifier=bundle_id, CFBundleName="Tether UI Fixture",
                    CFBundleDisplayName="Tether UI Fixture", LSUIElement=False,
                    TetherUIAutomationFixture=True)
    # An isolated launch never registers the production deep link or an updater feed.
    metadata.pop("CFBundleURLTypes", None)
    metadata.pop("SUFeedURL", None)
    metadata["SUEnableAutomaticChecks"] = False
    (fixture / "Contents" / "Info.plist").write_bytes(plistlib.dumps(metadata))
    return executable, metadata, hashlib.sha256(binary_data).hexdigest()


def quoted(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def write_project(project, executable, metadata):
    bundle_id = require_fixture_bundle_id(metadata.get("CFBundleIdentifier"))
    tests = ROOT / "Tests" / "NativeUITests" / "TetherNativeUITests.swift"
    source = tests.read_text()
    # Change only the generated copy; the checked-in tests remain a stable input.
    # Missing/duplicated placeholders are setup failures rather than silently
    # testing an app selected from stale LaunchServices registration.
    id_literal = quoted(BUNDLE_ID_PREFIX)
    path_literal = quoted("__TETHER_UI_EXPECTED_EXECUTABLE_PATH__")
    if source.count(id_literal) != 1 or source.count(path_literal) != 1:
        raise Blocked("Native UI tests must contain one bundle identifier and one executable-path placeholder")
    expected_executable = (project.parent / "DerivedData" / "Build" / "Products" / "Debug"
                           / "TetherUIFixture.app" / "Contents" / "MacOS" / executable)
    source = source.replace(id_literal, quoted(bundle_id)).replace(path_literal, quoted(expected_executable))
    (project / "Sources").mkdir()
    (project / "Sources" / "main.c").write_text("int main(void) { return 70; }\n")
    (project / "Sources" / tests.name).write_text(source)
    xcodeproject = project / "TetherNativeUI.xcodeproj"
    xcodeproject.mkdir()
    # Xcode owns the product and its final ad hoc signature. The final build phase
    # replaces the placeholder with the already compiled app, including frameworks.
    script = 'set -eu\n/usr/bin/ditto "$PROJECT_DIR/Fixture/TetherUIFixture.app" "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"\n'
    project_settings = 'SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 26.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_HARDENED_RUNTIME = NO; ENABLE_USER_SCRIPT_SANDBOXING = NO;'
    host_settings = f'PRODUCT_NAME = TetherUIFixture; PRODUCT_BUNDLE_IDENTIFIER = {quoted(bundle_id)}; EXECUTABLE_NAME = {quoted(executable)}; INFOPLIST_FILE = Fixture/TetherUIFixture.app/Contents/Info.plist; GENERATE_INFOPLIST_FILE = NO;'
    test_settings = f'PRODUCT_NAME = TetherNativeUITests; PRODUCT_BUNDLE_IDENTIFIER = {quoted(bundle_id + ".runner-tests")}; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = TetherUIFixture; SWIFT_EMIT_LOC_STRINGS = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks";'
    objects = {
        "A00000000000000000000003": 'isa = PBXProject; attributes = { LastUpgradeCheck = 2600; TargetAttributes = { ' + TEST_ID + ' = { TestTargetID = ' + HOST_ID + '; }; }; }; buildConfigurationList = A00000000000000000000004; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, ko, Base); mainGroup = A00000000000000000000005; productRefGroup = A00000000000000000000006; projectDirPath = ""; projectRoot = ""; targets = (' + HOST_ID + ', ' + TEST_ID + ');',
        HOST_ID: 'isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000007; buildPhases = (A00000000000000000000008, A00000000000000000000009); buildRules = (); dependencies = (); name = TetherUIFixture; productName = TetherUIFixture; productReference = A0000000000000000000000A; productType = "com.apple.product-type.application";',
        TEST_ID: 'isa = PBXNativeTarget; buildConfigurationList = A0000000000000000000000B; buildPhases = (A0000000000000000000000C); buildRules = (); dependencies = (A0000000000000000000000D); name = TetherNativeUITests; productName = TetherNativeUITests; productReference = A0000000000000000000000E; productType = "com.apple.product-type.bundle.ui-testing";',
        "A00000000000000000000005": 'isa = PBXGroup; children = (A0000000000000000000000F, A00000000000000000000010, A00000000000000000000006); sourceTree = "<group>";',
        "A00000000000000000000006": 'isa = PBXGroup; children = (A0000000000000000000000A, A0000000000000000000000E); name = Products; sourceTree = "<group>";',
        "A0000000000000000000000F": 'isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = Sources/main.c; sourceTree = "<group>";',
        "A00000000000000000000010": 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sources/TetherNativeUITests.swift; sourceTree = "<group>";',
        "A0000000000000000000000A": 'isa = PBXFileReference; explicitFileType = wrapper.application; path = TetherUIFixture.app; sourceTree = BUILT_PRODUCTS_DIR;',
        "A0000000000000000000000E": 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = TetherNativeUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;',
        "A00000000000000000000011": 'isa = PBXBuildFile; fileRef = A0000000000000000000000F;',
        "A00000000000000000000012": 'isa = PBXBuildFile; fileRef = A00000000000000000000010;',
        "A00000000000000000000008": 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000011); runOnlyForDeploymentPostprocessing = 0;',
        "A00000000000000000000009": 'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); name = "Copy guarded fixture app"; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = ' + quoted(script) + ';',
        "A0000000000000000000000C": 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000012); runOnlyForDeploymentPostprocessing = 0;',
        "A0000000000000000000000D": 'isa = PBXTargetDependency; target = ' + HOST_ID + '; targetProxy = A00000000000000000000013;',
        "A00000000000000000000013": 'isa = PBXContainerItemProxy; containerPortal = A00000000000000000000003; proxyType = 1; remoteGlobalIDString = ' + HOST_ID + '; remoteInfo = TetherUIFixture;',
    }
    for list_id, config_id, settings in [("04", "14", project_settings), ("07", "15", host_settings), ("0B", "16", test_settings)]:
        objects["A000000000000000000000" + list_id] = 'isa = XCConfigurationList; buildConfigurations = (A000000000000000000000' + config_id + '); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;'
        objects["A000000000000000000000" + config_id] = 'isa = XCBuildConfiguration; buildSettings = {' + settings + '}; name = Debug;'
    body = "\n".join(f"{identifier} = {{ {value} }};" for identifier, value in objects.items())
    (xcodeproject / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + body + '\n}; rootObject = A00000000000000000000003; }\n')

    scheme = ET.Element("Scheme", LastUpgradeVersion="2600", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="NO", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    def reference(parent, identifier, name, product):
        ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=identifier,
                      BuildableName=product, BlueprintName=name, ReferencedContainer="container:TetherNativeUI.xcodeproj")
    for identifier, name, product in [(HOST_ID, "TetherUIFixture", "TetherUIFixture.app"), (TEST_ID, "TetherNativeUITests", "TetherNativeUITests.xctest")]:
        entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="NO",
                              buildForProfiling="NO", buildForArchiving="NO", buildForAnalyzing="NO")
        reference(entry, identifier, name, product)
    action = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="NO")
    testable = ET.SubElement(ET.SubElement(action, "Testables"), "TestableReference", skipped="NO", parallelizable="NO")
    reference(testable, TEST_ID, "TetherNativeUITests", "TetherNativeUITests.xctest")
    schemes = xcodeproject / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(schemes / "TetherNativeUI.xcscheme", encoding="UTF-8", xml_declaration=True)
    return xcodeproject


def execute(args, logfile, timeout):
    with logfile.open("w") as log:
        child = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return child.wait(timeout=timeout), False
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            return child.returncode, True


def runtime_warning_evidence(summary, log):
    summary = summary or {}
    warnings = summary.get("runtimeWarnings") or []
    # Current xcresult summaries provide the full warning array. Accept the count
    # field too, so a count-only report can never silently become a passing run.
    count = max(summary.get("runtimeWarningCount") or 0, len(warnings))
    log_evidence = [line for line in log.splitlines()
                    if "publishing changes from within view updates" in line.lower()]
    return {"runtimeWarningCount": count, "runtimeWarnings": warnings,
            "runtimeWarningLogCount": len(log_evidence), "runtimeWarningLogEvidence": log_evidence}


def classify(returncode, summary, log, timed_out):
    if timed_out:
        return "blocked", "xcodebuild exceeded the time limit or was interrupted; no passing result is inferred"
    setup_evidence = [log] + [item.get("failureText", "")
                              for item in ((summary or {}).get("testFailures") or [])]
    if any("failed to initialize for ui testing" in evidence.lower()
           and "timed out while enabling automation mode" in evidence.lower()
           for evidence in setup_evidence):
        return "blocked", "UI test runner initialization timed out while enabling automation mode; see xcodebuild.log and xcresult"
    blocked_signatures = ["not authorized for accessibility", "accessibility permission", "not permitted to control",
                          "enable ui automation", "failed to authorize rights",
                          "screen is locked", "no user is logged in", "system authentication is running"]
    for signature in blocked_signatures:
        if signature in log.lower():
            return "blocked", f"UI automation unavailable: {signature}; see xcodebuild.log and xcresult"
    warnings = runtime_warning_evidence(summary, log)
    if warnings["runtimeWarningCount"] or warnings["runtimeWarningLogCount"]:
        return "failed", ("Native UI runtime warnings invalidate the run: "
                          f"xcresult={warnings['runtimeWarningCount']}, "
                          f"Publishing changes log lines={warnings['runtimeWarningLogCount']}; "
                          "see runtimeWarnings, runtimeWarningLogEvidence and xcodebuild.log")
    capture_failure = "Failed to get screenshot: Failed to create screenshot. Image creation failed."
    capture_messages = {capture_failure, capture_failure + " Disable automatic screenshots in your test plan's configuration and avoid taking manual screenshots."}
    failures = [str(item.get("failureText") or "").strip()
                for item in ((summary or {}).get("testFailures") or [])]
    # Require a complete, homogeneous failed report. Screenshot errors cannot
    # conceal an assertion, crash, runtime warning, or an unreported log error.
    log_errors = re.findall(r"^.*\berror:\s+(?:-\[[^\]\n]+\]\s*:\s*)?(.*?)\s*$", log, re.MULTILINE)
    runtime_defects = ["fatal error:", "assertion failure", "exc_bad_access", "exc_bad_instruction",
                       "signal sigabrt", "application crashed", "app crashed", "main thread checker",
                       "runtime warning", "swift runtime failure"]
    if (returncode != 0 and summary and summary.get("result") == "Failed"
            and summary.get("totalTestCount", 0) > 0
            and summary.get("failedTests") == summary.get("totalTestCount") == len(failures)
            and summary.get("passedTests") == summary.get("skippedTests") == summary.get("expectedFailures") == 0
            and all(message in capture_messages for message in failures)
            and all(message in capture_messages for message in log_errors)
            and not any(signature in log.lower() for signature in runtime_defects)):
        return "blocked", "All native UI tests stopped because screenshot image creation was unavailable; raw failures remain recorded and UI behavior is not verified"
    if (returncode == 0 and summary and summary.get("result") == "Passed"
            and summary.get("totalTestCount", 0) > 0 and summary.get("failedTests") == 0
            and summary.get("skippedTests") == 0 and summary.get("expectedFailures") == 0
            and summary.get("passedTests") == summary.get("totalTestCount")):
        return "passed", "xcodebuild and the actual xcresult confirm all native UI tests passed"
    return "failed", "Native UI verification did not pass; see xcodebuild.log and xcresult summary"


def test_execution_started(summary, log=""):
    # A missing/incomplete xcresult can still have direct XCTest method-start
    # evidence. A suite start or runner initialization message is insufficient.
    if re.search(r"^Test Case '-\[[\w.]+ test\w+\]' started\.$", log, re.MULTILINE):
        return True
    if not summary:
        return None
    failures = summary.get("testFailures") or []
    # xcresult can count a runner initialization error as one failed test,
    # although none of the requested UI test methods executed.
    only_runner_failure = (failures and summary.get("failedTests") == summary.get("totalTestCount")
        and all("test runner failed to initialize for ui testing" in item.get("failureText", "").lower()
                for item in failures))
    if only_runner_failure:
        return False
    return bool(summary.get("totalTestCount", 0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build" / "Tether.app")
    parser.add_argument("--output", type=Path, default=ROOT / "build" / "native-ui" / (datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]))
    parser.add_argument("--prepare-only", action="store_true", help="Generate the isolated project without launching UI or claiming test success")
    parser.add_argument("--only-testing", action="append", default=[], help="Optional xcodebuild test identifier; may be repeated")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be an empty/new directory; existing test evidence is never overwritten")
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    output.mkdir(parents=True, exist_ok=True)
    bundle_id = fresh_fixture_bundle_id()
    result = {"status": "blocked", "source_app": str(args.app.expanduser().resolve()), "output": str(output),
              "fixture_bundle_id": bundle_id, "xcodebuild_started": False, "test_execution_started": False, "physical_power_tested": False,
              "production_app_tested": False, "started_at": datetime.now(timezone.utc).isoformat(),
              "sourceExecutableSHA256": None, "nativeUITestSourceSHA256": None, "fixtureExecutableSHA256": None}
    started = time.monotonic()
    exitcode = 2
    try:
        if sys.platform != "darwin":
            raise Blocked("Native macOS UI tests require macOS and full Xcode")
        result["xcode"] = command(["xcodebuild", "-version"])
        result["macos"] = platform.mac_ver()[0]
        project = output / "Project"
        project.mkdir()
        executable, metadata, source_hash = prepare_app(Path(result["source_app"]), project, bundle_id)
        result["sourceExecutableSHA256"] = source_hash
        result["source_version"] = metadata.get("CFBundleShortVersionString")
        result["source_build"] = metadata.get("CFBundleVersion")
        xcodeproject = write_project(project, executable, metadata)
        result["nativeUITestOriginalSourceSHA256"] = hashlib.sha256(
            (ROOT / "Tests" / "NativeUITests" / "TetherNativeUITests.swift").read_bytes()).hexdigest()
        generated_tests = project / "Sources" / "TetherNativeUITests.swift"
        result["nativeUITestSourceSHA256"] = hashlib.sha256(generated_tests.read_bytes()).hexdigest()
        if args.prepare_only:
            result.update(status="prepared", reason="Isolated Xcode project generated; native UI tests were not run")
            exitcode = 0
        else:
            bundle = output / "NativeUI.xcresult"
            invocation = ["xcodebuild", "test", "-project", str(xcodeproject), "-scheme", "TetherNativeUI",
                          "-destination", f"platform=macOS,arch={platform.machine()}", "-derivedDataPath", str(output / "DerivedData"),
                          "-resultBundlePath", str(bundle), "-parallel-testing-enabled", "NO", "-enableCodeCoverage", "NO"]
            invocation.extend("-only-testing:" + identifier for identifier in args.only_testing)
            result["command"] = invocation
            result["xcodebuild_started"] = True
            print("Running isolated native UI tests; evidence: " + str(output), flush=True)
            returncode, timed_out = execute(invocation, output / "xcodebuild.log", args.timeout)
            result.update(xcodebuild_returncode=returncode, timed_out=timed_out, xcresult=str(bundle))
            # Read Xcode's final product after its copy/signing/test actions, not the
            # unsigned staging copy. A missing build product remains unknown.
            fixture_executable = output / "DerivedData" / "Build" / "Products" / "Debug" / "TetherUIFixture.app" / "Contents" / "MacOS" / executable
            if fixture_executable.is_file():
                result["fixtureExecutableSHA256"] = hashlib.sha256(fixture_executable.read_bytes()).hexdigest()
                result["fixtureExecutablePath"] = str(fixture_executable)
            summary = None
            if bundle.exists():
                try:
                    summary = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"]))
                    (output / "xcresult-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
                except (Blocked, ValueError, subprocess.TimeoutExpired) as error:
                    result["xcresult_summary_error"] = str(error)
            log = (output / "xcodebuild.log").read_text(errors="replace")
            result.update(runtime_warning_evidence(summary, log))
            result["status"], result["reason"] = classify(returncode, summary, log, timed_out)
            result["test_execution_started"] = test_execution_started(summary, log)
            if summary:
                result["counts"] = {key: summary.get(key) for key in ["totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"]}
                result["test_failures"] = summary.get("testFailures", [])
            exitcode = 0 if result["status"] == "passed" else (2 if result["status"] == "blocked" else 1)
    except (Blocked, OSError, ValueError, subprocess.TimeoutExpired) as error:
        result.update(status="blocked", reason=str(error))
    finally:
        result.update(finished_at=datetime.now(timezone.utc).isoformat(), elapsed_seconds=round(time.monotonic() - started, 2))
        (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return exitcode


if __name__ == "__main__":
    sys.exit(main())
