import Foundation

public struct LocalPushRuntimeConfiguration: Equatable, Sendable {
    public var port: Int
    public var routes: [PushRoute]

    public init(port: Int, routes: [PushRoute]) {
        self.port = port
        self.routes = routes
    }
}

public enum LocalPushRuntimeError: Error, LocalizedError, Sendable {
    case restorationFailed(requested: String, restoration: String)

    public var errorDescription: String? {
        switch self {
        case .restorationFailed(let requested, let restoration):
            "Local Push could not apply the requested port (\(requested)) or restore the previous port (\(restoration))."
        }
    }
}

/// Owns the one app-wide listener and applies route/port changes serially.
public actor LocalPushRuntime {
    private let registry: PushRouteRegistry
    private let listener: LocalPushHTTPListener
    private var active: LocalPushRuntimeConfiguration?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(engine: AlertEngine) {
        registry = PushRouteRegistry(engine: engine)
        listener = LocalPushHTTPListener(registry: registry)
    }

    public func apply(_ requested: LocalPushRuntimeConfiguration) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try await applyUnlocked(requested)
    }

    public func stop() async {
        await acquireOperation()
        defer { releaseOperation() }
        if let active {
            await registry.configure(routes: active.routes, port: active.port, ready: false)
        }
        await listener.stop()
        active = nil
    }

    public func activeConfiguration() -> LocalPushRuntimeConfiguration? {
        active
    }

    private func applyUnlocked(_ requested: LocalPushRuntimeConfiguration) async throws {
        guard active != requested else { return }
        if active?.port == requested.port {
            await activate(requested)
            return
        }

        let previous = active
        await registry.configure(routes: requested.routes, port: requested.port, ready: false)
        if previous != nil {
            await listener.stop()
            active = nil
        }
        do {
            try await listener.start(port: requested.port)
            await activate(requested)
        } catch let requestedError {
            guard let previous else { throw requestedError }
            do {
                try await listener.start(port: previous.port)
                await activate(previous)
            } catch let restorationError {
                await registry.configure(routes: previous.routes, port: previous.port, ready: false)
                throw LocalPushRuntimeError.restorationFailed(
                    requested: requestedError.localizedDescription,
                    restoration: restorationError.localizedDescription
                )
            }
            throw requestedError
        }
    }

    private func activate(_ configuration: LocalPushRuntimeConfiguration) async {
        await registry.configure(routes: configuration.routes, port: configuration.port, ready: true)
        active = configuration
    }

    private func acquireOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}
