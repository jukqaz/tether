import XCTest
import Sparkle
@testable import Tether
import TetherCore

@MainActor
final class AppUpdaterTests: XCTestCase {
    /// Sparkle resolves SUDefaultsDomain inside this disposable, non-main bundle.
    /// No production preference, running app, download or installer is involved.
    private func withStartupFixture(feedURL: String? = "http://127.0.0.1:1/appcast.xml",
                                    publicKey: String = Data(repeating: 1, count: 32).base64EncodedString(),
                                    _ body: (Bundle, UserDefaults) async throws -> Void) async throws {
        let name = "io.github.jukqaz.tether.startup-test." + UUID().uuidString
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("tether-updater-" + UUID().uuidString)
        let contents = directory.appendingPathComponent("Fixture.bundle/Contents")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            _ = defaults.synchronize()
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": name, "CFBundleName": "Updater Startup Fixture",
            "CFBundlePackageType": "BNDL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "SUDefaultsDomain": name, "SUPublicEDKey": publicKey,
            "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
            "SUSignedFeedFailureExpirationInterval": 0,
            "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true]
        ]
        if let feedURL { info["SUFeedURL"] = feedURL }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        XCTAssertEqual(bundle.bundleIdentifier, name)
        XCTAssertNotEqual(bundle, .main)
        try await body(bundle, defaults)
    }

    private func waitForLifecycle(_ condition: () -> Bool, file: StaticString = #filePath,
                                  line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "Sparkle fixture lifecycle did not settle", file: file, line: line)
    }

    func testNativeStartupClearsOnlyFixtureFeedAndPublishesInitialKVOWithoutChecking() async throws {
        try await withStartupFixture { bundle, defaults in
            let checked = Date(timeIntervalSince1970: 1_700_000_000)
            defaults.set("http://127.0.0.1:1/old-beta.xml", forKey: "SUFeedURL")
            defaults.set(checked, forKey: "SULastCheckTime")
            defaults.set(true, forKey: "SUAutomaticallyUpdate")
            defaults.set("preserved", forKey: "unrelatedSetting")
            var snapshots: [AppUpdateStatus] = []
            let subject = AppUpdater(hostBundle: bundle, defaults: defaults, lidClosed: { false }) { snapshots.append($0) }
            subject.start(automatically: false, channel: .beta)
            let engine = try XCTUnwrap(subject.engine)
            XCTAssertEqual(engine.hostBundle, bundle)
            XCTAssertTrue(engine.canCheckForUpdates, "SPUUpdater.start must complete configuration validation")
            XCTAssertEqual(engine.feedURL?.absoluteString, "http://127.0.0.1:1/appcast.xml")
            XCTAssertNil(defaults.object(forKey: "SUFeedURL"))
            XCTAssertFalse(engine.automaticallyChecksForUpdates)
            XCTAssertFalse(engine.automaticallyDownloadsUpdates)
            XCTAssertEqual(subject.allowedChannels(for: engine), ["beta"])
            XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
            XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, false)
            try await waitForLifecycle { snapshots.count >= 2 && defaults.bool(forKey: "SUHasLaunchedBefore") }
            XCTAssertTrue(snapshots.allSatisfy { !$0.sessionInProgress && !$0.checking && $0.error == nil })
            XCTAssertEqual(snapshots.last?.lastChecked, checked)
            XCTAssertEqual(defaults.string(forKey: "unrelatedSetting"), "preserved")
            XCTAssertEqual(defaults.object(forKey: "SULastCheckTime") as? Date, checked)
            // An accidental second start must not replace the engine or change the chosen channel.
            subject.start(automatically: true, channel: .stable)
            XCTAssertTrue(subject.engine === engine)
            XCTAssertFalse(subject.automaticallyChecks)
            XCTAssertEqual(subject.allowedChannels(for: engine), ["beta"])
        }
    }

    func testNativeConfigurationFailurePublishesErrorWithoutStartingOrChecking() async throws {
        try await withStartupFixture(publicKey: "invalid-public-key") { bundle, defaults in
            var snapshots: [AppUpdateStatus] = []
            let subject = AppUpdater(hostBundle: bundle, defaults: defaults) { snapshots.append($0) }
            subject.start(automatically: false, channel: .stable)
            let engine = try XCTUnwrap(subject.engine)
            XCTAssertFalse(engine.canCheckForUpdates)
            XCTAssertTrue(snapshots.last?.error?.contains("EdDSA") == true)
            try await waitForLifecycle { snapshots.count >= 2 }
            XCTAssertTrue(snapshots.allSatisfy { !$0.sessionInProgress && !$0.checking })
            XCTAssertFalse(defaults.bool(forKey: "SUHasLaunchedBefore"))
            XCTAssertNil(defaults.object(forKey: "SULastCheckTime"))
        }
    }

    func testNativeProbingCyclePublishesKVOAndConfigurationFailureBeforeAnyNetworkRequest() async throws {
        // start permits a missing feed, but a probe rejects it before the appcast downloader runs.
        // The probing driver shows no UI and a unique bundle has no cached installer to resume.
        try await withStartupFixture(feedURL: nil) { bundle, defaults in
            defaults.set(true, forKey: "SUAutomaticallyUpdate")
            var snapshots: [AppUpdateStatus] = []
            let subject = AppUpdater(hostBundle: bundle, defaults: defaults) { snapshots.append($0) }
            subject.start(automatically: false, channel: .stable)
            let engine = try XCTUnwrap(subject.engine)
            XCTAssertTrue(engine.canCheckForUpdates)
            try await waitForLifecycle { defaults.bool(forKey: "SUHasLaunchedBefore") && snapshots.count >= 2 }
            snapshots.removeAll()
            engine.checkForUpdateInformation()
            XCTAssertTrue(engine.sessionInProgress)
            XCTAssertFalse(subject.select(.beta))
            try await waitForLifecycle { snapshots.contains(where: { $0.sessionInProgress }) && snapshots.last?.error != nil && snapshots.last?.sessionInProgress == false }
            XCTAssertTrue(engine.canCheckForUpdates)
            XCTAssertFalse(engine.sessionInProgress)
            XCTAssertTrue(snapshots.last?.error?.contains("SUFeedURL") == true)
            XCTAssertFalse(snapshots.last?.checking ?? true)
            XCTAssertFalse(snapshots.last?.waitingForOpenLid ?? true)
            XCTAssertNil(snapshots.last?.availableVersion)
            XCTAssertTrue(subject.canTerminateForUpdate)
            XCTAssertNil(defaults.object(forKey: "SUFeedURL"))
            // A later opt-in to checks must not revive the legacy automatic-download choice.
            // This fixture has no feed, and both changes precede Sparkle's delayed scheduler.
            subject.automaticallyChecks = true
            XCTAssertFalse(engine.automaticallyDownloadsUpdates)
            XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, false)
            subject.automaticallyChecks = false
        }
    }

    func testResumedBetaIsCanceledAtEveryStageAfterSelectingStable() throws {
        var channel = UpdateChannel.beta
        var rejections = 0
        let driver = UpdateUserDriver(hostBundle: .main, delegate: nil,
            accepts: { channel.accepts(candidateChannel: $0) }, rejected: { rejections += 1 })
        // Only system-independent metadata is used from this deprecated fixture initializer.
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:channel": "beta", "sparkle:version": "43",
            "enclosure": ["url": "https://example.invalid/Tether.zip", "sparkle:version": "43"]
        ]))
        XCTAssertEqual(item.channel, "beta")
        channel = .stable
        for stage: SPUUserUpdateStage in [.notDownloaded, .downloaded, .installing] {
            let state = try makeState(stage)
            XCTAssertEqual(state.stage, stage)
            var replies: [SPUUserUpdateChoice] = []
            driver.showUpdateFound(with: item, state: state) { replies.append($0) }
            XCTAssertEqual(replies, [.skip]) // Dismiss would leave an install-on-quit pending.
        }
        XCTAssertEqual(rejections, 3)
    }
    func testPostponingReadyUpdateCancelsThePreparedInstaller() {
        XCTAssertEqual(UpdateUserDriver.explicitInstallationChoice(.dismiss), .skip)
        XCTAssertEqual(UpdateUserDriver.explicitInstallationChoice(.install), .install)
        XCTAssertEqual(UpdateUserDriver.explicitInstallationChoice(.skip), .skip)
        let driver = UpdateUserDriver(hostBundle: .main, delegate: nil, accepts: { _ in true }, rejected: {})
        XCTAssertTrue(driver.responds(to: #selector(SPUUserDriver.showReady(toInstallAndRelaunch:))))
    }
    func testPostponingResumedInstallerCancelsWithoutSkippingUndownloadedUpdate() {
        XCTAssertEqual(UpdateUserDriver.foundUpdateChoice(.dismiss, stage: .installing), .skip)
        XCTAssertEqual(UpdateUserDriver.foundUpdateChoice(.install, stage: .installing), .install)
        XCTAssertEqual(UpdateUserDriver.foundUpdateChoice(.dismiss, stage: .downloaded), .dismiss)
        XCTAssertEqual(UpdateUserDriver.foundUpdateChoice(.dismiss, stage: .notDownloaded), .dismiss)
    }
    func testExtractionGuardsTerminationUntilTheUpdateCycleEnds() {
        var lid: Bool? = false
        let subject = AppUpdater(lidClosed: { lid }) { _ in }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: subject, userDriverDelegate: subject)
        subject.updater(controller.updater, willExtractUpdate: .empty())
        XCTAssertTrue(subject.canTerminateForUpdate)
        XCTAssertTrue(subject.installationRequested)
        lid = true; XCTAssertFalse(subject.canTerminateForUpdate)
        lid = nil; XCTAssertFalse(subject.canTerminateForUpdate)
        subject.updater(controller.updater, didFinishUpdateCycleFor: .updates, error: nil)
        XCTAssertTrue(subject.canTerminateForUpdate)
        XCTAssertFalse(subject.installationRequested)
    }
    private func makeState(_ stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        // Exercise Sparkle's real secure-coding type without importing its private headers.
        let writer = NSKeyedArchiver(requiringSecureCoding: true)
        writer.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        writer.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
        writer.finishEncoding()
        let reader = try NSKeyedUnarchiver(forReadingFrom: writer.encodedData)
        defer { reader.finishDecoding() }
        return try XCTUnwrap(SPUUserUpdateState(coder: reader))
    }
    func testSparkleCallsTheActualDelegateSelectors() {
        let subject = AppUpdater { _ in }
        XCTAssertTrue(subject.responds(to: #selector(SPUUpdaterDelegate.allowedChannels(for:))))
        XCTAssertTrue(subject.responds(to: #selector(SPUUpdaterDelegate.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:))))
        XCTAssertTrue(subject.responds(to: #selector(SPUUpdaterDelegate.updater(_:didFinishUpdateCycleFor:error:))))
        XCTAssertTrue(subject.responds(to: #selector(SPUStandardUserDriverDelegate.standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:))))
    }
    func testActualDelegateDefersAndResumesOnceWithFreshLid() {
        var lid: Bool? = true, count = 0
        var status = AppUpdateStatus()
        let subject = AppUpdater(lidClosed: { lid }) { status = $0 }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: subject, userDriverDelegate: subject)
        let item = SUAppcastItem.empty()
        XCTAssertTrue(subject.updater(controller.updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { count += 1 }))
        XCTAssertTrue(status.waitingForOpenLid)
        subject.resumeInstallation(); XCTAssertEqual(count, 0)
        lid = nil; subject.resumeInstallation(); XCTAssertEqual(count, 0)
        lid = false; XCTAssertEqual(count, 0)
        subject.resumeInstallation(); subject.resumeInstallation()
        XCTAssertEqual(count, 1); XCTAssertFalse(status.waitingForOpenLid)
        lid = true; XCTAssertFalse(subject.canTerminateForUpdate)
    }
    func testAbortedUpdateClearsContinuationAndExposesFailure() {
        var lid: Bool? = true
        var status = AppUpdateStatus()
        let subject = AppUpdater(lidClosed: { lid }) { status = $0 }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: subject, userDriverDelegate: subject)
        _ = subject.updater(controller.updater, shouldPostponeRelaunchForUpdate: .empty(), untilInvokingBlock: { XCTFail("aborted installer") })
        subject.updater(controller.updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertNotNil(status.error); XCTAssertFalse(status.waitingForOpenLid)
        lid = false; subject.resumeInstallation()
        XCTAssertTrue(subject.canTerminateForUpdate)
    }
    func testSelectedChannelsReachSparkleAndStableIsDefault() {
        let subject = AppUpdater { _ in }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: subject, userDriverDelegate: subject)
        XCTAssertEqual(subject.allowedChannels(for: controller.updater), [])
        XCTAssertTrue(subject.select(.beta))
        XCTAssertEqual(subject.allowedChannels(for: controller.updater), ["beta"])
        XCTAssertTrue(subject.select(.stable))
        XCTAssertEqual(subject.allowedChannels(for: controller.updater), [])
    }
    func testScheduledReminderNeverOpensWindowInEitherFocusState() {
        let subject = AppUpdater { _ in }
        XCTAssertTrue(subject.supportsGentleScheduledUpdateReminders)
        for focus in [true, false] {
            XCTAssertFalse(subject.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: focus))
        }
    }
    func testSuccessfulCheckClearsAnEarlierNetworkFailure() {
        var status = AppUpdateStatus()
        let subject = AppUpdater { status = $0 }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: subject, userDriverDelegate: subject)
        subject.updater(controller.updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertNotNil(status.error)
        subject.updaterDidNotFindUpdate(controller.updater)
        XCTAssertNil(status.error); XCTAssertNil(status.availableVersion); XCTAssertNotNil(status.lastChecked)
        subject.standardUserDriverWillFinishUpdateSession()
        XCTAssertNil(status.availableVersion)
    }

    private func candidate(_ version: String = "43") throws -> SUAppcastItem {
        try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": version, "sparkle:shortVersionString": "4.0",
            "enclosure": ["url": "https://example.invalid/Tether-\(version).zip",
                "sparkle:version": version, "length": "1024", "sparkle:edSignature": "fixture-signature-\(version)"]
        ]))
    }

    func testFindingAnUpdateDoesNotPrepareOrReserveInstallation() async throws {
        try await withStartupFixture { bundle, defaults in
            var status = AppUpdateStatus()
            let subject = AppUpdater(hostBundle: bundle, defaults: defaults, lidClosed: { false }) { status = $0 }
            let driver = subject.makeUserDriver()
            let dormant = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: subject)
            subject.updater(dormant, didFindValidUpdate: try candidate())
            XCTAssertNotNil(status.availableVersion)
            XCTAssertFalse(subject.installationRequested)
            XCTAssertNil(subject.engine, "Observing a candidate does not start a framework cycle or download")
            subject.resumeInstallation()
            XCTAssertFalse(subject.installationRequested, "There is no hidden work-end callback to resume")
        }
    }

    func testExplicitSparkleRepliesRecheckCurrentSafetyAndAreAnsweredOnce() {
        for stage: SPUUserUpdateStage in [.installing, .downloaded, .notDownloaded] {
            var allowed = true
            var replies: [SPUUserUpdateChoice] = []
            let reply = UpdateUserDriver.checkedInstallationReply(stage: stage,
                installationAllowed: { allowed }, reply: { replies.append($0) })
            allowed = false
            reply(.install)
            allowed = true
            reply(.install)
            XCTAssertEqual(replies, [stage == .installing ? .skip : .install],
                "Only an eventual install/relaunch requires the fresh gate; every callback is answered once")
        }
    }

    func testDismissingAnExplicitInstallerCannotArmInstallOnQuit() {
        var replies: [SPUUserUpdateChoice] = []
        let reply = UpdateUserDriver.checkedInstallationReply(stage: .installing,
            installationAllowed: { true }, reply: { replies.append($0) })
        reply(.dismiss)
        reply(.install)
        XCTAssertEqual(replies, [.skip])
    }
}
