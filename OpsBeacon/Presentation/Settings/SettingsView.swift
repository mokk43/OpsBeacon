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

    public init(configurationStore: any ConfigurationStore, engine: AlertEngine) {
        self.configurationStore = configurationStore
        self.engine = engine
    }

    public func load() {
        Task { [weak self, configurationStore] in
            guard let self else { return }
            guard let stored = try? await configurationStore.load() else { return }
            await MainActor.run {
                self.configuration = stored
                self.collectionWindow = stored.settings.collectionWindow
                self.pushPort = stored.settings.pushPort
                self.launchAtLogin = stored.settings.launchAtLogin
                self.sources = stored.alertConfiguration.sources
                self.rules = stored.alertConfiguration.rules
                self.sourceIssues = stored.sourceIssues
            }
        }
    }

    public func setConfigurationApplied(_ action: @escaping @MainActor (StoredConfiguration) async -> StoredConfiguration) {
        configurationApplied = action
    }

    public func setToastGeometryReset(_ action: @escaping @MainActor () -> Void) {
        toastGeometryReset = action
    }

    func saveGeneral() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await MainActor.run { (self.collectionWindow, self.pushPort, self.launchAtLogin, self.configuration) }
            guard (1...3_600).contains(settings.0), (1_024...65_535).contains(settings.1) else { return }
            var updated = settings.3
            updated.settings = .init(collectionWindow: settings.0, pushPort: settings.1, launchAtLogin: settings.2)
            updated.alertConfiguration.collectionWindow = settings.0
            do {
                try await MainActor.run { try LaunchAtLogin.setEnabled(settings.2) }
                try await self.commit(updated)
            } catch { }
        }
    }

    func addLocalPushSource() {
        Task { [weak self] in
            guard let self else { return }
            let source = AlertSource(name: "Local Push Source", kind: .localPush)
            let credentialStore = KeychainPushCredentialStore()
            do {
                _ = try await credentialStore.generateAndStoreCredential(for: source.id)
                var updated = await MainActor.run { self.configuration }
                updated.alertConfiguration.sources.append(source)
                updated.pushSources[source.id] = .init(sourceID: source.id, keychainReference: source.id.uuidString)
                try await self.commit(updated)
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
            Task { [weak self] in
                guard let self else { return }
                var updated = await MainActor.run { self.configuration }
                updated.alertConfiguration.sources.append(source)
                updated.logSources[source.id] = .init(sourceID: source.id, directoryBookmark: bookmark, relativePath: file.lastPathComponent, lastResolvedPath: file.path)
                do {
                    try await self.commit(updated)
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
        Task { [weak self] in
            guard let self else { return }
            var updated = await MainActor.run { self.configuration }
            updated.alertConfiguration.sources.removeAll { $0.id == sourceID }
            updated.alertConfiguration.rules.removeAll { $0.sourceID == sourceID }
            updated.logSources.removeValue(forKey: sourceID)
            updated.pushSources.removeValue(forKey: sourceID)
            do {
                try await self.commit(updated)
                let credentialStore = KeychainPushCredentialStore()
                try? await credentialStore.deleteCredential(for: sourceID)
            } catch { }
        }
    }

    private func setSource(_ sourceID: UUID, enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            var updated = await MainActor.run { self.configuration }
            guard let index = updated.alertConfiguration.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            updated.alertConfiguration.sources[index].enabled = enabled
            do {
                try await self.commit(updated)
            } catch { }
        }
    }

    private func setSource(_ sourceID: UUID, name: String) {
        Task { [weak self] in
            guard let self, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var updated = await MainActor.run { self.configuration }
            guard let index = updated.alertConfiguration.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            updated.alertConfiguration.sources[index].name = name
            try? await self.commit(updated)
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
            Task { [weak self] in
                guard let self else { return }
                var updated = await MainActor.run { self.configuration }
                guard var logSource = updated.logSources[sourceID] else { return }
                logSource.directoryBookmark = bookmark
                logSource.relativePath = file.lastPathComponent
                logSource.lastResolvedPath = file.path
                updated.logSources[sourceID] = logSource
                try? await self.commit(updated)
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
        Task { [weak self] in
            guard let self else { return }
            guard (try? await KeychainPushCredentialStore().generateAndStoreCredential(for: sourceID)) != nil else { return }
            let current = await MainActor.run { self.configuration }
            let reconciled = await self.configurationApplied(current)
            await MainActor.run { self.configuration = reconciled; self.sourceIssues = reconciled.sourceIssues }
        }
    }

    func clearIssue(_ issueID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            guard var updated = try? await configurationStore.load(), let index = updated.sourceIssues.firstIndex(where: { $0.id == issueID }) else { return }
            updated.sourceIssues[index].resolved = true
            guard (try? await configurationStore.save(updated)) != nil else { return }
            await MainActor.run { self.configuration = updated; self.sourceIssues = updated.sourceIssues }
        }
    }

    func addRule(kind: SourceKind) {
        Task { [weak self] in
            guard let self else { return }
            var updated = await MainActor.run { self.configuration }
            guard let source = updated.alertConfiguration.sources.first(where: { $0.kind == kind }) else { return }
            let nextOrder = (updated.alertConfiguration.rules.filter { $0.sourceID == source.id }.map(\.order).max() ?? -1) + 1
            let matcher: RuleMatcher = kind == .logFile
                ? .log(.contains("", caseSensitive: false))
                : .push(name: nil, conditions: [])
            updated.alertConfiguration.rules.append(.init(sourceID: source.id, name: "New Rule", order: nextOrder, matcher: matcher))
            try? await self.commit(updated)
        }
    }

    func deleteRule(_ ruleID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            var updated = await MainActor.run { self.configuration }
            updated.alertConfiguration.rules.removeAll { $0.id == ruleID }
            try? await self.commit(updated)
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
        Task { [weak self] in
            guard let self else { return }
            var updated = await MainActor.run { self.configuration }
            var reordered = updated.alertConfiguration.rules
            reordered.move(fromOffsets: offsets, toOffset: destination)
            for index in reordered.indices { reordered[index].order = index }
            updated.alertConfiguration.rules = reordered
            try? await self.commit(updated)
        }
    }

    private func setRule(_ ruleID: UUID, change: @escaping (inout Rule) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            var updated = await MainActor.run { self.configuration }
            guard let index = updated.alertConfiguration.rules.firstIndex(where: { $0.id == ruleID }) else { return }
            change(&updated.alertConfiguration.rules[index])
            try? await self.commit(updated)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func resetToastGeometry() {
        Task { [weak self] in
            guard let self else { return }
            do {
                var updated = try await configurationStore.load()
                updated.displayGeometries.removeAll()
                try await configurationStore.save(updated)
                await MainActor.run {
                    self.configuration = updated
                    self.toastGeometryReset()
                }
            } catch { }
        }
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
