import Foundation

public struct DrainingLogGeneration: Codable, Equatable, Sendable {
    public var fileIdentity: String?
    public var committedOffset: UInt64

    public init(fileIdentity: String?, committedOffset: UInt64) {
        self.fileIdentity = fileIdentity
        self.committedOffset = committedOffset
    }
}

public struct LogCursor: Codable, Equatable, Sendable {
    public var fileIdentity: String?
    public var committedOffset: UInt64
    /// One renamed generation can remain writable while a replacement is read.
    /// Persisting this metadata allows a later recovery to surface a gap instead
    /// of silently treating the old unread bytes as consumed.
    public var drainingGeneration: DrainingLogGeneration?

    public init(fileIdentity: String? = nil, committedOffset: UInt64 = 0, drainingGeneration: DrainingLogGeneration? = nil) {
        self.fileIdentity = fileIdentity
        self.committedOffset = committedOffset
        self.drainingGeneration = drainingGeneration
    }
}

public enum LogPathError: Error, LocalizedError, Equatable {
    case absolutePath
    case traversal

    public var errorDescription: String? {
        switch self {
        case .absolutePath: "A Log File Source path must be relative to its authorized directory."
        case .traversal: "A Log File Source path cannot traverse outside its authorized directory."
        }
    }
}

public func validatedRelativeLogPath(_ path: String) throws -> String {
    guard !path.hasPrefix("/") else { throw LogPathError.absolutePath }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains("..") else { throw LogPathError.traversal }
    return components.filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
}
