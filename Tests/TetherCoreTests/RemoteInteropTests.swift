import XCTest
@testable import TetherCore

final class RemoteInteropTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let freshness = RemoteFreshnessLimits(connection: 20, frameDelivery: 10, inputRoundTrip: 10, authentication: 30)

    private func scope() -> RemoteEvidenceScope {
        .init(providerID: "splashtop-host", productName: "Splashtop Streamer", role: .host,
              bundleID: "com.splashtop.Splashtop-Streamer", osVersion: "15.7.1", sessionKey: "fixture-session",
              generation: 4, displayRevision: 7, hostInstalledVersion: "3.8.6.0", hostRuntimeVersion: "3.8.6.0", clientVersion: "3.8.5.0")
    }
    private func observed(_ value: Bool? = true, at: Double = 9_999, scope: RemoteEvidenceScope? = nil,
                          source: RemoteEvidenceSource = .publicAPI) -> RemoteObservation<Bool> {
        .init(value: value, availability: .known, reason: .observed, source: source, observedAt: at, scope: scope ?? self.scope())
    }
    private func state(source: RemoteEvidenceSource = .publicAPI) -> RemoteProviderState {
        let scope = scope()
        let version: RemoteObservation<String> = .init(value: "3.8.6.0", availability: .known, reason: .observed,
                                                       source: .bundleMetadata, observedAt: 9_999, scope: scope)
        let runtime: RemoteObservation<String> = .init(value: "3.8.6.0", availability: .known, reason: .observed,
                                                       source: .publicAPI, observedAt: 9_999, scope: scope)
        let client: RemoteObservation<String> = .init(value: "3.8.5.0", availability: .known, reason: .observed,
                                                      source: .publicAPI, observedAt: 9_999, scope: scope)
        return .init(candidate: RemoteSupportCatalog.candidates[0], scope: scope,
                     localInstalledVersion: version, hostInstalledVersion: version, runtimeVersion: runtime, clientVersion: client,
                     connection: observed(source: source), frameDelivery: observed(source: source),
                     inputRoundTrip: observed(source: source), authentication: observed(source: source))
    }

    func testPresenceVirtualDisplayAndAssertionNeverBecomeConnectionProof() throws {
        let display = DisplayObservation(id: 9, builtIn: false, vendor: 0xeee0, model: 0xeee1,
                                         width: 1920, height: 1080, active: true, asleep: false)
        let finding = DisplayFinding(observation: display, name: "Splashtop Display 1", kind: .virtual,
                                     connection: nil, provider: "Splashtop", profileMatched: true, evidence: "fixture")
        let context = RemoteProviderProbe.resolve(
            bundles: ["splashtop-host": .init(metadata: .init(bundleID: "com.splashtop.Splashtop-Streamer", version: "3.8.6.0"),
                                              running: true, reason: .observed)],
            displays: .init(checkedAt: 9_999, displays: [finding], issue: nil, graphicsAvailable: true),
            assertionHints: [.init(pid: 1, process: "Splashtop Streamer", kind: .display, reason: "private-fixture-payload")],
            generation: 4, displayRevision: 7, sessionKey: "fixture-session", osVersion: "15.7.1", now: now)
        let host = try XCTUnwrap(context.providers.first { $0.id == "splashtop-host" })
        XCTAssertEqual(host.candidate.hints.map(\.kind), [.installedBundle, .runningApp, .virtualDisplay, .displayAssertion])
        XCTAssertEqual(host.hostInstalledVersion.value, "3.8.6.0")
        XCTAssertEqual(host.hostInstalledVersion.source, .bundleMetadata)
        XCTAssertNil(host.runtimeVersion.value)
        XCTAssertNil(host.clientVersion.value)
        for observation in [host.connection, host.frameDelivery, host.inputRoundTrip, host.authentication] {
            XCTAssertEqual(observation.availability, .unavailable)
            XCTAssertNil(observation.value)
            XCTAssertEqual(observation.source, .unsupported)
        }
        XCTAssertFalse(host.liveReady(currentScope: host.scope, now: now, freshness: freshness))
        XCTAssertFalse(context.reportLines().joined(separator: "\n").contains("private-fixture-payload"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(context), as: UTF8.self).contains("private-fixture-payload"))
    }

    func testViewerBundleAndMissingLookupDoNotClaimHostServiceOrUninstallation() throws {
        let context = RemoteProviderProbe.resolve(
            bundles: ["apple-sharing-viewer": .init(metadata: .init(bundleID: "com.apple.ScreenSharing", version: "7.0"),
                                                     running: true, reason: .observed)],
            generation: 1, displayRevision: 1, sessionKey: "fixture-session", osVersion: "26.0", now: now)
        let viewer = try XCTUnwrap(context.providers.first { $0.id == "apple-sharing-viewer" })
        let service = try XCTUnwrap(context.providers.first { $0.id == "apple-sharing-host" })
        let missing = try XCTUnwrap(context.providers.first { $0.id == "rustdesk" })
        XCTAssertEqual(viewer.candidate.role, .viewer)
        XCTAssertEqual(viewer.localInstalledVersion.summary, "7.0")
        XCTAssertEqual(viewer.hostInstalledVersion.availability, .notApplicable)
        XCTAssertNil(viewer.hostInstalledVersion.value)
        XCTAssertNil(service.candidate.bundleID)
        XCTAssertTrue(service.candidate.hints.isEmpty)
        XCTAssertEqual(service.connection.reason, .hostServiceUnavailable)
        XCTAssertNil(service.localInstalledVersion.value)
        XCTAssertEqual(missing.localInstalledVersion.reason, .bundleNotObserved)
        XCTAssertEqual(missing.localInstalledVersion.availability, .unavailable)
        XCTAssertFalse(service.liveReady(currentScope: service.scope, now: now, freshness: freshness))
        XCTAssertFalse(viewer.liveReady(currentScope: viewer.scope, now: now, freshness: freshness))
    }

    func testBundleIdentifierAndVersionRequireExactBoundedMetadata() {
        let id = "com.carriez.rustdesk"
        XCTAssertEqual(RemoteProviderProbe.validatedMetadata(["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.4.4"], expectedBundleID: id)?.version, "1.4.4")
        for wrong in ["com.carriez.RustDesk", "com.carriez.flutterHbb", "com.other.rustdesk"] {
            XCTAssertNil(RemoteProviderProbe.validatedMetadata(["CFBundleIdentifier": wrong, "CFBundleShortVersionString": "1.4.4"], expectedBundleID: id))
        }
        for version in ["", "1.4.4\n", " 1.4.4", "1.4\u{0}4", String(repeating: "1", count: 81)] {
            XCTAssertNil(RemoteProviderProbe.validatedMetadata(["CFBundleIdentifier": id, "CFBundleShortVersionString": version], expectedBundleID: id))
        }
        XCTAssertNil(RemoteProviderProbe.validatedMetadata(["CFBundleIdentifier": id, "CFBundleShortVersionString": 144], expectedBundleID: id))
        XCTAssertNil(RemoteProviderProbe.validatedMetadata(["CFBundleIdentifier": id, "CFBundleVersion": "144"], expectedBundleID: id))
    }

    func testEveryConfigurationBoundaryInvalidatesLateSuccess() {
        let current = scope()
        let observation = observed()
        XCTAssertEqual(observation.validity(currentScope: current, now: now, maximumAge: 20), .current)
        let changes: [(inout RemoteEvidenceScope) -> Void] = [
            { $0.providerID = "another-host" }, { $0.productName = "Another edition" }, { $0.role = .viewer },
            { $0.bundleID = "com.other.host" }, { $0.osVersion = "26.0" }, { $0.sessionKey = "new-session" },
            { $0.generation += 1 }, { $0.displayRevision += 1 }, { $0.hostInstalledVersion = "3.9.0.0" },
            { $0.hostRuntimeVersion = "3.8.5.0" }, { $0.clientVersion = "3.8.6.0" }
        ]
        for change in changes {
            var replacement = current
            change(&replacement)
            XCTAssertEqual(observation.validity(currentScope: replacement, now: now, maximumAge: 20), .scopeMismatch)
            XCTAssertFalse(state().liveReady(currentScope: replacement, now: now, freshness: freshness))
        }
        for invalidKey in ["", "unavailable", "UNKNOWN", " unavailable "] {
            var unavailable = current; unavailable.sessionKey = invalidKey
            XCTAssertEqual(observed(scope: unavailable).validity(currentScope: unavailable, now: now, maximumAge: 20), .unverifiedScope)
        }
        var missingVersion = current; missingVersion.hostRuntimeVersion = nil
        XCTAssertEqual(observed(scope: missingVersion).validity(currentScope: missingVersion, now: now, maximumAge: 20), .unverifiedScope)
        missingVersion = current; missingVersion.clientVersion = nil
        XCTAssertEqual(observed(scope: missingVersion).validity(currentScope: missingVersion, now: now, maximumAge: 20), .unverifiedScope)
    }

    func testFreshConnectionDoesNotRefreshOtherMetricsOrOverrideFailure() {
        XCTAssertTrue(state().liveReady(currentScope: scope(), now: now, freshness: freshness))
        for metric in ["frame", "input", "authentication"] {
            var candidate = state()
            switch metric {
            case "frame": candidate.frameDelivery = observed(at: 9_980)
            case "input": candidate.inputRoundTrip = observed(at: 9_980)
            default: candidate.authentication = observed(at: 9_960)
            }
            XCTAssertEqual(candidate.connection.observedAt, 9_999)
            XCTAssertFalse(candidate.liveReady(currentScope: scope(), now: now, freshness: freshness))
        }
        var disconnected = state(); disconnected.connection = observed(false)
        XCTAssertFalse(disconnected.liveReady(currentScope: scope(), now: now, freshness: freshness))
        var inputFailed = state(); inputFailed.inputRoundTrip = observed(false)
        XCTAssertFalse(inputFailed.liveReady(currentScope: scope(), now: now, freshness: freshness))
        XCTAssertEqual(observed(at: 10_001).validity(currentScope: scope(), now: now, maximumAge: 20), .future)
        XCTAssertEqual(observed(at: .nan).validity(currentScope: scope(), now: now, maximumAge: 20), .invalidTime)
        XCTAssertEqual(observed().validity(currentScope: scope(), now: now, maximumAge: -1), .invalidFreshnessLimit)
        XCTAssertEqual(observed().validity(currentScope: scope(), now: now, maximumAge: .infinity), .invalidFreshnessLimit)
        XCTAssertEqual(observed(nil).validity(currentScope: scope(), now: now, maximumAge: 20), .missingValue)
    }

    func testUnsupportedHintAndHistoricalProofNeverBecomeLiveReady() {
        for source in [RemoteEvidenceSource.unsupported, .hint, .bundleMetadata, .physicalVerification] {
            XCTAssertEqual(observed(source: source).validity(currentScope: scope(), now: now, maximumAge: 20), .unsupportedSource)
            XCTAssertFalse(state(source: source).liveReady(currentScope: scope(), now: now, freshness: freshness))
        }
        let physical = RemotePhysicalVerification(scope: scope(), observedAt: 9_999, connection: true,
                                                   frameDelivery: true, inputRoundTrip: true, authentication: true)
        XCTAssertTrue(physical.matchesConfiguration(scope(), now: now))
        var updated = scope(); updated.displayRevision += 1
        XCTAssertFalse(physical.matchesConfiguration(updated, now: now))
        let future = RemotePhysicalVerification(scope: scope(), observedAt: 10_001, connection: true,
                                                frameDelivery: true, inputRoundTrip: true, authentication: true)
        XCTAssertFalse(future.matchesConfiguration(scope(), now: now))
        var historicalOnly = state(source: .physicalVerification)
        historicalOnly.lastPhysicalVerification = physical
        XCTAssertFalse(historicalOnly.liveReady(currentScope: scope(), now: now, freshness: freshness))
    }

    func testPreviewAndForcedUnavailableRemainUnverifiedAndRoundTripSafely() throws {
        let example = RemoteProviderProbe.sample(generation: 3, displayRevision: 6, sessionKey: "fixture-session", now: now)
        XCTAssertTrue(example.simulated)
        XCTAssertEqual(example, try JSONDecoder().decode(RemoteInteropContext.self, from: JSONEncoder().encode(example)))
        let host = try XCTUnwrap(example.providers.first { $0.id == "splashtop-host" })
        XCTAssertEqual(host.hostInstalledVersion.source, .hint)
        XCTAssertEqual(host.hostInstalledVersion.reason, .sampleOnly)
        XCTAssertTrue(host.candidate.hints.contains { $0.kind == .previewExample })
        XCTAssertFalse(host.liveReady(currentScope: host.scope, now: now, freshness: freshness))
        let unavailable = RemoteProviderProbe.resolve(
            bundles: ["splashtop-host": .init(metadata: .init(bundleID: "com.splashtop.Splashtop-Streamer", version: "3.8.6.0"),
                                              running: true, reason: .observed)],
            generation: 3, displayRevision: 6, sessionKey: "unavailable", osVersion: "15.0", forceUnavailable: true, now: now)
        XCTAssertTrue(unavailable.providers.allSatisfy { $0.candidate.hints.isEmpty && $0.localInstalledVersion.value == nil })
        XCTAssertTrue(unavailable.providers.allSatisfy { !$0.liveReady(currentScope: $0.scope, now: now, freshness: freshness) })
        XCTAssertFalse(example.reportLines().joined(separator: "\n").contains("fixture-session"))
        XCTAssertFalse(example.reportLines().joined(separator: "\n").contains("live ready"))
        XCTAssertTrue(example.guides.allSatisfy { $0.url.hasPrefix("https://") && !$0.englishDetail.isEmpty && !$0.koreanDetail.isEmpty })
    }
}
