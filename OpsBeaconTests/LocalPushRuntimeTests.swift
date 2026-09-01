import Darwin
import Foundation
import XCTest
@testable import OpsBeacon

final class LocalPushRuntimeTests: XCTestCase {
    func testSamePortCredentialChangeUpdatesRouteAndKeepsListenerReachable() async throws {
        let fixture = try await makeFixture()
        let port = try availableLoopbackPort()
        let runtime = LocalPushRuntime(engine: fixture.engine)
        try await runtime.apply(.init(
            port: port,
            routes: [.init(sourceID: fixture.source.id, enabled: true, credential: "old-secret")]
        ))
        try await runtime.apply(.init(
            port: port,
            routes: [.init(sourceID: fixture.source.id, enabled: true, credential: "new-secret")]
        ))

        let oldCredential = try await sendPush(
            port: port,
            sourceID: fixture.source.id,
            credential: "old-secret",
            name: "deployment.failed"
        )
        let newCredential = try await sendPush(
            port: port,
            sourceID: fixture.source.id,
            credential: "new-secret",
            name: "deployment.failed"
        )
        await runtime.stop()

        XCTAssertEqual(oldCredential.statusCode, 401)
        XCTAssertEqual(newCredential.statusCode, 202)
        XCTAssertEqual(newCredential.body["matched"] as? Bool, true)
    }

    func testFailedPortChangeRestoresPreviousListenerAndRoutes() async throws {
        let fixture = try await makeFixture()
        let occupiedPort = try LoopbackPortReservation()
        let workingPort = try availableLoopbackPort()
        let runtime = LocalPushRuntime(engine: fixture.engine)
        let working = LocalPushRuntimeConfiguration(
            port: workingPort,
            routes: [.init(sourceID: fixture.source.id, enabled: true, credential: "secret")]
        )
        try await runtime.apply(working)

        do {
            try await runtime.apply(.init(port: occupiedPort.port, routes: working.routes))
            XCTFail("Expected the occupied port change to fail.")
        } catch { }

        let active = await runtime.activeConfiguration()
        let response = try await sendPush(
            port: workingPort,
            sourceID: fixture.source.id,
            credential: "secret",
            name: "deployment.failed"
        )
        await runtime.stop()

        XCTAssertEqual(active, working)
        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.body["matched"] as? Bool, true)
    }

    private func makeFixture() async throws -> (engine: AlertEngine, source: AlertSource) {
        let engine = AlertEngine(store: InMemoryAlertStore())
        let source = AlertSource(name: "Deployments", kind: .localPush)
        let rule = Rule(sourceID: source.id, name: "Failures", order: 0, matcher: .push(name: nil, conditions: []))
        _ = try await engine.start()
        try await engine.applyConfiguration(.init(sources: [source], rules: [rule]))
        return (engine, source)
    }
}

struct PushTestResponse {
    var statusCode: Int
    var body: [String: Any]
}

func sendPush(port: Int, sourceID: UUID, credential: String, name: String) async throws -> PushTestResponse {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/sources/\(sourceID.uuidString)/signals")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return .init(statusCode: http.statusCode, body: body)
}

func availableLoopbackPort() throws -> Int {
    let reservation = try LoopbackPortReservation()
    return reservation.port
}

final class LoopbackPortReservation {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}
