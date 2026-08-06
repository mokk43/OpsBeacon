import XCTest
@testable import OpsBeacon

final class AlertEngineTests: XCTestCase {
    func testRecoveryClampsImplausibleFutureDeadlineAndLatchesDiagnostic() async throws {
        let clock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 500))
        let source = AlertSource(name: "App", kind: .logFile)
        let rule = Rule(sourceID: source.id, name: "Any", order: 0, matcher: .log(.contains("alert", caseSensitive: false)))
        let windowID = UUID()
        let alert = Alert(
            id: UUID(), sequence: 1, state: .pending,
            occurrenceTime: await clock.now(), receiptTime: await clock.now(),
            sourceID: source.id, sourceName: source.name, ruleID: rule.id, ruleName: rule.name,
            severity: .warning, message: "alert", attributes: nil, collectionWindowID: windowID
        )
        let state = AlertEngineState(
            activeWindow: .collecting(.init(id: windowID, startedAt: await clock.now(), deadline: .init(timeIntervalSince1970: 100_000))),
            pendingAlerts: [alert],
            nextSequence: 1
        )
        let engine = AlertEngine(store: InMemoryAlertStore(initialState: state), clock: clock)
        try await engine.applyConfiguration(.init(sources: [source], rules: [rule], collectionWindow: 60))
        _ = try await engine.start()

        let stream = await engine.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let recovered = await snapshots.next()
        XCTAssertEqual(recovered?.pendingAlerts.count, 1)
        XCTAssertEqual(recovered?.recoveryDiagnostics.count, 1)

        await clock.advance(by: 60)
        let displayed = await snapshots.next()
        XCTAssertEqual(displayed?.displayedAlerts.map(\.message), ["alert"])
    }

    func testFirstMatchingRuleCreatesOnePendingAlertThenDisplaysAndAcknowledges() async throws {
        let clock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 1_000))
        let store = InMemoryAlertStore()
        let engine = AlertEngine(store: store, clock: clock)
        let source = AlertSource(name: "Application log", kind: .logFile)
        let nonMatching = Rule(
            sourceID: source.id,
            name: "Never",
            order: 0,
            matcher: .log(.contains("unreachable", caseSensitive: false))
        )
        let matching = Rule(
            sourceID: source.id,
            name: "Errors",
            order: 1,
            severity: .critical,
            matcher: .log(.contains("error", caseSensitive: false))
        )

        _ = try await engine.start()
        try await engine.applyConfiguration(.init(sources: [source], rules: [nonMatching, matching], collectionWindow: 60))

        let result = try await engine.ingest(.log(.init(message: "database ERROR", occurredAt: await clock.now())), from: source.id)
        XCTAssertEqual(result, .acceptedMatched)
        let stream = await engine.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let pending = await snapshots.next()
        XCTAssertEqual(pending?.pendingAlerts.count, 1)

        await clock.advance(by: 60)
        let displayed = await snapshots.next()
        XCTAssertEqual(displayed?.displayedAlerts.map(\.ruleName), ["Errors"])
        XCTAssertEqual(displayed?.highestSeverity, .critical)

        try await engine.acknowledgeDisplayed()
        let acknowledged = await snapshots.next()
        XCTAssertTrue(acknowledged?.displayedAlerts.isEmpty == true)
    }

    func testPauseFreezesCollectionWindowAndDiscardsIncomingSignals() async throws {
        let clock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 2_000))
        let engine = AlertEngine(store: InMemoryAlertStore(), clock: clock)
        let source = AlertSource(name: "App", kind: .logFile)
        let rule = Rule(sourceID: source.id, name: "Any", order: 0, matcher: .log(.contains("alert", caseSensitive: false)))
        _ = try await engine.start()
        try await engine.applyConfiguration(.init(sources: [source], rules: [rule], collectionWindow: 60))
        let firstResult = try await engine.ingest(.log(.init(message: "alert one", occurredAt: await clock.now())), from: source.id)
        XCTAssertEqual(firstResult, .acceptedMatched)

        try await engine.setMonitoringPaused(true)
        await clock.advance(by: 120)
        let pausedResult = try await engine.ingest(.log(.init(message: "alert missed", occurredAt: await clock.now())), from: source.id)
        XCTAssertEqual(pausedResult, .discardedDuringPause)
        try await engine.setMonitoringPaused(false)

        await clock.advance(by: 59)
        let beforeDeadline = await engine.snapshots()
        var beforeDeadlineSnapshots = beforeDeadline.makeAsyncIterator()
        let beforeDeadlineSnapshot = await beforeDeadlineSnapshots.next()
        XCTAssertTrue(beforeDeadlineSnapshot?.displayedAlerts.isEmpty == true)

        await clock.advance(by: 1)
        let delivered = await beforeDeadlineSnapshots.next()
        XCTAssertEqual(delivered?.displayedAlerts.map(\.message), ["alert one"])
    }

    func testPushRuleUsesTypedJsonConditionsAndFirstMatch() async throws {
        let clock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 3_000))
        let engine = AlertEngine(store: InMemoryAlertStore(), clock: clock)
        let source = AlertSource(name: "Backups", kind: .localPush)
        let broad = Rule(sourceID: source.id, name: "Any backup", order: 0, severity: .warning, matcher: .push(name: "backup.failed", conditions: []))
        let specific = Rule(
            sourceID: source.id,
            name: "Exit code one",
            order: 1,
            severity: .critical,
            matcher: .push(name: "backup.failed", conditions: [.init(path: .init("/exitCode"), operation: .equals, operand: .number("1"))])
        )
        _ = try await engine.start()
        try await engine.applyConfiguration(.init(sources: [source], rules: [broad, specific]))

        let result = try await engine.ingest(.push(.init(name: "backup.failed", message: "nightly", occurredAt: await clock.now(), attributes: ["exitCode": .number("1")])), from: source.id)
        XCTAssertEqual(result, .acceptedMatched)
        let stream = await engine.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let pending = await snapshots.next()
        XCTAssertEqual(pending?.pendingAlerts.first?.ruleName, "Any backup")
    }

    func testPendingOverflowTransfersToDisplayedAndSurvivesRecovery() async throws {
        let firstClock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 4_000))
        let store = InMemoryAlertStore()
        let source = AlertSource(name: "App", kind: .logFile)
        let rule = Rule(sourceID: source.id, name: "Any", order: 0, matcher: .log(.contains("alert", caseSensitive: false)))
        let firstEngine = AlertEngine(store: store, clock: firstClock)
        _ = try await firstEngine.start()
        try await firstEngine.applyConfiguration(.init(sources: [source], rules: [rule], collectionWindow: 60))
        for index in 0..<205 {
            let result = try await firstEngine.ingest(.log(.init(message: "alert \(index)", occurredAt: await firstClock.now())), from: source.id)
            XCTAssertEqual(result, .acceptedMatched)
        }

        let recoveredClock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 4_020))
        let recovered = AlertEngine(store: store, clock: recoveredClock)
        _ = try await recovered.start()
        try await recovered.applyConfiguration(.init(sources: [source], rules: [rule], collectionWindow: 60))
        let stream = await recovered.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let recoveredSnapshot = await snapshots.next()
        XCTAssertEqual(recoveredSnapshot?.pendingAlerts.count, 200)
        XCTAssertEqual(recoveredSnapshot?.pendingOmittedCount, 5)

        await recoveredClock.advance(by: 40)
        let displayed = await snapshots.next()
        XCTAssertEqual(displayed?.displayedAlerts.count, 200)
        XCTAssertEqual(displayed?.omittedCount, 5)
        XCTAssertEqual(displayed?.pendingOmittedCount, 0)
    }
}
