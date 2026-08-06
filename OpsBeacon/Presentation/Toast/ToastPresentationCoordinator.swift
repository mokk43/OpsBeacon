import AppKit
import CoreGraphics
import SwiftUI

@MainActor
public final class ToastPresentationCoordinator {
    private let engine: AlertEngine
    private let configurationStore: any ConfigurationStore
    private var panels: [CGDirectDisplayID: ToastPanel] = [:]
    private var geometryByDisplayUUID: [String: DisplayGeometry] = [:]
    private var latestSnapshot = AlertSnapshot(state: .init())
    private var observation: Task<Void, Never>?
    private var geometryPersistence: Task<Void, Never>?

    public init(engine: AlertEngine, configurationStore: any ConfigurationStore) {
        self.engine = engine
        self.configurationStore = configurationStore
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        observation?.cancel()
        geometryPersistence?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public func start() {
        observation?.cancel()
        observation = Task { [weak self, engine, configurationStore] in
            let stored = try? await configurationStore.load()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.geometryByDisplayUUID = stored?.displayGeometries ?? [:]
            }
            let stream = await engine.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.apply(snapshot) }
            }
        }
    }

    public func showAlerts() {
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    public func resetGeometry() {
        geometryByDisplayUUID.removeAll()
        geometryPersistence?.cancel()
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        apply(latestSnapshot)
    }

    @objc private func screensChanged() { apply(latestSnapshot) }

    private func apply(_ snapshot: AlertSnapshot) {
        latestSnapshot = snapshot
        guard !snapshot.displayedAlerts.isEmpty else {
            panels.values.forEach { $0.orderOut(nil) }
            return
        }
        let active = activeScreens()
        let wanted = Set(active.map(\.id))
        let removed = panels.keys.filter { !wanted.contains($0) }
        for id in removed {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
        }
        for screen in active {
            let restored = geometryByDisplayUUID[screen.uuid]?.frame ?? DisplayGeometryMath.defaultFrame(in: screen.visibleFrame)
            let panel = panels[screen.id] ?? ToastPanel(frame: restored)
            panel.frameDidChange = { [weak self, id = screen.id, uuid = screen.uuid, visibleFrame = screen.visibleFrame] frame in
                self?.remember(frame: frame, for: id, uuid: uuid, visibleFrame: visibleFrame)
            }
            panel.contentView = NSHostingView(rootView: ToastView(snapshot: snapshot, acknowledge: { [weak self] in self?.acknowledge() }))
            panel.setFrame(DisplayGeometryMath.clamped(panel.frame, into: screen.visibleFrame), display: true)
            if panels[screen.id] == nil {
                panels[screen.id] = panel
            }
            panel.orderFrontRegardless()
        }
    }

    private func acknowledge() {
        Task { [engine] in try? await engine.acknowledgeDisplayed() }
    }

    private func remember(frame: CGRect, for id: CGDirectDisplayID, uuid: String, visibleFrame: CGRect) {
        guard panels[id] != nil else { return }
        geometryByDisplayUUID[uuid] = .init(displayUUID: uuid, lastVisibleFrame: visibleFrame, frame: frame)
        persistGeometry()
    }

    private func persistGeometry() {
        geometryPersistence?.cancel()
        let geometry = geometryByDisplayUUID
        let configurationStore = configurationStore
        geometryPersistence = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                var stored = try await configurationStore.load()
                stored.displayGeometries = geometry
                try await configurationStore.save(stored)
            } catch {
                // Geometry persistence is best effort; Toast delivery remains active.
            }
        }
    }

    private func activeScreens() -> [(id: CGDirectDisplayID, uuid: String, visibleFrame: CGRect)] {
        NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, uuid: String, visibleFrame: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0 else { return nil }
            // The primary display represents a mirror set. A secondary copy
            // would overlap the same physical image and duplicate the Toast.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            guard let displayUUID = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
            return (id, CFUUIDCreateString(nil, displayUUID.takeRetainedValue()) as String, screen.visibleFrame)
        }
    }
}
