import AppKit
import SwiftUI

@MainActor
final class ToastPanel: NSPanel {
    var frameDidChange: ((NSRect) -> Void)?
    var acknowledge: (() -> Void)?

    func pointerHoverChanged(_ isInside: Bool) {
        if isInside {
            makeKey()
        } else if isKeyWindow {
            resignKey()
        }
    }

    func acknowledgeIfEligible(_ event: NSEvent, mouseLocation: NSPoint) -> Bool {
        guard isVisible, frame.contains(mouseLocation), event.type == .keyDown,
              event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let acknowledge else { return false }
        // Consume repeats without acknowledging a newly displayed batch.
        if !event.isARepeat { acknowledge() }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        acknowledgeIfEligible(event, mouseLocation: NSEvent.mouseLocation)
            || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !acknowledgeIfEligible(event, mouseLocation: NSEvent.mouseLocation) {
            super.keyDown(with: event)
        }
    }

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
