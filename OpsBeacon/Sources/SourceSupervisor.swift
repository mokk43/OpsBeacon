import Foundation

public enum SourceHealth: String, Codable, Sendable {
    case starting
    case monitoring
    case paused
    case needsAuthorization
    case fileMissing
    case degradedAfterGap
    case failed
}

public protocol SourceRuntime: Sendable {
    var sourceID: UUID { get async }
    func start() async throws
    func stop() async
}

/// Owns runtime lifecycle only; all Alert semantics remain inside AlertEngine.
public actor SourceSupervisor {
    public typealias RuntimeFactory = @Sendable (AlertSource) async throws -> any SourceRuntime

    private let factory: RuntimeFactory
    private var runtimes: [UUID: any SourceRuntime] = [:]
    private var health: [UUID: SourceHealth] = [:]

    public init(factory: @escaping RuntimeFactory) { self.factory = factory }

    public func reconcile(enabledSources: [AlertSource], monitoringPaused: Bool) async {
        let enabled = Dictionary(uniqueKeysWithValues: enabledSources.filter(\.enabled).map { ($0.id, $0) })
        let removed = runtimes.keys.filter { enabled[$0] == nil }
        for id in removed {
            await runtimes[id]?.stop()
            runtimes.removeValue(forKey: id)
            health.removeValue(forKey: id)
        }
        for source in enabled.values where runtimes[source.id] == nil {
            health[source.id] = .starting
            do {
                let runtime = try await factory(source)
                try await runtime.start()
                runtimes[source.id] = runtime
                health[source.id] = monitoringPaused ? .paused : .monitoring
            } catch {
                health[source.id] = .failed
            }
        }
        if monitoringPaused {
            for id in runtimes.keys { health[id] = .paused }
        } else {
            for id in runtimes.keys where health[id] == .paused { health[id] = .monitoring }
        }
    }

    public func status(for sourceID: UUID) -> SourceHealth? { health[sourceID] }
    public func allStatuses() -> [UUID: SourceHealth] { health }

    public func stopAll() async {
        for runtime in runtimes.values { await runtime.stop() }
        runtimes.removeAll()
        health.removeAll()
    }
}
