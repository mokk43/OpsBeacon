import XCTest
@testable import OpsBeacon

final class PersistenceTests: XCTestCase {
    func testFileAlertStoreAtomicallyRoundTripsCompleteEngineState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("engine.json")
        let store = FileAlertStore(fileURL: url)
        let state = AlertEngineState(monitoringPaused: true, pendingOmittedCount: 3, displayedOmittedCount: 4, nextSequence: 8)

        try await store.save(state)

        let loadedState = try await store.load()
        XCTAssertEqual(loadedState, state)
    }

    func testConfigurationStorePersistsOnlyKeychainReferenceNotCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("configuration.json")
        let source = AlertSource(name: "Push", kind: .localPush)
        let configuration = StoredConfiguration(
            alertConfiguration: .init(sources: [source], rules: []),
            pushSources: [source.id: .init(sourceID: source.id, keychainReference: source.id.uuidString)]
        )
        let store = FileConfigurationStore(fileURL: url)

        try await store.save(configuration)

        let serialized = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(serialized.contains("Bearer"))
        let loadedConfiguration = try await store.load()
        XCTAssertEqual(loadedConfiguration, configuration)
    }

    func testSwiftDataAlertStoreRoundTripsOneCompleteState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SwiftDataAlertStore(url: directory.appendingPathComponent("state.store"))
        let state = AlertEngineState(monitoringPaused: true, pendingOmittedCount: 9)

        try await store.save(state)

        let loadedState = try await store.load()
        XCTAssertEqual(loadedState, state)
    }
}
