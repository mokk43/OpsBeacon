import AppKit
import Foundation
import OSLog
#if SWIFT_PACKAGE
import OpsBeacon
#endif
import SwiftUI

@MainActor
final class AppEnvironment: NSObject {
    private let logger = Logger(subsystem: "com.opsbeacon.app", category: "lifecycle")
    private let configurationStore: any ConfigurationStore
    private let alertStore: any AlertStore
    private let credentialStore: any PushCredentialStore
    let engine: AlertEngine
    private let pushRegistry: PushRouteRegistry
    private let pushListener: LocalPushHTTPListener
    private let toastCoordinator: ToastPresentationCoordinator
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var snapshotTask: Task<Void, Never>?
    private var sourceSupervisor: SourceSupervisor?
    private var monitoringPaused = false
    private var activePushPort: Int?
    private var hasUnresolvedIssues = false

    override init() {
        let directory = Self.applicationSupportDirectory()
        configurationStore = FileConfigurationStore(fileURL: directory.appendingPathComponent("Configuration.json"))
        do {
            alertStore = try SwiftDataAlertStore(url: directory.appendingPathComponent("AlertState.store"))
        } catch {
            fatalError("OpsBeacon could not initialize its durable Alert store: \(error.localizedDescription)")
        }
        engine = AlertEngine(store: alertStore)
        credentialStore = KeychainPushCredentialStore()
        pushRegistry = PushRouteRegistry(engine: engine)
        pushListener = LocalPushHTTPListener(registry: pushRegistry)
        toastCoordinator = ToastPresentationCoordinator(engine: engine, configurationStore: configurationStore)
        super.init()
    }

    func start() {
        Task { [weak self, engine, configurationStore] in
            guard let self else { return }
            do {
                var stored = try await configurationStore.load()
                var configuration = stored.alertConfiguration
                configuration.collectionWindow = stored.settings.collectionWindow
                try await engine.applyConfiguration(configuration)
                let recovered = try await engine.start()
                do {
                    try await self.startPushListener(using: stored)
                } catch {
                    self.latchListenerFailure(error.localizedDescription, in: &stored)
                    try? await configurationStore.save(stored)
                    self.logger.error("Local Push listener did not start: \(error.localizedDescription, privacy: .public)")
                }
                try await self.startLogSources(using: stored, monitoringPaused: recovered.monitoringPaused)
                await MainActor.run {
                    self.hasUnresolvedIssues = stored.sourceIssues.contains { !$0.resolved }
                    self.installPresentation()
                    self.logger.info("OpsBeacon started")
                }
            } catch {
                self.logger.error("OpsBeacon startup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startLogSources(using stored: StoredConfiguration, monitoringPaused: Bool) async throws {
        let logConfigurations = stored.logSources
        let engine = engine
        let configurationStore = configurationStore
        let supervisor = SourceSupervisor { source in
            guard source.kind == .logFile, let log = logConfigurations[source.id], let bookmark = log.directoryBookmark else {
                throw CocoaError(.fileNoSuchFile)
            }
            var stale = false
            let directory = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard directory.startAccessingSecurityScopedResource() else { throw SecurityScopedLogAccessError.accessDenied }
            do {
                let relative = try validatedRelativeLogPath(log.relativePath)
                let runtime = LogFileSourceRuntime(
                    sourceID: source.id,
                    fileURL: directory.appendingPathComponent(relative),
                    cursor: log.cursor,
                    engine: engine,
                    scopedDirectory: directory,
                    cursorDidCommit: { cursor in
                        var current = try await configurationStore.load()
                        guard var storedLog = current.logSources[source.id] else { return }
                        storedLog.cursor = cursor
                        current.logSources[source.id] = storedLog
                        try await configurationStore.save(current)
                    },
                    issue: { kind, detail in
                        var current = try await configurationStore.load()
                        current.sourceIssues.append(.init(sourceID: source.id, kind: kind, redactedDetail: detail))
                        try await configurationStore.save(current)
                    }
                )
                return runtime
            } catch {
                directory.stopAccessingSecurityScopedResource()
                throw error
            }
        }
        sourceSupervisor = supervisor
        await supervisor.reconcile(enabledSources: stored.alertConfiguration.sources.filter { $0.kind == .logFile }, monitoringPaused: monitoringPaused)
    }

    private func startPushListener(using stored: StoredConfiguration) async throws {
        var routes: [PushRoute] = []
        for source in stored.alertConfiguration.sources where source.kind == .localPush {
            guard let push = stored.pushSources[source.id],
                  let credential = try await credentialStore.credential(for: source.id) else { continue }
            _ = push // The reference is intentionally not exposed outside the persistence boundary.
            routes.append(.init(sourceID: source.id, enabled: source.enabled, credential: credential))
        }
        await pushRegistry.configure(routes: routes, port: stored.settings.pushPort, ready: false)
        try await pushListener.start(port: stored.settings.pushPort)
        activePushPort = stored.settings.pushPort
        await pushRegistry.configure(routes: routes, port: stored.settings.pushPort, ready: true)
    }

    private func reconcileRuntimes(using stored: StoredConfiguration) async -> StoredConfiguration {
        var reconciled = stored
        await pushListener.stop()
        do { try await startPushListener(using: stored) }
        catch {
            let detail = error.localizedDescription
            logger.error("Local Push listener could not be reconfigured: \(detail, privacy: .public)")
            latchListenerFailure(detail, in: &reconciled)
            if let activePushPort, activePushPort != stored.settings.pushPort {
                reconciled.settings.pushPort = activePushPort
                do { try await startPushListener(using: reconciled) }
                catch { logger.error("Local Push listener could not restore its previous port: \(error.localizedDescription, privacy: .public)") }
            }
            try? await configurationStore.save(reconciled)
        }
        await sourceSupervisor?.stopAll()
        do { try await startLogSources(using: reconciled, monitoringPaused: monitoringPaused) }
        catch { logger.error("Log Sources could not be reconfigured: \(error.localizedDescription, privacy: .public)") }
        hasUnresolvedIssues = reconciled.sourceIssues.contains { !$0.resolved }
        return reconciled
    }

    private func latchListenerFailure(_ detail: String, in configuration: inout StoredConfiguration) {
        for source in configuration.alertConfiguration.sources where source.kind == .localPush && source.enabled {
            guard !configuration.sourceIssues.contains(where: { $0.sourceID == source.id && $0.kind == .listenerFailure && !$0.resolved }) else { continue }
            configuration.sourceIssues.append(.init(sourceID: source.id, kind: .listenerFailure, redactedDetail: detail))
        }
    }

    private func installPresentation() {
        toastCoordinator.start()
        statusItem = StatusItemController(engine: engine, showAlerts: { [weak self] in self?.toastCoordinator.showAlerts() }, showSettings: { [weak self] in self?.showSettings() })
        snapshotTask = Task { [weak self, engine] in
            let stream = await engine.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.monitoringPaused = snapshot.monitoringPaused
                    self?.statusItem?.update(paused: snapshot.monitoringPaused, hasIssues: self?.hasUnresolvedIssues ?? false)
                }
            }
        }
    }

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsViewModel(configurationStore: configurationStore, engine: engine)
        model.setConfigurationApplied { [weak self] updated in
            await self?.reconcileRuntimes(using: updated) ?? updated
        }
        model.setToastGeometryReset { [weak self] in self?.toastCoordinator.resetGeometry() }
        model.load()
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "OpsBeacon Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private static func applicationSupportDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("OpsBeacon", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
