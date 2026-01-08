import Foundation

/// Unified message from any platform
struct Message: Identifiable, Codable {
    let id: String
    let platform: Platform
    let platformMessageId: String

    // Content
    let senderName: String
    let senderHandle: String?
    let senderAvatarURL: URL?
    let subject: String?
    let content: String
    let timestamp: Date

    // Context
    let channelName: String?
    let threadId: String?

    // Classification
    var priority: Priority
    var needsResponse: Bool
    var isRead: Bool

    // AI Draft
    var draft: Draft?

    // MARK: - Priority

    enum Priority: String, Codable {
        case critical
        case high
        case medium
        case low

        var color: String {
            switch self {
            case .critical: return "#FF3B30"
            case .high: return "#FF9500"
            case .medium: return "#FFCC00"
            case .low: return "#34C759"
            }
        }
    }
}

// MARK: - Preview Data (only for SwiftUI Previews)

#if DEBUG
extension Message {
    static let sampleMessages: [Message] = [
        Message(
            id: "preview:1",
            platform: .gmail,
            platformMessageId: "preview_001",
            senderName: "Preview Sender",
            senderHandle: "preview@example.com",
            senderAvatarURL: nil,
            subject: "Preview Message",
            content: "This is a preview message for development only.",
            timestamp: Date(),
            channelName: nil,
            threadId: nil,
            priority: .medium,
            needsResponse: true,
            isRead: false,
            draft: nil
        ),
        Message(
            id: "preview:2",
            platform: .slack,
            platformMessageId: "preview_002",
            senderName: "Preview User",
            senderHandle: "@preview",
            senderAvatarURL: nil,
            subject: nil,
            content: "Another preview message for testing.",
            timestamp: Date().addingTimeInterval(-300),
            channelName: "#preview",
            threadId: nil,
            priority: .low,
            needsResponse: false,
            isRead: false,
            draft: nil
        )
    ]
}
#else
extension Message {
    static let sampleMessages: [Message] = []
}
#endif
