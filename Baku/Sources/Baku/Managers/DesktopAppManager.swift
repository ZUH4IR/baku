import Foundation
import AppKit

/// Manages integration with macOS desktop apps via AppleScript
actor DesktopAppManager {
    static let shared = DesktopAppManager()

    // MARK: - App Detection

    /// Check if an app is running
    func isAppRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    /// Check if Mail.app is running
    var isMailRunning: Bool {
        isAppRunning("com.apple.mail")
    }

    /// Check if Slack is running
    var isSlackRunning: Bool {
        isAppRunning("com.tinyspeck.slackmacgap")
    }

    /// Check if Discord is running
    var isDiscordRunning: Bool {
        isAppRunning("com.hnc.Discord")
    }

    // MARK: - Mail.app Integration

    /// Fetch unread emails from Mail.app
    func fetchMailUnread() async throws -> [Message] {
        let script = """
        tell application "Mail"
            set unreadMessages to {}
            set inboxMailbox to inbox
            set msgs to (messages of inboxMailbox whose read status is false)

            repeat with msg in msgs
                set msgId to id of msg
                set msgSubject to subject of msg
                set msgSender to sender of msg
                set msgContent to content of msg
                set msgDate to date received of msg

                set end of unreadMessages to {|id|:msgId, |subject|:msgSubject, |sender|:msgSender, |content|:msgContent, |date|:msgDate}
            end repeat

            return unreadMessages
        end tell
        """

        let result = try await runAppleScript(script)
        return parseMailMessages(result)
    }

    /// Send a reply via Mail.app
    func sendMailReply(to originalId: String, content: String) async throws {
        let escapedContent = content.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Mail"
            set originalMsg to message id \(originalId) of inbox
            set replyMsg to reply originalMsg with opening window
            set content of replyMsg to "\(escapedContent)"
            send replyMsg
        end tell
        """

        _ = try await runAppleScript(script)
    }

    private func parseMailMessages(_ result: Any?) -> [Message] {
        guard let records = result as? [[String: Any]] else { return [] }

        return records.compactMap { record -> Message? in
            guard let id = record["id"] as? Int,
                  let subject = record["subject"] as? String,
                  let sender = record["sender"] as? String else {
                return nil
            }

            let content = record["content"] as? String ?? ""
            let date = record["date"] as? Date ?? Date()

            // Parse sender name from "Name <email>" format
            let senderName = extractName(from: sender)
            let senderHandle = extractEmail(from: sender)

            return Message(
                id: "mail:\(id)",
                platform: .gmail,
                senderName: senderName,
                senderHandle: senderHandle,
                subject: subject,
                content: content.prefix(500).description,
                timestamp: date,
                isRead: false,
                needsResponse: true,
                priority: .medium
            )
        }
    }

    // MARK: - Slack Integration

    /// Fetch unread Slack messages (limited without API)
    func fetchSlackUnread() async throws -> [Message] {
        // Slack doesn't expose much via AppleScript
        // This is a stub - real implementation would need Slack API

        // Check if Slack is running
        guard isSlackRunning else {
            throw DesktopAppError.appNotRunning("Slack")
        }

        // We can at least get notification count via Dock badge
        let badgeCount = try await getSlackBadgeCount()

        if badgeCount > 0 {
            // Return a placeholder indicating unread messages
            return [Message(
                id: "slack:unread",
                platform: .slack,
                senderName: "Slack",
                senderHandle: nil,
                subject: nil,
                channelName: nil,
                content: "You have \(badgeCount) unread message\(badgeCount == 1 ? "" : "s") in Slack",
                timestamp: Date(),
                isRead: false,
                needsResponse: false,
                priority: .medium
            )]
        }

        return []
    }

    private func getSlackBadgeCount() async throws -> Int {
        let script = """
        tell application "System Events"
            tell process "Slack"
                try
                    set badgeValue to value of attribute "AXStatusLabel" of (first UI element of list 1 of group 1 of group 1)
                    return badgeValue as integer
                on error
                    return 0
                end try
            end tell
        end tell
        """

        let result = try await runAppleScript(script)
        return result as? Int ?? 0
    }

    // MARK: - Discord Integration

    /// Fetch Discord notifications (limited without API)
    func fetchDiscordUnread() async throws -> [Message] {
        guard isDiscordRunning else {
            throw DesktopAppError.appNotRunning("Discord")
        }

        // Discord is even more limited via AppleScript
        // Return empty for now - real implementation needs Discord API or RPC

        return []
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ script: String) async throws -> Any? {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                let result = appleScript?.executeAndReturnError(&error)

                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    continuation.resume(throwing: DesktopAppError.scriptError(message))
                    return
                }

                // Convert AppleScript result to Swift types
                let converted = self.convertAppleScriptResult(result)
                continuation.resume(returning: converted)
            }
        }
    }

    private func convertAppleScriptResult(_ descriptor: NSAppleEventDescriptor?) -> Any? {
        guard let descriptor = descriptor else { return nil }

        switch descriptor.descriptorType {
        case typeAEList:
            var array: [Any] = []
            for i in 1...descriptor.numberOfItems {
                if let item = convertAppleScriptResult(descriptor.atIndex(i)) {
                    array.append(item)
                }
            }
            return array

        case typeAERecord:
            var dict: [String: Any] = [:]
            for i in 1...descriptor.numberOfItems {
                let key = descriptor.keywordForDescriptor(at: i)
                if key != 0, let value = convertAppleScriptResult(descriptor.atIndex(i)) {
                    // Convert four-char code to string key
                    let keyString = String(format: "%c%c%c%c",
                                          (key >> 24) & 0xFF,
                                          (key >> 16) & 0xFF,
                                          (key >> 8) & 0xFF,
                                          key & 0xFF)
                    dict[keyString] = value
                }
            }
            return dict

        case typeUnicodeText, typeUTF8Text:
            return descriptor.stringValue

        case typeSInt32, typeSInt64:
            return descriptor.int32Value

        case typeIEEE64BitFloatingPoint:
            return descriptor.doubleValue

        case typeBoolean:
            return descriptor.booleanValue

        case typeLongDateTime:
            return descriptor.dateValue

        default:
            return descriptor.stringValue
        }
    }

    // MARK: - Helpers

    private func extractName(from sender: String) -> String {
        // "John Doe <john@example.com>" -> "John Doe"
        if let angleIndex = sender.firstIndex(of: "<") {
            return String(sender[..<angleIndex]).trimmingCharacters(in: .whitespaces)
        }
        return sender
    }

    private func extractEmail(from sender: String) -> String? {
        // "John Doe <john@example.com>" -> "john@example.com"
        guard let start = sender.firstIndex(of: "<"),
              let end = sender.firstIndex(of: ">") else {
            return sender.contains("@") ? sender : nil
        }
        return String(sender[sender.index(after: start)..<end])
    }
}

// MARK: - Errors

enum DesktopAppError: Error, LocalizedError {
    case appNotRunning(String)
    case scriptError(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let app):
            return "\(app) is not running. Please open \(app) and try again."
        case .scriptError(let message):
            return "AppleScript error: \(message)"
        case .permissionDenied:
            return "Baku needs permission to control other apps. Enable in System Settings > Privacy & Security > Automation."
        }
    }
}
