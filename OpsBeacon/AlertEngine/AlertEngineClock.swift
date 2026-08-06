import Foundation

public protocol AlertEngineClock: Sendable {
    func now() async -> Date
    func sleep(until deadline: Date) async throws
}

public struct SystemAlertEngineClock: AlertEngineClock {
    private let continuousClock: ContinuousClock
    private let continuousAnchor: ContinuousClock.Instant
    private let wallClockAnchor: Date

    public init() {
        let clock = ContinuousClock()
        continuousClock = clock
        continuousAnchor = clock.now
        wallClockAnchor = Date()
    }

    /// A Date-shaped wall-clock value anchored to a monotonic clock. This keeps
    /// an active Collection Window stable when the user changes time or zone.
    public func now() async -> Date {
        wallClockAnchor.addingTimeInterval(continuousAnchor.duration(to: continuousClock.now).timeInterval)
    }

    public func sleep(until deadline: Date) async throws {
        let interval = max(0, deadline.timeIntervalSince(await now()))
        try await Task.sleep(for: .seconds(interval))
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

public actor ManualAlertEngineClock: AlertEngineClock {
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, Error>
    }

    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]

    public init(now: Date) { current = now }

    public func now() -> Date { current }

    public func sleep(until deadline: Date) async throws {
        guard deadline > current else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelSleeper(id) }
        })
    }

    public func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
        let ready = sleepers.filter { $0.value.deadline <= current }
        for (id, sleeper) in ready {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
