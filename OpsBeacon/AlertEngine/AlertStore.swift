import Foundation

public protocol AlertStore: Sendable {
    func load() async throws -> AlertEngineState?
    func save(_ state: AlertEngineState) async throws
}

public actor InMemoryAlertStore: AlertStore {
    private var state: AlertEngineState?

    public init(initialState: AlertEngineState? = nil) { state = initialState }
    public func load() async throws -> AlertEngineState? { state }
    public func save(_ state: AlertEngineState) async throws { self.state = state }
}

public actor FileAlertStore: AlertStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> AlertEngineState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(AlertEngineState.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ state: AlertEngineState) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: fileURL, options: [.atomic])
    }
}
