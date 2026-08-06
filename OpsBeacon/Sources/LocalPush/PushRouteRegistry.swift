import Foundation

public struct PushRoute: Sendable, Equatable {
    public var sourceID: UUID
    public var enabled: Bool
    public var credential: String

    public init(sourceID: UUID, enabled: Bool, credential: String) {
        self.sourceID = sourceID
        self.enabled = enabled
        self.credential = credential
    }
}

public actor PushRouteRegistry {
    public static let maximumHeaderBytes = 16 * 1024
    public static let maximumConcurrentConnections = 32

    private let engine: AlertEngine
    private var routes: [UUID: PushRoute] = [:]
    private var port = 0
    private var ready = false

    public init(engine: AlertEngine) { self.engine = engine }

    public func configure(routes: [PushRoute], port: Int, ready: Bool) {
        self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.sourceID, $0) })
        self.port = port
        self.ready = ready
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard ready else { return .json(503, ["error": "service unavailable"], headers: ["Retry-After": "1"]) }
        guard request.headerByteCount <= Self.maximumHeaderBytes else {
            return .json(431, ["error": "headers too large"])
        }
        guard request.body.count <= PushSignalDecoder.maximumBodyBytes else {
            return .json(413, ["error": "body too large"])
        }
        guard isAllowedHost(request.header(named: "Host")) else {
            return .json(400, ["error": "invalid host"])
        }
        guard let sourceID = routeID(from: request.target) else {
            return .json(404, ["error": "not found"])
        }
        guard request.method.uppercased() == "POST" else {
            return .json(405, ["error": "method not allowed"], headers: ["Allow": "POST"])
        }
        guard request.header(named: "Content-Type")?.lowercased() == "application/json" else {
            return .json(415, ["error": "unsupported media type"])
        }
        guard let route = routes[sourceID], route.enabled else {
            return .json(404, ["error": "not found"])
        }
        guard let authorization = request.header(named: "Authorization"), authorization.hasPrefix("Bearer "),
              constantTimeEquals(String(authorization.dropFirst("Bearer ".count)), route.credential) else {
            return .json(401, ["error": "unauthorized"])
        }
        let signal: PushSignal
        do { signal = try PushSignalDecoder.decode(request.body, receiptTime: Date()) }
        catch PushSignalDecodingError.bodyTooLarge { return .json(413, ["error": "body too large"]) }
        catch { return .json(400, ["error": "invalid envelope"]) }

        do {
            switch try await engine.ingest(.push(signal), from: sourceID) {
            case .acceptedMatched: return .json(202, ["status": "accepted", "matched": true])
            case .acceptedUnmatched: return .json(202, ["status": "accepted", "matched": false])
            case .discardedDuringPause: return .json(202, ["status": "paused", "discarded": true])
            }
        } catch {
            return .json(503, ["error": "service unavailable"], headers: ["Retry-After": "1"])
        }
    }

    private func routeID(from target: String) -> UUID? {
        guard !target.contains("?") else { return nil }
        let parts = target.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "v1", parts[2] == "sources", parts[4] == "signals" else { return nil }
        return UUID(uuidString: String(parts[3]))
    }

    private func isAllowedHost(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "127.0.0.1:\(port)" || value == "localhost:\(port)" || value == "[::1]:\(port)"
    }

    private func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        let length = max(leftBytes.count, rightBytes.count)
        var difference = leftBytes.count ^ rightBytes.count
        for index in 0..<length {
            let lhs = index < leftBytes.count ? leftBytes[index] : 0
            let rhs = index < rightBytes.count ? rightBytes[index] : 0
            difference |= Int(lhs ^ rhs)
        }
        return difference == 0
    }
}

/// Admission is separate from request routing so the listener can stop excess
/// clients before it starts reading their request bytes.
public final class PushConnectionAdmission: @unchecked Sendable {
    private let limit: Int
    private var activeConnections = 0
    private let lock = NSLock()

    public init(limit: Int = PushRouteRegistry.maximumConcurrentConnections) {
        precondition(limit > 0)
        self.limit = limit
    }

    public func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < limit else { return false }
        activeConnections += 1
        return true
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        precondition(activeConnections > 0, "A Push connection was released without admission.")
        activeConnections -= 1
    }

    public func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeConnections
    }
}
