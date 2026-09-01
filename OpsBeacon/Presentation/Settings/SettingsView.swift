import AppKit
import SwiftUI

@MainActor
public struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var sourcePendingDeletion: AlertSource?

    public var body: some View {
        TabView {
            Form {
                TextField("Collection Window (seconds)", value: $model.collectionWindow, format: .number)
                TextField("Local Push port", value: $model.pushPort, format: .number)
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Text(model.monitoringPaused ? "Monitoring is paused" : "Monitoring is running")
                Button("Save General settings") { model.saveGeneral() }
                Button("Reset Toast Geometry") { model.resetToastGeometry() }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gear") }

            VStack {
                HStack {
                    Button("Add Log File…") { model.addLogFileSource() }
                    Button("Add Local Push") { model.addLocalPushSource() }
                    Spacer()
                }
                .padding([.horizontal, .top])
                List(model.sources, id: \.id) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            TextField("Source name", text: model.sourceNameBinding(for: source.id))
                            Text(source.kind == .logFile ? "Log File Source" : "Local Push Source").font(.caption).foregroundStyle(.secondary)
                            ForEach(model.issues(for: source.id)) { issue in
                                HStack(spacing: 6) {
                                    Text(issue.redactedDetail).font(.caption).foregroundStyle(.orange)
                                    if issue.resolved {
                                        Text("Resolved").font(.caption2).foregroundStyle(.secondary)
                                    } else {
                                        Button("Clear") { model.clearIssue(issue.id) }.font(.caption)
                                    }
                                }
                            }
                        }
                        Spacer()
                        Toggle("Enabled", isOn: model.enabledBinding(for: source.id))
                            .labelsHidden()
                        if source.kind == .logFile {
                            Button("Reauthorize…") { model.reauthorizeLogSource(source.id) }
                        } else {
                            Menu("Push") {
                                Button("Copy endpoint") { model.copyPushEndpoint(source.id) }
                                Button("Copy credential") { model.copyPushCredential(source.id) }
                                Button("Copy curl example") { model.copyPushCurlExample(source.id) }
                                Divider()
                                Button("Regenerate credential") { model.regeneratePushCredential(source.id) }
                            }
                        }
                        Button(role: .destructive) { sourcePendingDeletion = source } label: { Image(systemName: "trash") }
                    }
                }
            }
            .tabItem { Label("Sources", systemImage: "tray") }

            VStack {
                HStack {
                    Button("Add Log Rule") { model.addRule(kind: .logFile) }
                    Button("Add Push Rule") { model.addRule(kind: .localPush) }
                    Spacer()
                }
                .padding([.horizontal, .top])
                List {
                    ForEach(model.rules, id: \.id) { rule in
                        HStack {
                            TextField("Rule name", text: model.ruleNameBinding(for: rule.id))
                            Toggle("Enabled", isOn: model.ruleEnabledBinding(for: rule.id)).labelsHidden()
                            Picker("Severity", selection: model.ruleSeverityBinding(for: rule.id)) {
                                ForEach(Severity.allCases, id: \.self) { severity in Text(String(describing: severity)).tag(severity) }
                            }
                            .labelsHidden()
                            Button(role: .destructive) { model.deleteRule(rule.id) } label: { Image(systemName: "trash") }
                        }
                        Text(verbatim: "\(String(describing: rule.matcher)) · order \(rule.order)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .onMove(perform: model.moveRules)
                }
            }
            .tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .frame(minWidth: 520, minHeight: 340)
        .confirmationDialog(
            "Delete \(sourcePendingDeletion?.name ?? "Source")?",
            isPresented: Binding(
                get: { sourcePendingDeletion != nil },
                set: { if !$0 { sourcePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Source", role: .destructive) {
                if let source = sourcePendingDeletion { model.deleteSource(source.id) }
                sourcePendingDeletion = nil
            }
        } message: {
            Text("Its Rules and local configuration will be removed. Displayed and Pending Alerts are kept.")
        }
    }

    public init(model: SettingsViewModel) { self.model = model }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published var collectionWindow: Double = 60
    @Published var pushPort = 9780
    @Published var launchAtLogin = false
    @Published var monitoringPaused = false
    @Published var sources: [AlertSource] = []
    @Published var rules: [Rule] = []
    @Published var sourceIssues: [SourceIssue] = []

    private let configurationStore: any ConfigurationStore
    private let engine: AlertEngine
    private var configuration = StoredConfiguration()
    private var configurationApplied: @MainActor (StoredConfiguration) async -> StoredConfiguration = { $0 }
    private var toastGeometryReset: @MainActor () -> Void = {}
    private var settingsOperationTail: Task<Void, Never>?

    public init(configurationStore: any ConfigurationStore, engine: AlertEngine) {
        self.configurationStore = configurationStore
        self.engine = engine
    }

    public func load() {
        enqueueOperation { model in
            guard let stored = try? await model.configurationStore.load() else { return }
            model.configuration = stored
            model.collectionWindow = stored.settings.collectionWindow
            model.pushPort = stored.settings.pushPort
            model.launchAtLogin = stored.settings.launchAtLogin
            model.sources = stored.alertConfiguration.sources
            model.rules = stored.alertConfiguration.rules
            model.sourceIssues = stored.sourceIssues
        }
    }

    public func setConfigurationApplied(_ action: @escaping @MainActor (StoredConfiguration) async -> StoredConfiguration) {
        configurationApplied = action
    }

    public func setToastGeometryReset(_ action: @escaping @MainActor () -> Void) {
        toastGeometryReset = action
    }

    func saveGeneral() {
        enqueueOperation { model in
            let settings = (model.collectionWindow, model.pushPort, model.launchAtLogin, model.configuration)
            guard (1...3_600).contains(settings.0), (1_024...65_535).contains(settings.1) else { return }
            var updated = settings.3
            updated.settings = .init(collectionWindow: settings.0, pushPort: settings.1, launchAtLogin: settings.2)
            updated.alertConfiguration.collectionWindow = settings.0
            do {
                try await MainActor.run { try LaunchAtLogin.setEnabled(settings.2) }
                try await model.commit(updated)
            } catch { }
        }
    }

    func addLocalPushSource() {
        enqueueOperation { model in
            let source = AlertSource(name: "Local Push Source", kind: .localPush)
            let credentialStore = KeychainPushCredentialStore()
            do {
                _ = try await credentialStore.generateAndStoreCredential(for: source.id)
                var updated = model.configuration
                updated.alertConfiguration.sources.append(source)
                updated.pushSources[source.id] = .init(sourceID: source.id, keychainReference: source.id.uuidString)
                try await model.commit(updated)
            } catch { }
        }
    }

    func addLogFileSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a log file. OpsBeacon will authorize its containing directory."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let bookmark = try SecurityScopedLogAccess.createDirectoryBookmark(for: file.deletingLastPathComponent())
            let source = AlertSource(name: file.lastPathComponent, kind: .logFile)
            enqueueOperation { model in
                var updated = model.configuration
                updated.alertConfiguration.sources.append(source)
                updated.logSources[source.id] = .init(sourceID: source.id, directoryBookmark: bookmark, relativePath: file.lastPathComponent, lastResolvedPath: file.path)
                do {
                    try await model.commit(updated)
                } catch { }
            }
        } catch { }
    }

    func enabledBinding(for sourceID: UUID) -> Binding<Bool> {
        Binding(
            get: { self.sources.first(where: { $0.id == sourceID })?.enabled ?? false },
            set: { enabled in self.setSource(sourceID, enabled: enabled) }
        )
    }

    func sourceNameBinding(for sourceID: UUID) -> Binding<String> {
        Binding(
            get: { self.sources.first(where: { $0.id == sourceID })?.name ?? "" },
            set: { self.setSource(sourceID, name: $0) }
        )
    }

    func issues(for sourceID: UUID) -> [SourceIssue] { sourceIssues.filter { $0.sourceID == sourceID } }

    func deleteSource(_ sourceID: UUID) {
        enqueueOperation { model in
            var updated = model.configuration
            updated.alertConfiguration.sources.removeAll { $0.id == sourceID }
            updated.alertConfiguration.rules.removeAll { $0.sourceID == sourceID }
            updated.logSources.removeValue(forKey: sourceID)
            updated.pushSources.removeValue(forKey: sourceID)
            do {
                try await model.commit(updated)
                let credentialStore = KeychainPushCredentialStore()
                try? await credentialStore.deleteCredential(for: sourceID)
            } catch { }
        }
    }

    private func setSource(_ sourceID: UUID, enabled: Bool) {
        enqueueOperation { model in
            var updated = model.configuration
            guard let index = updated.alertConfiguration.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            updated.alertConfiguration.sources[index].enabled = enabled
            do {
                try await model.commit(updated)
            } catch { }
        }
    }

    private func setSource(_ sourceID: UUID, name: String) {
        enqueueOperation { model in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var updated = model.configuration
            guard let index = updated.alertConfiguration.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            updated.alertConfiguration.sources[index].name = name
            try? await model.commit(updated)
        }
    }

    func reauthorizeLogSource(_ sourceID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the log file inside the directory to authorize."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let bookmark = try SecurityScopedLogAccess.createDirectoryBookmark(for: file.deletingLastPathComponent())
            enqueueOperation { model in
                var updated = model.configuration
                guard var logSource = updated.logSources[sourceID] else { return }
                logSource.directoryBookmark = bookmark
                logSource.relativePath = file.lastPathComponent
                logSource.lastResolvedPath = file.path
                updated.logSources[sourceID] = logSource
                try? await model.commit(updated)
            }
        } catch { }
    }

    func copyPushEndpoint(_ sourceID: UUID) {
        copyToPasteboard("http://127.0.0.1:\(pushPort)/v1/sources/\(sourceID.uuidString)/signals")
    }

    func copyPushCredential(_ sourceID: UUID) {
        Task {
            guard let credential = try? await KeychainPushCredentialStore().credential(for: sourceID) else { return }
            await MainActor.run { self.copyToPasteboard(credential) }
        }
    }

    func copyPushCurlExample(_ sourceID: UUID) {
        Task {
            guard let credential = try? await KeychainPushCredentialStore().credential(for: sourceID) else { return }
            let endpoint = "http://127.0.0.1:\(await MainActor.run { self.pushPort })/v1/sources/\(sourceID.uuidString)/signals"
            let example = "curl --fail-with-body -X POST '\(endpoint)' -H 'Authorization: Bearer \(credential)' -H 'Content-Type: application/json' --data '{\"name\":\"example.failed\",\"message\":\"Example failure\"}'"
            await MainActor.run { self.copyToPasteboard(example) }
        }
    }

    func regeneratePushCredential(_ sourceID: UUID) {
        enqueueOperation { model in
            guard (try? await KeychainPushCredentialStore().generateAndStoreCredential(for: sourceID)) != nil else { return }
            try? await model.commit(model.configuration)
        }
    }

    func clearIssue(_ issueID: UUID) {
        enqueueOperation { model in
            guard var updated = try? await model.configurationStore.load(), let index = updated.sourceIssues.firstIndex(where: { $0.id == issueID }) else { return }
            updated.sourceIssues[index].resolved = true
            guard (try? await model.configurationStore.save(updated)) != nil else { return }
            model.configuration = updated
            model.sourceIssues = updated.sourceIssues
        }
    }

    func addRule(kind: SourceKind) {
        enqueueOperation { model in
            var updated = model.configuration
            guard let source = updated.alertConfiguration.sources.first(where: { $0.kind == kind }) else { return }
            let nextOrder = (updated.alertConfiguration.rules.filter { $0.sourceID == source.id }.map(\.order).max() ?? -1) + 1
            let matcher: RuleMatcher = kind == .logFile
                ? .log(.contains("", caseSensitive: false))
                : .push(name: nil, conditions: [])
            updated.alertConfiguration.rules.append(.init(sourceID: source.id, name: "New Rule", order: nextOrder, matcher: matcher))
            try? await model.commit(updated)
        }
    }

    func deleteRule(_ ruleID: UUID) {
        enqueueOperation { model in
            var updated = model.configuration
            updated.alertConfiguration.rules.removeAll { $0.id == ruleID }
            try? await model.commit(updated)
        }
    }

    func ruleNameBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: { self.rules.first(where: { $0.id == ruleID })?.name ?? "" },
            set: { value in self.setRule(ruleID) { rule in rule.name = value } }
        )
    }

    func ruleEnabledBinding(for ruleID: UUID) -> Binding<Bool> {
        Binding(get: { self.rules.first(where: { $0.id == ruleID })?.enabled ?? false }, set: { value in self.setRule(ruleID) { $0.enabled = value } })
    }

    func ruleSeverityBinding(for ruleID: UUID) -> Binding<Severity> {
        Binding(get: { self.rules.first(where: { $0.id == ruleID })?.severity ?? .warning }, set: { value in self.setRule(ruleID) { $0.severity = value } })
    }

    func moveRules(from offsets: IndexSet, to destination: Int) {
        enqueueOperation { model in
            var updated = model.configuration
            var reordered = updated.alertConfiguration.rules
            reordered.move(fromOffsets: offsets, toOffset: destination)
            for index in reordered.indices { reordered[index].order = index }
            updated.alertConfiguration.rules = reordered
            try? await model.commit(updated)
        }
    }

    private func setRule(_ ruleID: UUID, change: @escaping (inout Rule) -> Void) {
        enqueueOperation { model in
            var updated = model.configuration
            guard let index = updated.alertConfiguration.rules.firstIndex(where: { $0.id == ruleID }) else { return }
            change(&updated.alertConfiguration.rules[index])
            try? await model.commit(updated)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func resetToastGeometry() {
        enqueueOperation { model in
            do {
                var updated = try await model.configurationStore.load()
                updated.displayGeometries.removeAll()
                try await model.configurationStore.save(updated)
                model.configuration = updated
                model.toastGeometryReset()
            } catch { }
        }
    }

    private func enqueueOperation(_ operation: @escaping @MainActor (SettingsViewModel) async -> Void) {
        let predecessor = settingsOperationTail
        let queued = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            await operation(self)
        }
        settingsOperationTail = queued
    }

    private func commit(_ requested: StoredConfiguration) async throws {
        let latest = try await configurationStore.load()
        var updated = requested
        // Cursor/issue/geometry changes are produced by long-lived runtimes while
        // Settings is open. Preserve them when saving an unrelated edit.
        updated.displayGeometries = latest.displayGeometries
        updated.sourceIssues = latest.sourceIssues
        for id in Array(updated.logSources.keys) {
            guard var logSource = updated.logSources[id] else { continue }
            if let currentCursor = latest.logSources[id]?.cursor { logSource.cursor = currentCursor }
            updated.logSources[id] = logSource
        }
        try await configurationStore.save(updated)
        try await engine.applyConfiguration(updated.alertConfiguration)
        let reconciled = await configurationApplied(updated)
        configuration = reconciled
        collectionWindow = reconciled.settings.collectionWindow
        pushPort = reconciled.settings.pushPort
        launchAtLogin = reconciled.settings.launchAtLogin
        sources = reconciled.alertConfiguration.sources
        rules = reconciled.alertConfiguration.rules
    }
}
