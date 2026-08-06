@preconcurrency import SwiftData
import Foundation

@Model
private final class PersistedAlertEngineState {
    @Attribute(.unique) var key: String
    @Attribute(.externalStorage) var payload: Data

    init(key: String, payload: Data) {
        self.key = key
        self.payload = payload
    }
}

/// Stores one complete encoded engine state per transition, so model objects never leave this adapter.
public actor SwiftDataAlertStore: AlertStore {
    private let context: ModelContext
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        let schema = Schema([PersistedAlertEngineState.self])
        let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> AlertEngineState? {
        let descriptor = FetchDescriptor<PersistedAlertEngineState>(predicate: #Predicate { $0.key == "engine-state" })
        guard let record = try context.fetch(descriptor).first else { return nil }
        return try decoder.decode(AlertEngineState.self, from: record.payload)
    }

    public func save(_ state: AlertEngineState) async throws {
        let descriptor = FetchDescriptor<PersistedAlertEngineState>(predicate: #Predicate { $0.key == "engine-state" })
        let payload = try encoder.encode(state)
        if let record = try context.fetch(descriptor).first {
            record.payload = payload
        } else {
            context.insert(PersistedAlertEngineState(key: "engine-state", payload: payload))
        }
        try context.save()
    }
}
