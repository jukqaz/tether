import XCTest
@testable import TetherCore

// Exercise migration and real backup files without writing test domains to
// the user's cfprefsd store, which can recreate empty plists after deletion.
private final class MigrationTestDefaults: UserDefaults {
    private var domains: [String: [String: Any]] = [:]
    override func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { domains[domainName] = domain }
    override func removePersistentDomain(forName domainName: String) { domains.removeValue(forKey: domainName) }
}

final class MigrationTests: XCTestCase {
    private var folder: URL!
    private var path: String { folder.appendingPathComponent("control.json").path }
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tether-migration-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func write(_ json: String) throws { try Data(json.utf8).write(to: URL(fileURLWithPath: path)) }

    // 2.0.0 and 2.0.1 have the same persisted fields; the difference was how they wrote the file.
    func testReleased20SettingsPreserveEveryPersistentValueAndExactOriginal() throws {
        let original = #"{ "enabled":false, "limits":{"batteryFloor":40,"closedLidMaxTemperature":38,"openLidMaxTemperature":42,"maxHoldHours":1}, "heatGuard":{"enabled":false,"level":1}, "holdLowPower":false, "debugLog":true, "appPath":"/Applications/Tether.app/Contents/MacOS/Tether", "batteryHoldUntil":9999999999, "sleepNowRequest":9999999900, "holdSource":"cli", "unknownFromOldVersion":{"keep":"original"} }"#
        try write(original)
        let report = try XCTUnwrap(SettingsMigration.migrate(controlPath: path))
        let result = try XCTUnwrap(JSONFile.read(Control.self, from: path))
        XCTAssertEqual(result.schemaVersion, Control.currentSchema); XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.condition, .ac)
        XCTAssertEqual(result.limits, UserLimits(batteryFloor: 40, maxHoldHours: 1))
        XCTAssertNil(result.heatGuard)
        XCTAssertNil(result.holdLowPower); XCTAssertEqual(result.debugLog, true)
        XCTAssertEqual(result.appPath, "/Applications/Tether.app/Contents/MacOS/Tether")
        XCTAssertNil(result.batteryHoldUntil); XCTAssertNil(result.sleepNowRequest); XCTAssertNil(result.holdSource)
        let backup = folder.appendingPathComponent("migrations/\(report.backupName)")
        XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testDefaultsStayDefaultsForMinimalReleasedConfig() throws {
        try write(#"{"enabled":true}"#)
        _ = try SettingsMigration.migrate(controlPath: path)
        let result = try XCTUnwrap(JSONFile.read(Control.self, from: path))
        XCTAssertTrue(result.enabled); XCTAssertEqual(result.condition, .ac)
        XCTAssertEqual(SafetyPolicy.floor(result.limits),20)
        XCTAssertEqual(SafetyPolicy.maxHold(result.limits),14400)
    }
    func test21DevelopmentProfilesAndPauseNeverActivateRemovedModes() throws {
        for profile in ["tasks","presentation","travel","remote"] {
            try write("{\"schemaVersion\":1,\"enabled\":true,\"profile\":\"\(profile)\",\"limits\":{\"batteryFloor\":30},\"batteryHoldUntil\":9999999999}")
            _ = try SettingsMigration.migrate(controlPath: path)
            let result = try XCTUnwrap(JSONFile.read(Control.self, from: path))
            XCTAssertFalse(result.enabled); XCTAssertEqual(result.limits?.batteryFloor,30); XCTAssertNil(result.batteryHoldUntil)
        }
        try write(#"{"schemaVersion":1,"enabled":true,"profile":"cable","paused":true}"#)
        _ = try SettingsMigration.migrate(controlPath:path)
        XCTAssertEqual(JSONFile.read(Control.self,from:path)?.enabled,false)
    }
    func testAdaptivePolicyFreezesEffectiveLimits() throws {
        try write(#"{"enabled":true,"autoLimits":true,"limits":{"batteryFloor":40,"maxHoldHours":1}}"#)
        let report = try XCTUnwrap(SettingsMigration.migrate(controlPath:path))
        XCTAssertTrue(report.frozeAdaptiveLimits)
        let result = try XCTUnwrap(JSONFile.read(Control.self,from:path))
        XCTAssertNil(result.autoLimits)
        XCTAssertEqual(SafetyPolicy.floor(result.limits),40)
        XCTAssertEqual(SafetyPolicy.maxHold(result.limits),3600)
        XCTAssertFalse(result.enabled)
        XCTAssertNil(result.limits?.closedLidMaxTemperature)
        XCTAssertNil(result.limits?.openLidMaxTemperature)
    }
    private func measuredUsage(seconds: Double = 3600, drain: Double = 30,
                               starts: [Int] = [], day: Date = Date().addingTimeInterval(-2 * 86400)) -> Usage {
        let stats = StatsTracker(days: [DayStats(day: StatsTracker.dayKey(day), holdSeconds: seconds, holdDrain: drain)])
        let sessions = starts.map { charge in
            LidSession(start: 0, end: 3600, lastSeen: 3600, maxTemperature: nil, maxThermal: 0,
                       batteryStart: charge, batteryEnd: nil, lowPower: false, onBattery: true)
        }
        return Usage(stats: stats, recentSessions: sessions)
    }
    func testAdaptiveMigrationFreezesMeasuredAllowanceAndPreservesOriginal() throws {
        let original = #"{"enabled":true,"autoLimits":true,"limits":{"batteryFloor":20},"batteryHoldUntil":9999999999,"holdSource":"app"}"#
        try write(original)
        let report = try XCTUnwrap(SettingsMigration.migrate(controlPath: path, usage: measuredUsage()))
        let result = try XCTUnwrap(JSONFile.read(Control.self, from: path))
        XCTAssertTrue(report.frozeAdaptiveLimits)
        XCTAssertEqual(result.limits, UserLimits(batteryFloor: 20, maxHoldHours: 2))
        XCTAssertFalse(result.enabled)
        XCTAssertNil(result.batteryHoldUntil)
        XCTAssertNil(result.holdSource)
        XCTAssertNil(result.autoLimits)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("migrations/\(report.backupName)")), Data(original.utf8))
        let migrated = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNil(try SettingsMigration.migrate(controlPath: path, usage: measuredUsage(drain: 80)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), migrated)
    }
    func testAdaptiveMigrationNeverLoosensAStricterUserAllowance() throws {
        try write(#"{"enabled":false,"autoLimits":true,"limits":{"batteryFloor":40,"maxHoldHours":0.5}}"#)
        _ = try SettingsMigration.migrate(controlPath: path, usage: measuredUsage())
        let result = try XCTUnwrap(JSONFile.read(Control.self, from: path))
        XCTAssertEqual(result.limits, UserLimits(batteryFloor: 40, maxHoldHours: 0.5))
        XCTAssertFalse(result.enabled)
    }
    func testAdaptiveMigrationUsesAverageStartingCharge() throws {
        try write(#"{"enabled":true,"autoLimits":true,"limits":{"batteryFloor":40}}"#)
        _ = try SettingsMigration.migrate(controlPath: path, usage: measuredUsage(starts: [70, 90]))
        XCTAssertEqual(JSONFile.read(Control.self, from: path)?.limits, UserLimits(batteryFloor: 40, maxHoldHours: 1))
    }
    func testAdaptiveMigrationWaitsForEnoughValidMeasurements() throws {
        for usage in [measuredUsage(seconds: 899, drain: 80), measuredUsage(drain: 0),
                      measuredUsage(seconds: .infinity), measuredUsage(drain: .nan),
                      measuredUsage(day: Date().addingTimeInterval(-10 * 86400))] {
            try write(#"{"enabled":true,"autoLimits":true}"#)
            _ = try SettingsMigration.migrate(controlPath: path, usage: usage)
            XCTAssertEqual(JSONFile.read(Control.self, from: path)?.limits, UserLimits(batteryFloor: 20, maxHoldHours: 4))
        }
    }
    func testAdaptiveMigrationIncludesTheFifteenMinuteBoundary() throws {
        try write(#"{"enabled":true,"autoLimits":true}"#)
        _ = try SettingsMigration.migrate(controlPath: path, usage: measuredUsage(seconds: 900, drain: 7.5))
        XCTAssertEqual(JSONFile.read(Control.self, from: path)?.limits?.maxHoldHours, 2)
    }
    func testNonAdaptiveMigrationIgnoresHistoricalRecommendations() throws {
        for flag in ["", ",\"autoLimits\":false"] {
            try write("{\"enabled\":true,\"limits\":{\"batteryFloor\":30,\"maxHoldHours\":3}\(flag)}")
            let report = try XCTUnwrap(SettingsMigration.migrate(controlPath: path, usage: measuredUsage(drain: 80)))
            XCTAssertFalse(report.frozeAdaptiveLimits)
            let result = try XCTUnwrap(JSONFile.read(Control.self, from: path))
            XCTAssertTrue(result.enabled)
            XCTAssertEqual(result.limits, UserLimits(batteryFloor: 30, maxHoldHours: 3))
        }
    }
    func testRepeatedMigrationAndLaterUserEditsArePreserved() throws {
        try write(#"{"enabled":false}"#)
        let report = try XCTUnwrap(SettingsMigration.migrate(controlPath:path))
        var next = try XCTUnwrap(JSONFile.read(Control.self,from:path))
        next.powerCondition = .ac; next.automaticHoldMinutes = 30; next.limits = UserLimits(batteryFloor:50)
        XCTAssertTrue(JSONFile.write(next,to:path,permissions:0o644))
        let before = try Data(contentsOf: URL(fileURLWithPath:path))
        XCTAssertNil(try SettingsMigration.migrate(controlPath:path))
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),before)
        XCTAssertEqual(JSONFile.read(MigrationReport.self,from:folder.appendingPathComponent("migration-report.json").path),report)
    }
    func testV4MigrationRetiresBatteryOnlyButKeepsTheACPortionAndExactBackup() throws {
        for condition in ["battery", "any", "ac"] {
            let original = "{\"schemaVersion\":3,\"enabled\":true,\"powerCondition\":\"\(condition)\",\"limits\":{\"batteryFloor\":35}}"
            try write(original)
            let report = try XCTUnwrap(SettingsMigration.migrate(controlPath: path))
            let result = try XCTUnwrap(JSONFile.read(Control.self, from: path))
            XCTAssertEqual(result.enabled, condition != "battery")
            XCTAssertEqual(result.powerCondition, .ac)
            XCTAssertEqual(result.limits?.batteryFloor, 35)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("migrations/\(report.backupName)")), Data(original.utf8))
        }
    }
    func testCurrentSchemaCannotSilentlyReintroduceRetiredBatteryAutomation() throws {
        let original = "{\"schemaVersion\":\(Control.currentSchema),\"enabled\":true,\"powerCondition\":\"battery\"}"
        try write(original)
        XCTAssertThrowsError(try SettingsMigration.migrate(controlPath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(original.utf8))
    }
    func testCorruptUnsupportedAndUnknownConditionsDoNotOverwrite() throws {
        for json in ["{",#"{"enabled":true,"schemaVersion":99}"#,#"{"enabled":true,"powerCondition":"mystery"}"#,#"{"enabled":"yes"}"#] {
            try write(json)
            XCTAssertThrowsError(try SettingsMigration.migrate(controlPath:path))
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),Data(json.utf8))
        }
    }
    func testBackupFailureStopsBeforeRewritingSettings() throws {
        try write(#"{"enabled":false}"#)
        try Data("occupied".utf8).write(to:folder.appendingPathComponent("migrations"))
        XCTAssertThrowsError(try SettingsMigration.migrate(controlPath:path))
        XCTAssertEqual(String(data:try Data(contentsOf:URL(fileURLWithPath:path)),encoding:.utf8),#"{"enabled":false}"#)
    }
    func testReportFailureKeepsRawOriginalAndRecoveryCopy() throws {
        try write(#"{"enabled":false}"#)
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("migration-report.json"),withIntermediateDirectories:false)
        XCTAssertThrowsError(try SettingsMigration.migrate(controlPath:path))
        XCTAssertNil(JSONFile.read(Control.self,from:path)?.schemaVersion)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.appendingPathComponent("migrations").path).count,1)
    }
    func testSymlinkBackupDirectoryIsRefused() throws {
        try write(#"{"enabled":false}"#)
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("migrations"),withDestinationURL:folder)
        XCTAssertThrowsError(try SettingsMigration.migrate(controlPath:path))
    }
    func testLegacyPreferencesKeepDestinationFalseAndRecoveryBrightness() {
        let current:[String:Any] = ["checkUpdates":false,"menuBarDetails":false,"language":"ko"]
        let old:[String:Any] = ["checkUpdates":true,"menuBarDetails":true,"notifyHeat":false,"savedBuiltInBrightness":0.7,"savedKeyboardBrightness":0.4]
        let result = PreferenceMigration.merged(current:current,legacy:old,hadExistingInstall:true)
        XCTAssertEqual(result["checkUpdates"] as? Bool,false)
        XCTAssertEqual(result["SUEnableAutomaticChecks"] as? Bool,false)
        XCTAssertEqual(result["menuBarDetails"] as? Bool,false)
        XCTAssertEqual(result["notifyHeat"] as? Bool,false)
        XCTAssertEqual(result["savedBuiltInBrightness"] as? Double,0.7)
        XCTAssertEqual(result["savedKeyboardBrightness"] as? Double,0.4)
        XCTAssertEqual(result["launchAtLoginConfigured"] as? Bool,true)
        XCTAssertEqual(result["language"] as? String,"ko")
        let again = PreferenceMigration.merged(current:result,legacy:["notifyHeat":true],hadExistingInstall:true)
        XCTAssertEqual(again["notifyHeat"] as? Bool,false)
    }
    func testFreshInstallAndExistingSparkleChoiceAreDistinct() {
        let fresh = PreferenceMigration.merged(current:[:],legacy:[:],hadExistingInstall:false)
        XCTAssertNil(fresh["launchAtLoginConfigured"])
        let existing = PreferenceMigration.merged(current:["SUEnableAutomaticChecks":false,"checkUpdates":true],legacy:[:],hadExistingInstall:true)
        XCTAssertEqual(existing["SUEnableAutomaticChecks"] as? Bool,false)
    }
    func testSameMarketingVersionStillRequiresCurrentHelperBuild() throws {
        let old = "{\"updatedAt\":1,\"version\":\"\(TetherPaths.version)\",\"enabled\":false,\"power\":\"ac\",\"lidClosed\":false,\"sleepDisabled\":false}"
        var status = try JSONDecoder().decode(Status.self,from:Data(old.utf8))
        XCTAssertFalse(status.matchesCurrentBuild)
        status.build = TetherPaths.build - 1
        XCTAssertFalse(status.matchesCurrentBuild)
        status.build = TetherPaths.build
        let reread = try JSONDecoder().decode(Status.self,from:JSONEncoder().encode(status))
        XCTAssertTrue(reread.matchesCurrentBuild)
        status.version = "2.0.1"
        XCTAssertFalse(status.matchesCurrentBuild)
    }
    func testPreferenceStoreRetainsOriginalDomainsAndDoesNotReapplyOldEdits() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let defaults = MigrationTestDefaults()
        defaults.setPersistentDomain(["notifyHeat":false,"checkUpdates":false,"savedBuiltInBrightness":0.6],forName:old)
        defaults.setPersistentDomain(["menuBarDetails":false],forName:domain)
        let backups = folder.appendingPathComponent("prefs")
        try PreferenceMigration.apply(defaults:defaults,domain:domain,legacyDomain:old,backupDirectory:backups,hadExistingInstall:true)
        let result = try XCTUnwrap(defaults.persistentDomain(forName:domain))
        XCTAssertEqual(result["notifyHeat"] as? Bool,false)
        XCTAssertEqual(result["menuBarDetails"] as? Bool,false)
        XCTAssertEqual(result["SUEnableAutomaticChecks"] as? Bool,false)
        XCTAssertEqual(defaults.persistentDomain(forName:old)?["savedBuiltInBrightness"] as? Double,0.6)
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        let original = try Data(contentsOf:backup)
        var edited = result; edited["notifyHeat"] = true
        defaults.setPersistentDomain(edited,forName:domain)
        try PreferenceMigration.apply(defaults:defaults,domain:domain,legacyDomain:old,backupDirectory:backups,hadExistingInstall:true)
        XCTAssertEqual(defaults.persistentDomain(forName:domain)?["notifyHeat"] as? Bool,true)
        XCTAssertEqual(try Data(contentsOf:backup),original)
    }
    func testPreferenceBackupFailureLeavesBothDomainsUntouched() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let defaults = MigrationTestDefaults()
        defaults.setPersistentDomain(["notifyHeat":false],forName:old)
        let blocked = folder.appendingPathComponent("occupied")
        try Data("occupied".utf8).write(to:blocked)
        XCTAssertThrowsError(try PreferenceMigration.apply(defaults:defaults,domain:domain,legacyDomain:old,backupDirectory:blocked,hadExistingInstall:true))
        XCTAssertNil(defaults.persistentDomain(forName:domain))
        XCTAssertEqual(defaults.persistentDomain(forName:old)?["notifyHeat"] as? Bool,false)
    }
    func testUnrelatedOrMalformedPreferenceBackupCannotCompleteMigration() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let current: [String: Any] = ["menuBarDetails": false]
        let legacy: [String: Any] = ["notifyHeat": false]
        let defaults = MigrationTestDefaults()
        let backups = folder.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        let invalid: [[String: Any]] = [
            ["unrelated": true],
            ["current": current],
            ["current": "invalid", "legacy": legacy],
            ["current": current, "legacy": "invalid"],
            ["current": current, "legacy": legacy, "unrelated": true]
        ]
        let originals = try invalid.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
            + [Data("corrupt plist".utf8)]
        for original in originals {
            defaults.setPersistentDomain(current, forName: domain)
            defaults.setPersistentDomain(legacy, forName: old)
            try original.write(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            XCTAssertThrowsError(try PreferenceMigration.apply(defaults: defaults, domain: domain, legacyDomain: old,
                backupDirectory: backups, hadExistingInstall: true))
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: domain))).isEqual(to: current))
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: old))).isEqual(to: legacy))
            XCTAssertNil(defaults.persistentDomain(forName: domain)?["preferencesMigration2"])
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [backup.lastPathComponent])
        }
    }
    func testInterruptedPreferenceBackupDoesNotPublishFinalNameAndRetryPreservesOff() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let current: [String: Any] = ["menuBarDetails": false]
        let legacy: [String: Any] = ["checkUpdates": false, "notifyHeat": false]
        let defaults = MigrationTestDefaults()
        defaults.setPersistentDomain(current, forName: domain)
        defaults.setPersistentDomain(legacy, forName: old)
        let backups = folder.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["current": current, "legacy": legacy],
                                                         format: .binary, options: 0)
        XCTAssertThrowsError(try PreferenceMigration.publishBackup(original, to: backup.path) { file, data in
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
            try file.write(contentsOf: data.prefix(8))
            throw ServiceFailure("writeFailed")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: domain))).isEqual(to: current))
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: old))).isEqual(to: legacy))
        try PreferenceMigration.apply(defaults: defaults, domain: domain, legacyDomain: old,
            backupDirectory: backups, hadExistingInstall: true)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["preferencesMigration2"] as? Bool, true)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["menuBarDetails"] as? Bool, false)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [backup.lastPathComponent])
    }
    func testExclusivePreferenceBackupPublicationPreservesAnOriginalCreatedDuringWrite() throws {
        let backups = folder.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        let candidate = try PropertyListSerialization.data(fromPropertyList: ["current": ["checkUpdates": false], "legacy": [:]],
                                                          format: .binary, options: 0)
        let existing = try PropertyListSerialization.data(fromPropertyList: ["current": ["checkUpdates": true], "legacy": [:]],
                                                         format: .binary, options: 0)
        let published = try PreferenceMigration.publishBackup(candidate, to: backup.path) { file, data in
            try file.write(contentsOf: data)
            try existing.write(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        XCTAssertFalse(published)
        XCTAssertEqual(try Data(contentsOf: backup), existing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [backup.lastPathComponent])
        let defaults = MigrationTestDefaults()
        defaults.setPersistentDomain(["checkUpdates": false], forName: "current")
        XCTAssertThrowsError(try PreferenceMigration.apply(defaults: defaults, domain: "current", legacyDomain: "legacy",
            backupDirectory: backups, hadExistingInstall: true))
        XCTAssertEqual(defaults.persistentDomain(forName: "current")?["checkUpdates"] as? Bool, false)
        XCTAssertNil(defaults.persistentDomain(forName: "current")?["preferencesMigration2"])
        XCTAssertEqual(try Data(contentsOf: backup), existing)
    }
    func testExistingPartialPreferenceBackupRemainsBlockedAndUntouched() throws {
        let backups = folder.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        let partial = Data("bplist00".utf8)
        try partial.write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        let defaults = MigrationTestDefaults()
        defaults.setPersistentDomain(["checkUpdates": false], forName: "current")
        for _ in 1...2 {
            XCTAssertThrowsError(try PreferenceMigration.apply(defaults: defaults, domain: "current", legacyDomain: "legacy",
                backupDirectory: backups, hadExistingInstall: true))
            XCTAssertNil(defaults.persistentDomain(forName: "current")?["preferencesMigration2"])
            XCTAssertEqual(defaults.persistentDomain(forName: "current")?["checkUpdates"] as? Bool, false)
            XCTAssertEqual(try Data(contentsOf: backup), partial)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [backup.lastPathComponent])
    }
    func testEmptyPreferenceDomainsNeedNoRecoveryDirectoryOrBackup() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let backups = folder.appendingPathComponent("prefs")
        for hadExistingInstall in [false, true] {
            let defaults = MigrationTestDefaults()
            try PreferenceMigration.apply(defaults: defaults, domain: domain, legacyDomain: old,
                backupDirectory: backups, hadExistingInstall: hadExistingInstall)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["preferencesMigration2"] as? Bool, true)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["migratedFromLocalTether"] as? Bool, true)
            XCTAssertNil(defaults.persistentDomain(forName: old))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        }
    }
    func testDifferentPreferenceOriginalIsPreservedWithoutAddingAnotherBackup() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let current: [String: Any] = ["checkUpdates": false]
        let legacy: [String: Any] = ["language": "ko"]
        let defaults = MigrationTestDefaults()
        defaults.setPersistentDomain(current, forName: domain)
        defaults.setPersistentDomain(legacy, forName: old)
        let backups = folder.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        let previous: [[String: Any]] = [
            ["current": ["checkUpdates": true], "legacy": legacy],
            ["current": ["checkUpdates": 0], "legacy": legacy],
            ["current": current, "legacy": ["language": "en"]]
        ]
        for value in previous {
            let original = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            try original.write(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            XCTAssertThrowsError(try PreferenceMigration.apply(defaults: defaults, domain: domain, legacyDomain: old,
                backupDirectory: backups, hadExistingInstall: true))
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: domain))).isEqual(to: current))
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: old))).isEqual(to: legacy))
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [backup.lastPathComponent])
        }
    }
    func testMatchingPreferenceOriginalIsReusedAcrossPlistEncodings() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let current: [String: Any] = ["menuBarDetails": false, "language": "ko", "nested": ["choices": ["one", "two"]]]
        let legacy: [String: Any] = ["notifyHeat": false, "checkUpdates": false]
        let defaults = MigrationTestDefaults()
        let backups = folder.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            defaults.setPersistentDomain(current, forName: domain)
            defaults.setPersistentDomain(legacy, forName: old)
            let original = try PropertyListSerialization.data(fromPropertyList: ["legacy": legacy, "current": current], format: format, options: 0)
            try original.write(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            try PreferenceMigration.apply(defaults: defaults, domain: domain, legacyDomain: old,
                backupDirectory: backups, hadExistingInstall: true)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["preferencesMigration2"] as? Bool, true)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["menuBarDetails"] as? Bool, false)
            XCTAssertEqual(defaults.persistentDomain(forName: domain)?["notifyHeat"] as? Bool, false)
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: old))).isEqual(to: legacy))
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [backup.lastPathComponent])
        }
    }
    func testPreferenceBackupSymlinksArePreservedAndCannotCompleteMigration() throws {
        let domain = "tether.test.\(UUID())", old = domain + ".legacy"
        let current: [String: Any] = ["menuBarDetails": false]
        let legacy: [String: Any] = ["notifyHeat": false]
        let defaults = MigrationTestDefaults()
        defaults.setPersistentDomain(current, forName: domain)
        defaults.setPersistentDomain(legacy, forName: old)
        let backups = folder.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        let backup = backups.appendingPathComponent("preferences-before-2.2.plist")
        let target = folder.appendingPathComponent("target.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["current": current, "legacy": legacy], format: .binary, options: 0)
        for exists in [true, false] {
            if exists { try original.write(to: target) }
            try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: target)
            XCTAssertThrowsError(try PreferenceMigration.apply(defaults: defaults, domain: domain, legacyDomain: old,
                backupDirectory: backups, hadExistingInstall: true))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: backup.path), target.path)
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: domain))).isEqual(to: current))
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: old))).isEqual(to: legacy))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [backup.lastPathComponent])
            if exists { XCTAssertEqual(try Data(contentsOf: target), original); try FileManager.default.removeItem(at: target) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
            try FileManager.default.removeItem(at: backup)
        }
    }
    func testAppAndHelperReleaseIdentityCannotDrift() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from:Data(contentsOf:root.appendingPathComponent("Resources/Info.plist")),format:nil) as? [String:Any])
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String,TetherPaths.version)
        XCTAssertEqual(plist["CFBundleVersion"] as? String,String(TetherPaths.build))
        let publicKey = try String(contentsOf:root.appendingPathComponent("Resources/update-public-key.txt"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        XCTAssertEqual(plist["SUPublicEDKey"] as? String,publicKey)
        XCTAssertEqual(Data(base64Encoded:publicKey)?.count,32)
    }
}
