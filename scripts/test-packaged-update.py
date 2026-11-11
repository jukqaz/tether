#!/usr/bin/env python3
"""Exercise Sparkle with real package payloads under disposable identities/signing.

The source ZIPs are read only. Both extracted root bundles receive a unique
CFBundleIdentifier, SUDefaultsDomain and disposable public key before Sparkle
runs. Their executables are never launched. This is a packaged-payload fixture,
not an update of the original production bundle identity or signing chain.

SPARKLE_TEST_CLI and SPARKLE_TOOLS_DIR identify the official Sparkle 2.10 tools.
The production signing key is not used. A short CryptoKit invocation generates
the disposable key, matching test-sparkle-update.py without a package build.
"""

import argparse
import base64
import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile


PRODUCTION_ID = "io.github.jukqaz.tether"
TEST_PREFIX = PRODUCTION_ID + ".update-test."
SECURITY_KEYS = {
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
    "SUSignedFeedFailureExpirationInterval": 0,
}
SIGNATURE_FILES = {"Contents/Info.plist", "Contents/_CodeSignature/CodeResources"}
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def write_output(path, text):
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(text)


def command(*arguments, timeout=60, environment=None):
    result = subprocess.run(
        [str(value) for value in arguments], capture_output=True, text=True,
        timeout=timeout, env=environment,
    )
    require(result.returncode == 0, f"{Path(str(arguments[0])).name} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def checked_test_id(identifier):
    require(identifier.startswith(TEST_PREFIX), "Refuse a non-test bundle identity")
    value = identifier[len(TEST_PREFIX):]
    for suffix in (".runner", ".sentinel"):
        value = value.removesuffix(suffix)
    uuid.UUID(value)
    require(identifier != PRODUCTION_ID, "Production identity is forbidden")


def validate_archive(path):
    require(path.is_file() and not path.is_symlink(), "Source ZIP must be a regular file")
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            require(not name.is_absolute() and ".." not in name.parts, "Unsafe archive member")
            require(name.parts and name.parts[0] in ("Tether.app", "__MACOSX"), "Unexpected archive root")
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = PurePosixPath(archive.read(entry).decode("utf-8"))
                require(not target.is_absolute(), "Absolute archive symlink")
                depth = len(name.parent.parts)
                for part in target.parts:
                    depth += -1 if part == ".." else 0 if part == "." else 1
                    require(depth >= 1, "Archive symlink escapes its root")


def extract_archive(archive, destination):
    validate_archive(archive)
    destination.mkdir()
    command("/usr/bin/ditto", "-x", "-k", archive, destination)
    app = destination / "Tether.app"
    require(app.is_dir() and not app.is_symlink(), "Missing extracted Tether.app")
    for item in app.rglob("*"):
        if item.is_symlink():
            require(item.resolve().is_relative_to(app.resolve()), "Extracted symlink escapes app")
    return app


def bundle_info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def write_info(app, info):
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))


def tree_manifest(app):
    result = {}
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            result[relative] = {"symlink": os.readlink(path)}
        elif path.is_file():
            result[relative] = {"sha256": digest(path), "mode": stat.S_IMODE(path.stat().st_mode)}
    return result


def unsigned_executable_hash(executable, destination):
    shutil.copy2(executable, destination)
    command("/usr/bin/codesign", "--remove-signature", destination)
    return digest(destination)


