import AppKit
import SwiftUI

@MainActor
final class ToastPanel: NSPanel {
    var frameDidChange: ((NSRect) -> Void)?

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        minSize = .init(width: 320, height: 180)
        NotificationCenter.default.addObserver(self, selector: #selector(reportFrame), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(reportFrame), name: NSWindow.didResizeNotification, object: self)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var canBecomeKey: Bool { true }

    @objc private func reportFrame() { frameDidChange?(frame) }
}
