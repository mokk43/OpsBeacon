import Foundation

public enum AlertEngineError: Error, LocalizedError {
    case notStarted
    case unknownOrDisabledSource(UUID)

    public var errorDescription: String? {
        switch self {
        case .notStarted: "AlertEngine has not been started."
        case .unknownOrDisabledSource: "The Source is unknown or disabled."
        }
    }
}

public actor AlertEngine {
    private static let retentionCap = 200

    private let store: any AlertStore
    private let clock: any AlertEngineClock
    private var state = AlertEngineState()
    private var configuration = AlertConfiguration(sources: [], rules: [])
    private var started = false
    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration: UInt64 = 0
    private var streams: [UUID: AsyncStream<AlertSnapshot>.Continuation] = [:]

    public init(store: any AlertStore, clock: any AlertEngineClock = SystemAlertEngineClock()) {
        self.store = store
        self.clock = clock
    }

    deinit { deadlineTask?.cancel() }

    public func start() async throws -> AlertSnapshot {
        guard !started else { return snapshot() }
        state = try await store.load() ?? AlertEngineState()
        started = true

        if case .collecting(let window) = state.activeWindow {
            let now = await clock.now()
            if window.deadline <= now {
                try await displayCollectingWindow(id: window.id)
            } else {
                let recoveredRemaining = window.deadline.timeIntervalSince(now)
                let maximumRemaining = configuration.collectionWindow
                if recoveredRemaining > maximumRemaining {
                    let clamped = CollectionWindow(
                        id: window.id,
                        startedAt: window.startedAt,
                        deadline: now.addingTimeInterval(maximumRemaining)
                    )
                    state.activeWindow = .collecting(clamped)
                    latchRecoveryDiagnostic("Collection Window recovery deadline was clamped to its configured duration.")
                    try await store.save(state)
                    scheduleDeadline(for: clamped)
                } else {
                    scheduleDeadline(for: window)
                }
            }
        }
        publish()
        return snapshot()
    }

    public func applyConfiguration(_ requested: AlertConfiguration) async throws {
        guard requested.collectionWindow >= 1, requested.collectionWindow <= 3_600 else {
            throw RuleValidationError.invalidConfiguration("Collection Window must be between 1 second and 1 hour.")
        }
        for rule in requested.rules { try rule.validate() }
        let sourceIDs = Set(requested.sources.map(\.id))
        guard requested.rules.allSatisfy({ sourceIDs.contains($0.sourceID) }) else {
            throw RuleValidationError.invalidConfiguration("Every Rule must belong to a configured Source.")
        }
        var installed = requested
        installed.revision = max(requested.revision, configuration.revision + 1)
        configuration = installed
        publish()
    }

    public func ingest(_ signal: Signal, from sourceID: UUID) async throws -> IngestResult {
        guard started else { throw AlertEngineError.notStarted }
        guard let source = configuration.sources.first(where: { $0.id == sourceID && $0.enabled }) else {
            throw AlertEngineError.unknownOrDisabledSource(sourceID)
        }
        guard !state.monitoringPaused else { return .discardedDuringPause }

        let rules = configuration.rules
            .filter { $0.sourceID == sourceID && $0.enabled }
            .sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        guard let rule = rules.first(where: { $0.matches(signal) }) else { return .acceptedUnmatched }

        let now = await clock.now()
        let window: CollectionWindow
        switch state.activeWindow {
        case .idle:
            window = CollectionWindow(id: UUID(), startedAt: now, deadline: now.addingTimeInterval(configuration.collectionWindow))
            state.activeWindow = .collecting(window)
        case .collecting(let current):
            window = current
        case .frozen:
            preconditionFailure("Paused monitoring discards Signals before matching.")
        }

        state.nextSequence += 1
        let attributes: [String: JSONValue]?
        if case .push(let push) = signal { attributes = push.attributes } else { attributes = nil }
        let alert = Alert(
            id: UUID(), sequence: state.nextSequence, state: .pending,
            occurrenceTime: signal.occurredAt, receiptTime: now,
            sourceID: source.id, sourceName: source.name, ruleID: rule.id, ruleName: rule.name,
            severity: rule.severity, message: signal.message, attributes: attributes, collectionWindowID: window.id
        )
        state.pendingAlerts.append(alert)
        trimPending()
        try await store.save(state)
        if case .collecting = state.activeWindow, deadlineTask == nil { scheduleDeadline(for: window) }
        publish()
        return .acceptedMatched
    }

    public func setMonitoringPaused(_ paused: Bool) async throws {
        guard started else { throw AlertEngineError.notStarted }
        guard state.monitoringPaused != paused else { return }
        let now = await clock.now()
        if paused, case .collecting(let window) = state.activeWindow {
            cancelDeadline()
            state.activeWindow = .frozen(.init(id: window.id, startedAt: window.startedAt, remaining: max(0, window.deadline.timeIntervalSince(now))))
        } else if !paused, case .frozen(let frozen) = state.activeWindow {
            let window = CollectionWindow(id: frozen.id, startedAt: frozen.startedAt, deadline: now.addingTimeInterval(frozen.remaining))
            state.activeWindow = .collecting(window)
            scheduleDeadline(for: window)
        }
        state.monitoringPaused = paused
        try await store.save(state)
        publish()
    }

    public func acknowledgeDisplayed() async throws {
        guard started else { throw AlertEngineError.notStarted }
        state.displayedAlerts.removeAll()
        state.displayedOmittedCount = 0
        try await store.save(state)
        publish()
    }

    public func snapshots() -> AsyncStream<AlertSnapshot> {
        let id = UUID()
        let pair = AsyncStream<AlertSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(16))
        streams[id] = pair.continuation
        pair.continuation.yield(snapshot())
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStream(id) }
        }
        return pair.stream
    }

    private func removeStream(_ id: UUID) { streams.removeValue(forKey: id) }

    private func scheduleDeadline(for window: CollectionWindow) {
        cancelDeadline()
        let generation = deadlineGeneration
        let clock = self.clock
        deadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(until: window.deadline)
                guard !Task.isCancelled else { return }
                await self?.deadlineReached(for: window.id, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func deadlineReached(for id: UUID, generation: UInt64) async {
        guard generation == deadlineGeneration,
              case .collecting(let window) = state.activeWindow,
              window.id == id else { return }
        do { try await displayCollectingWindow(id: id) }
        catch { /* The next restart retries a failed durable transition. */ }
    }

    private func displayCollectingWindow(id: UUID) async throws {
        guard case .collecting(let window) = state.activeWindow, window.id == id else { return }
        cancelDeadline()
        let newDisplayed = state.pendingAlerts.map { pending in
            var displayed = pending
            displayed.state = .displayed
            return displayed
        }
        state.displayedAlerts.append(contentsOf: newDisplayed)
        state.displayedOmittedCount += state.pendingOmittedCount
        state.pendingAlerts.removeAll()
        state.pendingOmittedCount = 0
        state.activeWindow = .idle
        trimDisplayed()
        try await store.save(state)
        publish()
    }

    private func trimPending() {
        let overflow = max(0, state.pendingAlerts.count - Self.retentionCap)
        guard overflow > 0 else { return }
        state.pendingAlerts.removeFirst(overflow)
        state.pendingOmittedCount += overflow
    }

    private func trimDisplayed() {
        let overflow = max(0, state.displayedAlerts.count - Self.retentionCap)
        guard overflow > 0 else { return }
        state.displayedAlerts.removeFirst(overflow)
        state.displayedOmittedCount += overflow
    }

    private func latchRecoveryDiagnostic(_ diagnostic: String) {
        guard !state.recoveryDiagnostics.contains(diagnostic) else { return }
        state.recoveryDiagnostics.append(diagnostic)
    }

    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        deadlineGeneration &+= 1
    }

    private func snapshot() -> AlertSnapshot { AlertSnapshot(state: state) }

    private func publish() {
        let value = snapshot()
        streams.values.forEach { $0.yield(value) }
    }
}
