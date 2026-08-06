import AppKit

@MainActor
public final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine: AlertEngine
    private let showAlerts: () -> Void
    private let showSettings: () -> Void
    private var isPaused = false
    private var hasIssues = false

    public init(engine: AlertEngine, showAlerts: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.engine = engine
        self.showAlerts = showAlerts
        self.showSettings = showSettings
        super.init()
        buildMenu()
        updateButton()
    }

    public func update(paused: Bool, hasIssues: Bool) {
        isPaused = paused
        self.hasIssues = hasIssues
        updateButton()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Running", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pause Monitoring", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(withTitle: "Show Alerts", action: #selector(showToast), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpsBeacon", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func updateButton() {
        let name: String
        if hasIssues { name = "exclamationmark.circle.fill" }
        else { name = isPaused ? "pause.circle.fill" : "waveform.path.ecg" }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: isPaused ? "OpsBeacon paused" : "OpsBeacon running")
        statusItem.menu?.items.first?.title = isPaused ? "Paused" : "Running"
        statusItem.menu?.items.first(where: { $0.action == #selector(togglePause) })?.title = isPaused ? "Resume Monitoring" : "Pause Monitoring"
    }

    @objc private func togglePause() {
        Task { [engine] in try? await engine.setMonitoringPaused(!self.isPaused) }
    }

    @objc private func showToast() { showAlerts() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
