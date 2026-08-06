import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var headerByteCount: Int {
        headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var responseHeaders = ["Content-Type": "application/json", "Content-Length": "\(data.count)"]
        headers.forEach { responseHeaders[$0.key] = $0.value }
        return HTTPResponse(status: status, headers: responseHeaders, body: data)
    }

    public func jsonBody() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    }
}
