import XCTest
@testable import TetherCore

enum V4Fixture {
    static let scope = V4Scope(bootID: "boot", ownerID: "owner", powerGeneration: 1)
    static func context(_ power: V4Power = .ac, until: Double = 100000) -> V4ExecutionContext {
        .init(scope: scope, power: power, validUntil: until, lidClosed: false, allowDisplay: true, allowClosedLid: true)
    }
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
    static func settings(_ groups: [[V4Condition]], options: V4RequestOptions = .init()) -> V4Settings {
        let preset = V4Preset(id: UUID(), name: "Work", groups: groups.map { .init(id: UUID(), conditions: $0) }, options: options)
        var s = V4Settings(); s.automaticMode = .advanced; s.activePresetID = preset.id; s.presets = [preset]; return s
    }
    static func evaluate(_ s: V4Settings, _ context: V4ExecutionContext = context(), _ observations: [V4Observation] = [], now: Double = 100) -> V4RuleEvaluation {
        V4RuleEngine.evaluate(settings: s, context: context, observations: observations,
            capabilities: V4ConditionKind.allCases.map { .init(kind: $0, status: .supported) },
            now: now, wallDate: Date(timeIntervalSince1970: 0), calendar: calendar)
    }
    static func observation(_ condition: V4Condition, _ state: V4ObservationState = .satisfied, until: Double = 500) -> V4Observation {
        .init(conditionID: condition.id, scope: scope, state: state, observedAt: 90, validUntil: until)
    }
    static func manual(deadline: Double = 1000) -> V4ManualSnapshot {
        .init(requestID: UUID(), revisionID: UUID(), ownerID: "owner", startedAt: 0, deadline: deadline, canExtend15: true)
    }
}

final class V4RuleEngineTests: XCTestCase {
    func testAutomaticPowerGateCannotBeBypassedByOR() {
        let c = V4Condition(id: UUID(), kind: .appRunning, target: "app")
        let s = V4Fixture.settings([[c]])
        XCTAssertTrue(V4Fixture.evaluate(s, V4Fixture.context(), [V4Fixture.observation(c)]).gate.isSatisfied)
        for power in [V4Power.battery, .ups, .unknown] {
            XCTAssertFalse(V4Fixture.evaluate(s, V4Fixture.context(power), [V4Fixture.observation(c)]).gate.isSatisfied)
        }
    }
    func testUnknownANDDoesNotDisableAnotherSatisfiedORGroup() {
        let a = V4Condition(id: UUID(), kind: .appRunning, target: "a")
        let b = V4Condition(id: UUID(), kind: .volume, target: "b")
        let c = V4Condition(id: UUID(), kind: .usb, target: "c")
        let s = V4Fixture.settings([[a,b],[c]])
        let result = V4Fixture.evaluate(s, V4Fixture.context(), [V4Fixture.observation(a), V4Fixture.observation(b, .unknown), V4Fixture.observation(c, until: 300)])
        XCTAssertTrue(result.gate.isSatisfied); XCTAssertEqual(result.gate.validUntil, 300)
    }
    func testANDMinimumAndORMaximumExpiry() {
        let a = V4Condition(id: UUID(), kind: .appRunning, target: "a")
        let b = V4Condition(id: UUID(), kind: .volume, target: "b")
        let c = V4Condition(id: UUID(), kind: .usb, target: "c")
        let s = V4Fixture.settings([[a,b],[c]])
        let result = V4Fixture.evaluate(s, V4Fixture.context(until: 450), [V4Fixture.observation(a, until: 200), V4Fixture.observation(b, until: 400), V4Fixture.observation(c, until: 500)])
        XCTAssertEqual(result.gate.validUntil, 450)
    }
    func testStaleFutureAndWrongScopeObservationCannotGrant() {
        let c = V4Condition(id: UUID(), kind: .appRunning, target: "app")
        let s = V4Fixture.settings([[c]])
        var future = V4Fixture.observation(c); future.observedAt = 101
        var wrongScope = V4Fixture.observation(c); wrongScope.scope.powerGeneration += 1
        for observation in [future, wrongScope, V4Fixture.observation(c, until: 100)] {
            XCTAssertFalse(V4Fixture.evaluate(s, V4Fixture.context(), [observation]).gate.isSatisfied)
        }
    }
    func testMissingOrEmptyAdvancedPresetNeverFallsBackToAC() {
        var s = V4Fixture.settings([])
        XCTAssertFalse(V4Fixture.evaluate(s).gate.isSatisfied)
        s.activePresetID = UUID(); XCTAssertFalse(V4Fixture.evaluate(s).gate.isSatisfied)
    }
    func testAdapterActivityGraceIsNotOverriddenByRawThreshold() {
        let c = V4Condition(id: UUID(), kind: .cpuLoad, threshold: 80)
        var o = V4Fixture.observation(c); o.numericValue = 20
        XCTAssertTrue(V4Fixture.evaluate(V4Fixture.settings([[c]]), V4Fixture.context(), [o]).gate.isSatisfied)
        o.numericValue = .nan
        XCTAssertFalse(V4Fixture.evaluate(V4Fixture.settings([[c]]), V4Fixture.context(), [o]).gate.isSatisfied)
    }
    func testOnlySelectedAdvancedConditionsRequireProviders() {
        let c = V4Condition(id: UUID(), kind: .appRunning, target: "app")
        var s = V4Fixture.settings([[c]])
        XCTAssertEqual(V4RuleEngine.requiredConditions(settings: s, automaticEnabled: true).map(\.id), [c.id])
        XCTAssertTrue(V4RuleEngine.requiredConditions(settings: s, automaticEnabled: false).isEmpty)
        s.automaticMode = .acConnected
        XCTAssertTrue(V4RuleEngine.requiredConditions(settings: s, automaticEnabled: true).isEmpty)
    }
    func testOvernightWindowBelongsToItsStartWeekday() {
        let window = V4TimeWindow(startMinute: 22 * 60, endMinute: 2 * 60, weekdays: [2])
        let monday = Date(timeIntervalSince1970: 4 * 86400 + 23 * 3600)
        XCTAssertTrue(window.evaluate(at: monday, calendar: V4Fixture.calendar).satisfied)
        XCTAssertTrue(window.evaluate(at: monday.addingTimeInterval(2 * 3600), calendar: V4Fixture.calendar).satisfied)
        XCTAssertFalse(window.evaluate(at: monday.addingTimeInterval(3 * 3600), calendar: V4Fixture.calendar).satisfied)
    }
    func testActivityWindowRejectsStaleAndHonorsReleaseGrace() {
        let low = [V4ActivitySample(at: 99, value: 10)]
        XCTAssertEqual(V4ActivityWindow.evaluate(samples: low, now: 100, threshold: 50, lastSatisfiedAt: 80), .satisfied)
        XCTAssertEqual(V4ActivityWindow.evaluate(samples: [.init(at: 110, value: 10)], now: 111, threshold: 50, lastSatisfiedAt: 80), .notSatisfied)
        XCTAssertEqual(V4ActivityWindow.evaluate(samples: low, now: 200, threshold: 50, lastSatisfiedAt: 190), .unknown)
    }
}
