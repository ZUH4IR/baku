import AppKit
import SwiftUI

/// Floating panel window - can be moved anywhere on screen
class NotchWindow: NSPanel {

    // MARK: - Size Constants

    static let openSize = CGSize(width: 640, height: 400)
    static let closedSize = CGSize(width: 200, height: 44)

    // MARK: - Initialization

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        configureWindow()
    }

    private func configureWindow() {
        // Window behavior - normal window that can go behind others
        isFloatingPanel = false
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Appearance
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Make it movable by dragging anywhere
        isMovable = true
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true

        // Don't hide when app loses focus
        hidesOnDeactivate = false
        canHide = false
    }

    // MARK: - Frame Calculations

    /// Initial frame - centered on screen
    static func initialFrame(for screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - openSize.width / 2
        let y = screen.frame.midY - openSize.height / 2 + 100 // Slightly above center

        return NSRect(x: x, y: y, width: openSize.width, height: openSize.height)
    }

    /// Closed frame - keep current position, just resize
    static func closedFrame(for screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - closedSize.width / 2
        let y = screen.frame.midY + 100

        return NSRect(x: x, y: y, width: closedSize.width, height: closedSize.height)
    }

    // MARK: - State Transitions

    func transitionToOpen(animated: Bool = true) {
        let currentOrigin = frame.origin
        let targetFrame = NSRect(
            x: currentOrigin.x - (Self.openSize.width - frame.width) / 2,
            y: currentOrigin.y - (Self.openSize.height - frame.height),
            width: Self.openSize.width,
            height: Self.openSize.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(targetFrame, display: true)
            }
        } else {
            setFrame(targetFrame, display: true)
        }
    }

    func transitionToClosed(animated: Bool = true) {
        let currentOrigin = frame.origin
        let targetFrame = NSRect(
            x: currentOrigin.x + (frame.width - Self.closedSize.width) / 2,
            y: currentOrigin.y + (frame.height - Self.closedSize.height),
            width: Self.closedSize.width,
            height: Self.closedSize.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().setFrame(targetFrame, display: true)
            }
        } else {
            setFrame(targetFrame, display: true)
        }
    }
}
