import Foundation

public enum SecurityScopedLogAccessError: Error, LocalizedError {
    case inaccessibleBookmark
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .inaccessibleBookmark: "The authorized log directory could not be resolved."
        case .accessDenied: "OpsBeacon no longer has access to the authorized log directory."
        }
    }
}

public struct SecurityScopedLogAccess {
    public static func createDirectoryBookmark(for directory: URL) throws -> Data {
        try directory.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func withDirectory<T>(bookmark: Data, _ body: (URL) throws -> T) throws -> T {
        var stale = false
        let directory = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard directory.startAccessingSecurityScopedResource() else { throw SecurityScopedLogAccessError.accessDenied }
        defer { directory.stopAccessingSecurityScopedResource() }
        return try body(directory)
    }
}
