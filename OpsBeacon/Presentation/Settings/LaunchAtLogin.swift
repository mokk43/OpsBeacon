import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    static var requiresUserApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}