def prepare_fixture(app, identifier, public_key, feed_url, canonical_dir):
    checked_test_id(identifier)
    before = tree_manifest(app)
    info = bundle_info(app)
    require(info.get("CFBundleIdentifier") == PRODUCTION_ID, "Unexpected source bundle identity")
    for key, expected in SECURITY_KEYS.items():
        require(info.get(key) == expected, f"Source security setting differs: {key}")
    executable_name = info["CFBundleExecutable"]
    require(Path(executable_name).name == executable_name, "Unexpected executable path")
    executable = app / "Contents/MacOS" / executable_name
    canonical_dir.mkdir()
    original_unsigned = unsigned_executable_hash(executable, canonical_dir / "source")
    info.update({
        "CFBundleIdentifier": identifier,
        "SUDefaultsDomain": identifier,
        "SUPublicEDKey": public_key,
        "SUFeedURL": feed_url,
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    })
    # Sparkle registers the replaced bundle with LaunchServices. Fixture root
    # metadata must not register production URL schemes or helper declarations.
    for key in ("CFBundleURLTypes", "SMPrivilegedExecutables", "SMAuthorizedClients"):
        info.pop(key, None)
    write_info(app, info)
    # Keep all nested helper/framework signatures and payload bytes intact.
    command("/usr/bin/codesign", "--force", "--sign", "-", app)
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    fixture_unsigned = unsigned_executable_hash(executable, canonical_dir / "fixture")
    require(original_unsigned == fixture_unsigned, "GUI executable payload changed beyond its embedded signature")
    after = tree_manifest(app)
    changed = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
    permitted = SIGNATURE_FILES | {"Contents/MacOS/" + executable_name}
    require(set(changed) <= permitted, f"Unexpected payload changes: {changed}")
    require(bundle_info(app)["CFBundleIdentifier"] == identifier, "Fixture lost its unique identity")
    require(bundle_info(app)["SUDefaultsDomain"] == identifier, "Fixture lost its private preferences domain")
    return {
        "changedFiles": changed,
        "unsignedExecutableSHA256": original_unsigned,
        "unmodifiedPayloadFiles": len(before) - len(changed),
        "fixtureManifest": after,
    }


def create_utility_app(path, identifier, executable):
    checked_test_id(identifier)
    binary = path / "Contents/MacOS" / executable.name
    binary.parent.mkdir(parents=True)
    # System utilities can carry restricted file flags. Only the disposable
    # runner bytes and executable permission are needed here.
    shutil.copyfile(executable, binary)
    binary.chmod(0o755)
    write_info(path, {
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable.name,
        "CFBundleName": "Tether packaged update fixture",
        "CFBundlePackageType": "APPL",
        "SUDefaultsDomain": identifier,
    })
    command("/usr/bin/codesign", "--force", "--sign", "-", path)
    return binary


def make_disposable_key(folder):
    source = """import Foundation
import CryptoKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
guard FileManager.default.createFile(atPath: folder.appendingPathComponent("fixture.key").path,
    contents: key.rawRepresentation.base64EncodedData(), attributes: [.posixPermissions: 0o600]) else { exit(1) }
try key.publicKey.rawRepresentation.base64EncodedData().write(to: folder.appendingPathComponent("fixture.pub"))
"""
    command("/usr/bin/swift", "-e", source, folder)
    public = (folder / "fixture.pub").read_text().strip()
    require(len(base64.b64decode(public, validate=True)) == 32, "Unexpected fixture public key")
    return folder / "fixture.key", public


def owned_processes(folder, identifier):
    checked_test_id(identifier)
    output = command("/bin/ps", "-axww", "-o", "pid=,uid=,command=")
    found = []
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid, uid, arguments = fields
        if int(uid) == os.getuid() and int(pid) != os.getpid():
            if str(folder) in arguments or identifier in arguments:
                found.append(int(pid))
    return found


def cleanup_processes(folder, identifier):
    for attempt in range(50):
        processes = owned_processes(folder, identifier)
        if not processes:
            return
        for pid in processes:
            try:
                os.kill(pid, signal.SIGTERM if attempt < 25 else signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(0.1)
    require(not owned_processes(folder, identifier), "Fixture updater processes did not stop")


def cleanup_domains(*domains):
    for domain in domains:
        checked_test_id(domain)
        subprocess.run(["/usr/bin/defaults", "delete", domain], capture_output=True, text=True)
        library = Path.home() / "Library"
        (library / "Preferences" / (domain + ".plist")).unlink(missing_ok=True)
        cache = library / "Caches" / domain
        if cache.is_symlink():
            cache.unlink()
        elif cache.exists():
            shutil.rmtree(cache)


def make_server(paths, requests):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *arguments):
            pass

        def do_GET(self):
            self.serve_file(True)

        def do_HEAD(self):
            self.serve_file(False)

        def serve_file(self, send_body):
            path = paths.get(self.path)
            if self.client_address[0] != "127.0.0.1" or path is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(path.stat().st_size))
            self.send_header("Content-Type", "application/xml" if path.suffix == ".xml" else "application/zip")
            self.end_headers()
            sent = 0
            if send_body:
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(256 * 1024), b""):
                        self.wfile.write(block)
                        sent += len(block)
            requests.append({"method": self.command, "path": self.path, "bytes": sent})

    return http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)


