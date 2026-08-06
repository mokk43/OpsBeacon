import Foundation

public enum SourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case logFile
    case localPush
}

public struct AlertSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: SourceKind
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, kind: SourceKind, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
    }
}

public enum Severity: Int, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case info
    case warning
    case critical

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogSignal: Codable, Equatable, Sendable {
    public var message: String
    public var occurredAt: Date

    public init(message: String, occurredAt: Date) {
        self.message = message
        self.occurredAt = occurredAt
    }
}

public struct PushSignal: Codable, Equatable, Sendable {
    public var name: String
    public var message: String?
    public var occurredAt: Date
    public var attributes: [String: JSONValue]

    public init(name: String, message: String? = nil, occurredAt: Date, attributes: [String: JSONValue] = [:]) {
        self.name = name
        self.message = message
        self.occurredAt = occurredAt
        self.attributes = attributes
    }
}

public enum Signal: Codable, Equatable, Sendable {
    case log(LogSignal)
    case push(PushSignal)

    public var occurredAt: Date {
        switch self {
        case .log(let signal): signal.occurredAt
        case .push(let signal): signal.occurredAt
        }
    }

    public var message: String {
        switch self {
        case .log(let signal): signal.message
        case .push(let signal): signal.message ?? signal.name
        }
    }
}

public indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case boolean(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Decimal.self) {
            self = .number(NSDecimalNumber(decimal: value).stringValue)
        } else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value):
            guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
                throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Invalid JSON number"))
            }
            try container.encode(decimal)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum LogRuleMatcher: Codable, Equatable, Sendable {
    case contains(String, caseSensitive: Bool)
    case regularExpression(String, caseSensitive: Bool)
}

public struct JSONPointer: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isEmpty || rawValue.first == "/" else { return nil }
        self.rawValue = rawValue
    }

    public init(_ rawValue: String = "") {
        precondition(rawValue.isEmpty || rawValue.first == "/", "JSON Pointer must start with '/'")
        self.rawValue = rawValue
    }

    public func value(in root: JSONValue) -> JSONValue? {
        guard !rawValue.isEmpty else { return root }
        return rawValue.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
            .reduce(Optional(root)) { current, token in
                guard let current else { return nil }
                switch current {
                case .object(let object): return object[token]
                case .array(let values):
                    guard let index = Int(token), String(index) == token, values.indices.contains(index) else { return nil }
                    return values[index]
                default: return nil
                }
            }
    }
}

public enum PushConditionOperator: String, Codable, CaseIterable, Sendable {
    case exists
    case equals
    case notEquals
    case contains
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
}

public struct PushCondition: Codable, Equatable, Sendable {
    public var path: JSONPointer
    public var operation: PushConditionOperator
    public var operand: JSONValue?

    public init(path: JSONPointer, operation: PushConditionOperator, operand: JSONValue? = nil) {
        self.path = path
        self.operation = operation
        self.operand = operand
    }
}

public enum RuleMatcher: Codable, Equatable, Sendable {
    case log(LogRuleMatcher)
    case push(name: String?, conditions: [PushCondition])
}

public struct Rule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var name: String
    public var enabled: Bool
    public var order: Int
    public var severity: Severity
    public var matcher: RuleMatcher

    public init(id: UUID = UUID(), sourceID: UUID, name: String, enabled: Bool = true, order: Int, severity: Severity = .warning, matcher: RuleMatcher) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.enabled = enabled
        self.order = order
        self.severity = severity
        self.matcher = matcher
    }
}

public struct AlertConfiguration: Codable, Equatable, Sendable {
    public var revision: Int64
    public var sources: [AlertSource]
    public var rules: [Rule]
    public var collectionWindow: TimeInterval

    public init(revision: Int64 = 0, sources: [AlertSource], rules: [Rule], collectionWindow: TimeInterval = 60) {
        self.revision = revision
        self.sources = sources
        self.rules = rules
        self.collectionWindow = collectionWindow
    }
}

public enum AlertState: String, Codable, Sendable { case pending, displayed }

public struct Alert: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sequence: Int64
    public var state: AlertState
    public var occurrenceTime: Date
    public var receiptTime: Date
    public var sourceID: UUID
    public var sourceName: String
    public var ruleID: UUID
    public var ruleName: String
    public var severity: Severity
    public var message: String
    public var attributes: [String: JSONValue]?
    public var collectionWindowID: UUID
}

public struct CollectionWindow: Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var deadline: Date
}

public struct FrozenCollectionWindow: Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var remaining: TimeInterval
}

public enum CollectionWindowState: Codable, Equatable, Sendable {
    case idle
    case collecting(CollectionWindow)
    case frozen(FrozenCollectionWindow)

    private enum Kind: String, Codable { case idle, collecting, frozen }
    private enum CodingKeys: String, CodingKey { case kind, window, frozenWindow }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .collecting: self = .collecting(try container.decode(CollectionWindow.self, forKey: .window))
        case .frozen: self = .frozen(try container.decode(FrozenCollectionWindow.self, forKey: .frozenWindow))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle: try container.encode(Kind.idle, forKey: .kind)
        case .collecting(let window):
            try container.encode(Kind.collecting, forKey: .kind)
            try container.encode(window, forKey: .window)
        case .frozen(let window):
            try container.encode(Kind.frozen, forKey: .kind)
            try container.encode(window, forKey: .frozenWindow)
        }
    }
}

public struct AlertEngineState: Codable, Equatable, Sendable {
    public var monitoringPaused: Bool
    public var activeWindow: CollectionWindowState
    public var pendingAlerts: [Alert]
    public var displayedAlerts: [Alert]
    public var pendingOmittedCount: Int
    public var displayedOmittedCount: Int
    public var nextSequence: Int64
    public var recoveryDiagnostics: [String]

    public init(
        monitoringPaused: Bool = false,
        activeWindow: CollectionWindowState = .idle,
        pendingAlerts: [Alert] = [],
        displayedAlerts: [Alert] = [],
        pendingOmittedCount: Int = 0,
        displayedOmittedCount: Int = 0,
        nextSequence: Int64 = 0,
        recoveryDiagnostics: [String] = []
    ) {
        self.monitoringPaused = monitoringPaused
        self.activeWindow = activeWindow
        self.pendingAlerts = pendingAlerts
        self.displayedAlerts = displayedAlerts
        self.pendingOmittedCount = pendingOmittedCount
        self.displayedOmittedCount = displayedOmittedCount
        self.nextSequence = nextSequence
        self.recoveryDiagnostics = recoveryDiagnostics
    }
}

public struct AlertSnapshot: Equatable, Sendable {
    public var displayedAlerts: [Alert]
    public var pendingAlerts: [Alert]
    public var omittedCount: Int
    public var pendingOmittedCount: Int
    public var highestSeverity: Severity?
    public var monitoringPaused: Bool
    public var recoveryDiagnostics: [String]

    public init(state: AlertEngineState) {
        displayedAlerts = state.displayedAlerts
        pendingAlerts = state.pendingAlerts
        omittedCount = state.displayedOmittedCount
        pendingOmittedCount = state.pendingOmittedCount
        highestSeverity = state.displayedAlerts.map(\.severity).max()
        monitoringPaused = state.monitoringPaused
        recoveryDiagnostics = state.recoveryDiagnostics
    }
}

public enum IngestResult: Equatable, Sendable {
    case acceptedUnmatched
    case acceptedMatched
    case discardedDuringPause
}
