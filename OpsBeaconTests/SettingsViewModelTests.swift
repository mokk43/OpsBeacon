import Foundation
import XCTest
@testable import OpsBeacon

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testRapidSettingsChangesPreserveEveryEditAndKeepLocalPushReachable() async throws {
        let source = AlertSource(name: "Deployments", kind: .localPush)
        let rule = Rule(
            sourceID: source.id,
            name: "Failures",
            order: 0,
            matcher: .push(name: nil, conditions: [])
        )
        let configuration = StoredConfiguration(
            alertConfiguration: .init(sources: [source], rules: [rule]),
            pushSources: [source.id: .init(sourceID: source.id, keychainReference: source.id.uuidString)]
        )
        let store = InMemoryConfigurationStore(configuration: configuration)
        let engine = AlertEngine(store: InMemoryAlertStore())
        _ = try await engine.start()
        try await engine.applyConfiguration(configuration.alertConfiguration)

        let route = PushRoute(sourceID: source.id, enabled: true, credential: "secret")
        let port = try availableLoopbackPort()
        let runtime = LocalPushRuntime(engine: engine)
        try await runtime.apply(.init(port: port, routes: [route]))
        let completions = AsyncCompletionCounter(count: 2)
        let model = SettingsViewModel(configurationStore: store, engine: engine)
        model.setConfigurationApplied { stored in
            try? await runtime.apply(.init(port: port, routes: [route]))
            await completions.complete()
            return stored
        }
        model.load()
        await waitUntil { !model.rules.isEmpty }

        model.ruleNameBinding(for: rule.id).wrappedValue = "Deployment failures"
        model.ruleSeverityBinding(for: rule.id).wrappedValue = .critical
        await completions.wait()

        let persisted = try await store.load()
        let persistedRule = try XCTUnwrap(persisted.alertConfiguration.rules.first { $0.id == rule.id })
        XCTAssertEqual(persistedRule.name, "Deployment failures")
        XCTAssertEqual(persistedRule.severity, .critical)

        let response = try await sendPush(
            port: port,
            sourceID: source.id,
            credential: "secret",
            name: "deployment.failed"
        )
        await runtime.stop()

        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.body["matched"] as? Bool, true)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for Settings to load.")
    }
}

private actor AsyncCompletionCounter {
    private var remaining: Int
    private var waiter: CheckedContinuation<Void, Never>?

    init(count: Int) {
        remaining = count
    }

    func complete() {
        remaining -= 1
        guard remaining == 0 else { return }
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard remaining > 0 else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
