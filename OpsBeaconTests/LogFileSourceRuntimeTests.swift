import Foundation
import XCTest
@testable import OpsBeacon

final class LogFileSourceRuntimeTests: XCTestCase {
    func testRestartDrainsPersistedRenamedGenerationFoundByDirectChildIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let current = directory.appendingPathComponent("service.log")
        let rotated = directory.appendingPathComponent("service.log.1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing line\n".utf8).write(to: current)

        let source = AlertSource(name: "Service", kind: .logFile)
        let rule = Rule(sourceID: source.id, name: "All lines", order: 0, matcher: .log(.contains("line", caseSensitive: true)))
        let firstEngine = AlertEngine(store: InMemoryAlertStore())
        _ = try await firstEngine.start()
        try await firstEngine.applyConfiguration(.init(sources: [source], rules: [rule]))
        let firstRuntime = LogFileSourceRuntime(sourceID: source.id, fileURL: current, engine: firstEngine)
        try await firstRuntime.start()
        try FileManager.default.moveItem(at: current, to: rotated)
        try Data("new generation line\n".utf8).write(to: current)
        _ = try await firstRuntime.readAvailable()
        let cursor = await firstRuntime.currentCursor()
        XCTAssertNotNil(cursor.drainingGeneration)
        await firstRuntime.stop()

        try append("late previous generation line\n", to: rotated)
        let secondEngine = AlertEngine(store: InMemoryAlertStore())
        _ = try await secondEngine.start()
        try await secondEngine.applyConfiguration(.init(sources: [source], rules: [rule]))
        let recoveredRuntime = LogFileSourceRuntime(sourceID: source.id, fileURL: current, cursor: cursor, engine: secondEngine)
        try await recoveredRuntime.start()

        let stream = await secondEngine.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let snapshot = await snapshots.next()
        XCTAssertEqual(snapshot?.pendingAlerts.map(\.message), ["late previous generation line"])
        await recoveredRuntime.stop()
    }

    func testReplacementDrainsTheRenamedGenerationBeforeReadingTheNewFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let current = directory.appendingPathComponent("service.log")
        let rotated = directory.appendingPathComponent("service.log.1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing line\n".utf8).write(to: current)

        let clock = ManualAlertEngineClock(now: .init(timeIntervalSince1970: 5_000))
        let engine = AlertEngine(store: InMemoryAlertStore(), clock: clock)
        let source = AlertSource(name: "Service", kind: .logFile)
        let rule = Rule(sourceID: source.id, name: "All lines", order: 0, matcher: .log(.contains("line", caseSensitive: true)))
        _ = try await engine.start()
        try await engine.applyConfiguration(.init(sources: [source], rules: [rule]))

        let runtime = LogFileSourceRuntime(sourceID: source.id, fileURL: current, engine: engine)
        // Attach at EOF without installing a vnode source so this test controls
        // exactly when the runtime observes the replacement.
        _ = try await runtime.readAvailable()
        try append("before replacement line\n", to: current)
        try FileManager.default.moveItem(at: current, to: rotated)
        try append("after replacement line\n", to: rotated)
        try Data("new generation line\n".utf8).write(to: current)

        _ = try await runtime.readAvailable()
        let stream = await engine.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let snapshot = await snapshots.next()
        XCTAssertEqual(
            snapshot?.pendingAlerts.map(\.message),
            ["before replacement line", "after replacement line", "new generation line"]
        )
        await runtime.stop()
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
