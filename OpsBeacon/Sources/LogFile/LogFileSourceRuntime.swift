import Foundation
import Dispatch

public struct LogRuntimeReadResult: Equatable, Sendable {
    public var linesRead: Int
    public var oversizedLines: Int
    public var cursor: LogCursor
}

/// Runtime adapter for one already-authorized file. Cursor persistence is delegated to ConfigurationStore.
public actor LogFileSourceRuntime: SourceRuntime {
    public nonisolated let sourceID: UUID
    private let fileURL: URL
    private let engine: AlertEngine
    private let issue: @Sendable (SourceIssueKind, String) async throws -> Void
    private let cursorDidCommit: @Sendable (LogCursor) async throws -> Void
    private let scopedDirectory: URL?
    private var cursor: LogCursor
    private var framer = LogLineFramer()
    private var handle: FileHandle?
    private var activeFileIdentity: String?
    private var readOffset: UInt64 = 0
    private var vnodeSource: DispatchSourceFileSystemObject?
    private var drainingHandle: FileHandle?
    private var drainingReadOffset: UInt64 = 0
    private var drainingFramer = LogLineFramer()
    private var drainingVnodeSource: DispatchSourceFileSystemObject?

    public init(
        sourceID: UUID,
        fileURL: URL,
        cursor: LogCursor = .init(),
        engine: AlertEngine,
        scopedDirectory: URL? = nil,
        cursorDidCommit: @escaping @Sendable (LogCursor) async throws -> Void = { _ in },
        issue: @escaping @Sendable (SourceIssueKind, String) async throws -> Void = { _, _ in }
    ) {
        self.sourceID = sourceID
        self.fileURL = fileURL
        self.cursor = cursor
        self.engine = engine
        self.cursorDidCommit = cursorDidCommit
        self.scopedDirectory = scopedDirectory
        self.issue = issue
    }

    deinit {
        vnodeSource?.cancel()
        drainingVnodeSource?.cancel()
        try? handle?.close()
        try? drainingHandle?.close()
    }

    /// First attachment starts at EOF; an existing cursor resumes at its last committed complete line.
    public func start() async throws {
        try openOrAttach()
        try await restoreDrainingGenerationIfNeeded()
        try await cursorDidCommit(cursor)
        installVnodeMonitor()
    }

    public func stop() {
        vnodeSource?.cancel()
        vnodeSource = nil
        drainingVnodeSource?.cancel()
        drainingVnodeSource = nil
        try? handle?.close()
        handle = nil
        try? drainingHandle?.close()
        drainingHandle = nil
        scopedDirectory?.stopAccessingSecurityScopedResource()
    }

    @discardableResult
    public func readAvailable() async throws -> LogRuntimeReadResult {
        if handle == nil { try openOrAttach() }
        guard let handle else { throw CocoaError(.fileNoSuchFile) }
        _ = try await drainPreviousGeneration()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let pathIdentity = Self.fileIdentity(attributes)
        if activeFileIdentity != pathIdentity {
            // The descriptor still refers to the renamed generation. Drain completed
            // lines from it before changing to the replacement at the configured path.
            _ = try await consumeAvailable(from: handle)
            try await switchToReplacement(attributes: attributes)
            return try await readAvailable()
        }
        if size < readOffset {
            try handle.seek(toOffset: 0)
            readOffset = 0
            cursor.committedOffset = 0
            framer = LogLineFramer()
        }
        return try await consumeAvailable(from: handle)
    }

    private func consumeAvailable(from handle: FileHandle) async throws -> LogRuntimeReadResult {
        try handle.seek(toOffset: readOffset)
        let bytes = try handle.readToEnd() ?? Data()
        guard !bytes.isEmpty else { return .init(linesRead: 0, oversizedLines: 0, cursor: cursor) }
        readOffset += UInt64(bytes.count)
        let framing = framer.append(bytes)
        try await ingest(framing)
        cursor.committedOffset = readOffset - UInt64(framer.uncommittedByteCount)
        try await cursorDidCommit(cursor)
        if framing.oversizedLineCount > 0 {
            try await issue(.oversizedLine, "A log line exceeded the 256 KiB safety limit and was discarded.")
        }
        return .init(linesRead: framing.lines.count, oversizedLines: framing.oversizedLineCount, cursor: cursor)
    }

    @discardableResult
    private func drainPreviousGeneration() async throws -> LogRuntimeReadResult {
        guard let drainingHandle else { return .init(linesRead: 0, oversizedLines: 0, cursor: cursor) }
        try drainingHandle.seek(toOffset: drainingReadOffset)
        let bytes = try drainingHandle.readToEnd() ?? Data()
        guard !bytes.isEmpty else { return .init(linesRead: 0, oversizedLines: 0, cursor: cursor) }
        drainingReadOffset += UInt64(bytes.count)
        let framing = drainingFramer.append(bytes)
        try await ingest(framing)
        if var generation = cursor.drainingGeneration {
            generation.committedOffset = drainingReadOffset - UInt64(drainingFramer.uncommittedByteCount)
            cursor.drainingGeneration = generation
        }
        try await cursorDidCommit(cursor)
        if framing.oversizedLineCount > 0 {
            try await issue(.oversizedLine, "A log line exceeded the 256 KiB safety limit and was discarded.")
        }
        return .init(linesRead: framing.lines.count, oversizedLines: framing.oversizedLineCount, cursor: cursor)
    }

    private func ingest(_ framing: LogFramingResult) async throws {
        let occurrence = Date()
        for line in framing.lines {
            _ = try await engine.ingest(.log(.init(message: line, occurredAt: occurrence)), from: sourceID)
        }
    }

    public func currentCursor() -> LogCursor { cursor }

    private func fileSystemDidChange() async {
        do { _ = try await readAvailable() }
        catch { try? await issue(.rotationGap, "The configured log file could not be read after a filesystem change.") }
    }

    private func openOrAttach() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = Self.fileIdentity(attributes)
        let opened = try FileHandle(forReadingFrom: fileURL)
        handle = opened
        activeFileIdentity = identity
        if cursor.fileIdentity == nil {
            cursor.fileIdentity = identity
            cursor.committedOffset = size
        } else if cursor.fileIdentity != identity || cursor.committedOffset > size {
            cursor.fileIdentity = identity
            cursor.committedOffset = 0
        }
        readOffset = cursor.committedOffset
    }

    private func restoreDrainingGenerationIfNeeded() async throws {
        guard let generation = cursor.drainingGeneration else { return }
        guard let recoveryURL = try findDirectChild(withIdentity: generation.fileIdentity) else {
            cursor.drainingGeneration = nil
            try await cursorDidCommit(cursor)
            try await issue(.rotationGap, "A renamed log generation was unavailable during restart recovery; unread bytes may have been missed.")
            return
        }
        drainingHandle = try FileHandle(forReadingFrom: recoveryURL)
        drainingReadOffset = generation.committedOffset
        drainingFramer = LogLineFramer()
        _ = try await drainPreviousGeneration()
    }

    private func findDirectChild(withIdentity identity: String?) throws -> URL? {
        guard let identity else { return nil }
        let started = ContinuousClock.now
        let directory = fileURL.deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        for candidate in candidates.prefix(1_000) {
            if started.duration(to: .now) > .milliseconds(250) { return nil }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path) else { continue }
            if Self.fileIdentity(attributes) == identity { return candidate }
        }
        return nil
    }

    private func switchToReplacement(attributes: [FileAttributeKey: Any]) async throws {
        let replacement = try FileHandle(forReadingFrom: fileURL)
        if let existingDrainingHandle = drainingHandle {
            // Retain at most one completed generation. A second rapid rotation is
            // still safe for the current file and is surfaced as a monitoring gap.
            try? existingDrainingHandle.close()
            drainingVnodeSource?.cancel()
            drainingVnodeSource = nil
            drainingHandle = nil
            try await issue(.rotationGap, "A previous renamed log generation could not remain open through a second rotation.")
        }
        drainingHandle = handle
        drainingReadOffset = readOffset
        drainingFramer = framer
        drainingVnodeSource = vnodeSource
        cursor.drainingGeneration = .init(fileIdentity: activeFileIdentity, committedOffset: cursor.committedOffset)
        vnodeSource = nil
        handle = replacement
        activeFileIdentity = Self.fileIdentity(attributes)
        cursor.fileIdentity = activeFileIdentity
        cursor.committedOffset = 0
        readOffset = 0
        framer = LogLineFramer()
        installVnodeMonitor()
        try await cursorDidCommit(cursor)
    }

    private func installVnodeMonitor() {
        vnodeSource?.cancel()
        vnodeSource = nil
        guard let handle else { return }
        let runtime = self
        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .global(qos: .utility)
        )
        monitor.setEventHandler { [runtime] in
            Task { await runtime.fileSystemDidChange() }
        }
        monitor.resume()
        vnodeSource = monitor
    }

    private static func fileIdentity(_ attributes: [FileAttributeKey: Any]) -> String? {
        (attributes[.systemFileNumber] as? NSNumber).map { $0.stringValue }
    }
}
