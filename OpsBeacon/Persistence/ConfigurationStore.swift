import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var collectionWindow: TimeInterval
    public var pushPort: Int
    public var launchAtLogin: Bool

    public init(collectionWindow: TimeInterval = 60, pushPort: Int = 9780, launchAtLogin: Bool = false) {
        self.collectionWindow = collectionWindow
        self.pushPort = pushPort
        self.launchAtLogin = launchAtLogin
    }
}

public struct LogFileSourceConfiguration: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var directoryBookmark: Data?
    public var relativePath: String
    public var lastResolvedPath: String?
    public var cursor: LogCursor

    public init(sourceID: UUID, directoryBookmark: Data? = nil, relativePath: String, lastResolvedPath: String? = nil, cursor: LogCursor = .init()) {
        self.sourceID = sourceID
        self.directoryBookmark = directoryBookmark
        self.relativePath = relativePath
        self.lastResolvedPath = lastResolvedPath
        self.cursor = cursor
    }
}

public struct LocalPushSourceConfiguration: Codable, Equatable, Sendable {
    public var sourceID: UUID
    /// The Keychain account, not the secret itself.
    public var keychainReference: String

    public init(sourceID: UUID, keychainReference: String) {
        self.sourceID = sourceID
        self.keychainReference = keychainReference
    }
}

public enum SourceIssueKind: String, Codable, CaseIterable, Sendable {
    case rotationGap
    case oversizedLine
    case authorizationRevoked
    case listenerFailure
}

public struct SourceIssue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var kind: SourceIssueKind
    public var redactedDetail: String
    public var occurredAt: Date
    public var resolved: Bool

    public init(id: UUID = UUID(), sourceID: UUID, kind: SourceIssueKind, redactedDetail: String, occurredAt: Date = Date(), resolved: Bool = false) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.redactedDetail = redactedDetail
        self.occurredAt = occurredAt
        self.resolved = resolved
    }
}

public struct DisplayGeometry: Codable, Equatable, Sendable {
    public var displayUUID: String
    public var lastVisibleFrame: CGRect
    public var frame: CGRect

    public init(displayUUID: String, lastVisibleFrame: CGRect, frame: CGRect) {
        self.displayUUID = displayUUID
        self.lastVisibleFrame = lastVisibleFrame
        self.frame = frame
    }
}

public struct StoredConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var alertConfiguration: AlertConfiguration
    public var settings: AppSettings
    public var logSources: [UUID: LogFileSourceConfiguration]
    public var pushSources: [UUID: LocalPushSourceConfiguration]
    public var sourceIssues: [SourceIssue]
    public var displayGeometries: [String: DisplayGeometry]

    public init(
        schemaVersion: Int = 1,
        alertConfiguration: AlertConfiguration = .init(sources: [], rules: []),
        settings: AppSettings = .init(),
        logSources: [UUID: LogFileSourceConfiguration] = [:],
        pushSources: [UUID: LocalPushSourceConfiguration] = [:],
        sourceIssues: [SourceIssue] = [],
        displayGeometries: [String: DisplayGeometry] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.alertConfiguration = alertConfiguration
        self.settings = settings
        self.logSources = logSources
        self.pushSources = pushSources
        self.sourceIssues = sourceIssues
        self.displayGeometries = displayGeometries
    }
}

public protocol ConfigurationStore: Sendable {
    func load() async throws -> StoredConfiguration
    func save(_ configuration: StoredConfiguration) async throws
}

public actor InMemoryConfigurationStore: ConfigurationStore {
    private var configuration: StoredConfiguration
    public init(configuration: StoredConfiguration = .init()) { self.configuration = configuration }
    public func load() async throws -> StoredConfiguration { configuration }
    public func save(_ configuration: StoredConfiguration) async throws { self.configuration = configuration }
}

public actor FileConfigurationStore: ConfigurationStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        url = fileURL
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> StoredConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try decoder.decode(StoredConfiguration.self, from: Data(contentsOf: url))
    }

    public func save(_ configuration: StoredConfiguration) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(configuration).write(to: url, options: [.atomic])
    }
}
