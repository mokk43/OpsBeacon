import XCTest
@testable import OpsBeacon

final class PushRouteRegistryTests: XCTestCase {
    func testConnectionAdmissionLimitsOpenConnectionsBeforeRequestHandling() {
        let admission = PushConnectionAdmission(limit: 2)

        XCTAssertTrue(admission.acquire())
        XCTAssertTrue(admission.acquire())
        XCTAssertFalse(admission.acquire())
        XCTAssertEqual(admission.activeCount(), 2)

        admission.release()
        XCTAssertTrue(admission.acquire())
        XCTAssertEqual(admission.activeCount(), 2)
    }

    func testRegistryAuthenticatesDecodesAndWaitsForMatchedIngestion() async throws {
        let clock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 10_000))
        let engine = AlertEngine(store: InMemoryAlertStore(), clock: clock)
        let source = AlertSource(name: "Backups", kind: .localPush)
        let rule = Rule(sourceID: source.id, name: "Failures", order: 0, matcher: .push(name: "backup.failed", conditions: []))
        _ = try await engine.start()
        try await engine.applyConfiguration(.init(sources: [source], rules: [rule]))
        let registry = PushRouteRegistry(engine: engine)
        await registry.configure(routes: [.init(sourceID: source.id, enabled: true, credential: "secret")], port: 9780, ready: true)

        let request = HTTPRequest(
            method: "POST",
            target: "/v1/sources/\(source.id.uuidString)/signals",
            headers: ["Host": "127.0.0.1:9780", "Content-Type": "application/json", "Authorization": "Bearer secret"],
            body: Data("{\"name\":\"backup.failed\",\"message\":\"nightly failed\",\"attributes\":{\"exitCode\":1}}".utf8)
        )

        let response = await registry.handle(request)
        XCTAssertEqual(response.status, 202)
        XCTAssertEqual(try response.jsonBody()["matched"] as? Bool, true)
        let stream = await engine.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let snapshot = await snapshots.next()
        XCTAssertEqual(snapshot?.pendingAlerts.first?.message, "nightly failed")
    }

    func testRegistryRejectsLeakyOrInvalidRequestsWithoutIngestion() async throws {
        let engine = AlertEngine(store: InMemoryAlertStore())
        let source = AlertSource(name: "Backups", kind: .localPush)
        _ = try await engine.start()
        try await engine.applyConfiguration(.init(sources: [source], rules: []))
        let registry = PushRouteRegistry(engine: engine)
        await registry.configure(routes: [.init(sourceID: source.id, enabled: true, credential: "secret")], port: 9780, ready: true)
        let request = HTTPRequest(
            method: "POST",
            target: "/v1/sources/\(source.id.uuidString)/signals",
            headers: ["Host": "example.com:9780", "Content-Type": "application/json", "Authorization": "Bearer wrong"],
            body: Data("{\"name\":\"backup.failed\",\"message\":\"confidential\"}".utf8)
        )

        let response = await registry.handle(request)
        XCTAssertEqual(response.status, 400)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("confidential"))
        XCTAssertFalse(response.headers.keys.contains { $0.lowercased() == "access-control-allow-origin" })
    }
}
