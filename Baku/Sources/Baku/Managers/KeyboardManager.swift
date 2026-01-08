import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

/// Manages global keyboard shortcuts for Baku
@MainActor
class KeyboardManager {
    static let shared = KeyboardManager()

    private weak var viewModel: BakuViewModel?

    func setup(viewModel: BakuViewModel) {
        self.viewModel = viewModel

        // Register global shortcut handlers
        KeyboardShortcuts.onKeyUp(for: .toggleBaku) { [weak self] in
            self?.viewModel?.toggle()
        }

        KeyboardShortcuts.onKeyUp(for: .refreshInbox) { [weak self] in
            Task { @MainActor in
                await self?.viewModel?.refresh()
            }
        }
    }
}

// MARK: - Keyboard Shortcut Names

extension KeyboardShortcuts.Name {
    /// Toggle Baku window (Cmd+Shift+B)
    static let toggleBaku = Self("toggleBaku", default: .init(.b, modifiers: [.command, .shift]))

    /// Refresh inbox (Cmd+R when focused)
    static let refreshInbox = Self("refreshInbox", default: .init(.r, modifiers: [.command]))

    /// Generate all drafts (Cmd+G when focused)
    static let generateDrafts = Self("generateDrafts", default: .init(.g, modifiers: [.command]))

    /// Open settings (Cmd+,)
    static let openSettings = Self("openSettings", default: .init(.comma, modifiers: [.command]))
}
