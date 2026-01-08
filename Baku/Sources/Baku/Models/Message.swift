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

// MARK: - Sample Data

extension Message {
    static let sampleMessages: [Message] = [
        Message(
            id: "gmail:1",
            platform: .gmail,
            platformMessageId: "msg_001",
            senderName: "John Smith",
            senderHandle: "john@company.com",
            senderAvatarURL: nil,
            subject: "Re: Q1 Planning Meeting",
            content: "Can you review the budget proposal and let me know your thoughts by EOD?",
            timestamp: Date().addingTimeInterval(-120), // 2 min ago
            channelName: nil,
            threadId: "thread_001",
            priority: .high,
            needsResponse: true,
            isRead: false,
            draft: Draft(
                content: "Hi John, I'll review the budget proposal and get back to you by end of day. Thanks for sending it over.",
                tone: .professional,
                generatedAt: Date()
            )
        ),
        Message(
            id: "slack:1",
            platform: .slack,
            platformMessageId: "msg_002",
            senderName: "Sarah Chen",
            senderHandle: "@sarah",
            senderAvatarURL: nil,
            subject: nil,
            content: "Hey, quick question about the API integration - are we still planning to use the v2 endpoints?",
            timestamp: Date().addingTimeInterval(-900), // 15 min ago
            channelName: "#engineering",
            threadId: nil,
            priority: .medium,
            needsResponse: true,
            isRead: false,
            draft: nil
        ),
        Message(
            id: "discord:1",
            platform: .discord,
            platformMessageId: "msg_003",
            senderName: "GameDev Mike",
            senderHandle: "mike#1234",
            senderAvatarURL: nil,
            subject: nil,
            content: "Are we still on for the gaming session tonight?",
            timestamp: Date().addingTimeInterval(-3600), // 1 hour ago
            channelName: nil,
            threadId: nil,
            priority: .low,
            needsResponse: true,
            isRead: false,
            draft: nil
        ),
        Message(
            id: "twitter:1",
            platform: .twitter,
            platformMessageId: "msg_004",
            senderName: "Tech News",
            senderHandle: "@technews",
            senderAvatarURL: nil,
            subject: nil,
            content: "Thanks for the follow! Check out our latest article on AI trends.",
            timestamp: Date().addingTimeInterval(-7200), // 2 hours ago
            channelName: nil,
            threadId: nil,
            priority: .low,
            needsResponse: false,
            isRead: true,
            draft: nil
        )
    ]
}
