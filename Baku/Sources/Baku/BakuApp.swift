import SwiftUI
import Defaults
import AppKit
import KeyboardShortcuts
import os

/// Global logger for Baku - view logs in Console.app with subsystem "com.baku.app"
let logger = Logger(subsystem: "com.baku.app", category: "general")

@main
struct BakuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindow: NotchWindow?
    var viewModel: BakuViewModel?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only app - no dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize view model - start open so users see the app
        viewModel = BakuViewModel()
        viewModel?.notchState = .open

        // Create and show floating window
        setupNotchWindow()

        // Setup menubar status item
        setupStatusItem()

        // Setup keyboard shortcuts
        setupKeyboardShortcuts()

        logger.info("Baku launched successfully")
    }

    // MARK: - Window Setup

    private func setupNotchWindow() {
        // Prevent duplicate windows
        guard notchWindow == nil else {
            logger.warning("NotchWindow already exists, skipping creation")
            return
        }

        guard let screen = NSScreen.main else {
            logger.error("No main screen available")
            return
        }

        notchWindow = NotchWindow(
            contentRect: NotchWindow.initialFrame(for: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        guard let window = notchWindow, let vm = viewModel else { return }

        let contentView = ContentView(viewModel: vm)
        window.contentView = NSHostingView(rootView: contentView)
        window.orderFrontRegardless()

        logger.info("NotchWindow created and displayed")
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: "Baku")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            // Show context menu
            showStatusMenu()
        } else {
            // Toggle window
            Task { @MainActor in
                viewModel?.toggle()
                notchWindow?.orderFrontRegardless()
            }
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Open Baku", action: #selector(openBaku), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshInbox), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Baku", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openBaku() {
        Task { @MainActor in
            viewModel?.open()
            notchWindow?.orderFrontRegardless()
        }
    }

    @objc private func refreshInbox() {
        Task { @MainActor in
            await viewModel?.refresh()
        }
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleBaku) { [weak self] in
            Task { @MainActor in
                self?.viewModel?.toggle()
                self?.notchWindow?.orderFrontRegardless()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .refreshInbox) { [weak self] in
            Task { @MainActor in
                await self?.viewModel?.refresh()
            }
        }
    }

    // MARK: - Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        notchWindow?.close()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // For accessory apps, this is rarely called, but handle it gracefully
        if !flag {
            Task { @MainActor in
                viewModel?.open()
                notchWindow?.orderFrontRegardless()
            }
        }
        return false
    }
}