def run_test(args):
    require(os.getuid() != 0, "Run this fixture as an ordinary user")
    cli = args.cli.resolve()
    sign_update = args.tools.resolve() / "bin/sign_update"
    require(cli.is_file() and os.access(cli, os.X_OK), "Missing official sparkle-cli")
    require(sign_update.is_file() and os.access(sign_update, os.X_OK), "Missing Sparkle sign_update")
    previous_zip, candidate_zip = args.previous.resolve(), args.candidate.resolve()
    source_hashes = {"previous": digest(previous_zip), "candidate": digest(candidate_zip)}
    output = args.output.resolve()
    require(not output.is_relative_to(Path.home() / "Library"), "Report directory must be outside Library")
    require(not output.is_relative_to(Path("/Applications")), "Report directory must be outside Applications")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {
        "passed": False,
        "scope": "real package payload with isolated identity and disposable signing",
        "sourceArchives": source_hashes,
    }
    requests = []

    with tempfile.TemporaryDirectory(prefix="tether-packaged-update-", dir="/tmp") as temporary:
        folder = Path(temporary).resolve()
        identifier = TEST_PREFIX + str(uuid.uuid4())
        domains = [identifier, identifier + ".runner", identifier + ".sentinel"]
        for value in domains:
            checked_test_id(value)
        server = None
        server_thread = None
        process = None
        try:
            previous = extract_archive(previous_zip, folder / "installed")
            candidate = extract_archive(candidate_zip, folder / "candidate")
            previous_info, candidate_info = bundle_info(previous), bundle_info(candidate)
            require(previous_info["CFBundleVersion"] == str(args.previous_build), "Unexpected previous build")
            require(candidate_info["CFBundleVersion"] == str(args.candidate_build), "Unexpected candidate build")
            require(args.candidate_build > args.previous_build, "Candidate build must increase")
            require(candidate_info.get("TetherReleaseChannel") == "stable", "Candidate must use the stable channel")
            require(previous_info.get("SUPublicEDKey") == candidate_info.get("SUPublicEDKey"), "Original package public keys differ")
            require(isinstance(previous_info.get("SUPublicEDKey"), str)
                    and len(base64.b64decode(previous_info["SUPublicEDKey"], validate=True)) == 32,
                    "Original packages must contain a valid public key")
            report["originalIdentity"] = {
                "bundleID": PRODUCTION_ID,
                "previousBuild": previous_info["CFBundleVersion"],
                "candidateBuild": candidate_info["CFBundleVersion"],
                "candidateVersion": candidate_info["CFBundleShortVersionString"],
                "candidateChannel": candidate_info["TetherReleaseChannel"],
            }
            key, public = make_disposable_key(folder)
            feed = folder / "appcast.xml"
            archive = folder / "Tether-payload-fixture.zip"
            server = make_server({"/appcast.xml": feed, "/Tether-payload-fixture.zip": archive}, requests)
            origin = f"http://127.0.0.1:{server.server_port}"
            report["previousFixture"] = prepare_fixture(previous, identifier, public, origin + "/appcast.xml", folder / "old-canonical")
            report["candidateFixture"] = prepare_fixture(candidate, identifier, public, origin + "/appcast.xml", folder / "new-canonical")
            require(bundle_info(previous)["CFBundleIdentifier"] == bundle_info(candidate)["CFBundleIdentifier"] == identifier,
                    "Both Sparkle host identities must be isolated before updater startup")
            runner = create_utility_app(folder / "runner.app", domains[1], cli)
            sentinel = folder / "sentinel.app"
            create_utility_app(sentinel, domains[2], Path("/usr/bin/true"))
            command("/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", candidate, archive)
            signature = command(sign_update, "--ed-key-file", key, "-p", archive).strip()
            require(len(base64.b64decode(signature, validate=True)) == 64, "Unexpected fixture signature")
            version = candidate_info["CFBundleShortVersionString"]
            # Source metadata is constrained by the release process; XML escaping
            # still keeps the local feed valid if the display version changes.
            from xml.sax.saxutils import escape
            feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="{SPARKLE_NAMESPACE}" version="2.0"><channel><title>Tether payload fixture</title>
<item><title>{escape(version)}</title><sparkle:version>{args.candidate_build}</sparkle:version>
<sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>{escape(candidate_info['LSMinimumSystemVersion'])}</sparkle:minimumSystemVersion>
<enclosure url="{origin}/Tether-payload-fixture.zip" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item></channel></rss>''')
            command(sign_update, "--ed-key-file", key, feed)
            command(sign_update, "--ed-key-file", key, "--verify", feed)
            fixture_archive_hash = digest(archive)
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()
            environment = dict(os.environ)
            environment.pop("TETHER_SIGNING_KEY_FILE", None)
            environment.pop("PRIVATE_KEY", None)
            started = datetime.datetime.now(datetime.timezone.utc).isoformat()
            process = subprocess.Popen([
                str(runner), str(previous), "--application", str(sentinel),
                "--feed-url", origin + "/appcast.xml", "--check-immediately",
                "--user-agent-name", "TetherPackagedPayloadFixture", "--verbose",
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True, env=environment)
            stdout, stderr = process.communicate(timeout=args.timeout)
            write_output(output / "sparkle.log", stdout + stderr)
            require(process.returncode == 0, f"Sparkle payload update failed ({process.returncode}); see sparkle.log")
            require(bundle_info(previous)["CFBundleVersion"] == str(args.candidate_build), "Sparkle did not replace the old bundle")
            require(bundle_info(previous)["CFBundleIdentifier"] == identifier, "Replacement lost isolated identity")
            command("/usr/bin/codesign", "--verify", "--deep", "--strict", previous)
            require(tree_manifest(previous) == report["candidateFixture"]["fixtureManifest"], "Installed fixture differs from prepared candidate fixture")
            require(digest(archive) == fixture_archive_hash, "Served fixture ZIP changed")
            require(any(row["method"] == "GET" and row["path"] == "/appcast.xml" for row in requests), "No local appcast request observed")
            require(any(row["method"] == "GET" and row["path"] == "/Tether-payload-fixture.zip" and row["bytes"] == archive.stat().st_size for row in requests), "Complete local update download was not observed")
            require(source_hashes == {"previous": digest(previous_zip), "candidate": digest(candidate_zip)}, "Original source ZIP changed")
            report.update({"passed": True, "startedAt": started, "finishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                           "updaterExitCode": process.returncode, "fixtureBundleID": identifier,
                           "fixtureArchiveSHA256": fixture_archive_hash, "httpRequests": requests})
        except Exception as error:
            report["error"] = str(error)
            raise
        finally:
            cleanup_errors = []
            try:
                if process is not None and process.poll() is None:
                    try:
                        process.terminate()
                    finally:
                        try:
                            stdout, stderr = process.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            try:
                                process.kill()
                            finally:
                                stdout, stderr = process.communicate(timeout=5)
                    write_output(output / "sparkle.log", stdout + stderr)
            except Exception as error:
                cleanup_errors.append(f"CLI termination/log: {error}")
            try:
                if server is not None:
                    try:
                        if server_thread is not None and server_thread.is_alive():
                            server.shutdown()
                    finally:
                        server.server_close()
            except Exception as error:
                cleanup_errors.append(f"HTTP server: {error}")
            try:
                if server_thread is not None:
                    server_thread.join(timeout=5)
                    require(not server_thread.is_alive(), "Fixture HTTP server did not stop")
            except Exception as error:
                cleanup_errors.append(f"HTTP thread: {error}")
            try:
                cleanup_processes(folder, identifier)
            except Exception as error:
                cleanup_errors.append(f"Fixture processes: {error}")
            try:
                cleanup_domains(*domains)
            except Exception as error:
                cleanup_errors.append(f"Fixture domains/cache: {error}")
            report["cleanupCompleted"] = not cleanup_errors
            if cleanup_errors:
                report["passed"] = False
                report["cleanupErrors"] = cleanup_errors
            report["httpRequests"] = requests
            write_output(output / "result.json", json.dumps(report, indent=2, ensure_ascii=False) + "\n")
            require(not cleanup_errors, "Fixture cleanup failed; see result.json")
    print(f"PASS packaged-payload Sparkle fixture {args.previous_build} -> {args.candidate_build}")
    print("Scope: original executable/helper/framework payload; isolated root identity, metadata and disposable signing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--previous-build", type=int, default=59)
    parser.add_argument("--candidate-build", type=int, default=60)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--cli", type=Path, default=os.environ.get("SPARKLE_TEST_CLI"))
    parser.add_argument("--tools", type=Path, default=os.environ.get("SPARKLE_TOOLS_DIR"))
    args = parser.parse_args()
    if args.cli is None or args.tools is None:
        parser.error("Supply --cli and --tools, or SPARKLE_TEST_CLI and SPARKLE_TOOLS_DIR")
    require(args.timeout > 0, "Timeout must be positive")
    run_test(args)


if __name__ == "__main__":
    main()
