import Foundation
import Combine

/// Manages fetching messages from all connected platforms via MCP servers
@MainActor
class InboxManager: ObservableObject {
    static let shared = InboxManager()

    @Published var messages: [Message] = []
    @Published var isLoading: Bool = false
    @Published var lastError: Error?
    @Published var connectedPlatforms: Set<Platform> = []

    private var mcpClients: [Platform: MCPClient] = [:]
    private let settings = SettingsManager.shared

    // MARK: - Initialization

    func initialize() async {
        await connectToEnabledPlatforms()
    }

    private func connectToEnabledPlatforms() async {
        for platform in Platform.allCases {
            if settings.isPlatformEnabled(platform) {
                await connectPlatform(platform)
            }
        }
    }

    // MARK: - Platform Connection

    func connectPlatform(_ platform: Platform) async {
        guard let serverPath = mcpServerPath(for: platform) else { return }

        let client = MCPClient(
            serverPath: serverPath,
            environment: settings.environmentVariables(for: platform)
        )

        do {
            try await client.start()
            mcpClients[platform] = client
            connectedPlatforms.insert(platform)
        } catch {
            print("Failed to connect \(platform.displayName): \(error)")
        }
    }

    func disconnectPlatform(_ platform: Platform) async {
        await mcpClients[platform]?.stop()
        mcpClients.removeValue(forKey: platform)
        connectedPlatforms.remove(platform)
    }

    private func mcpServerPath(for platform: Platform) -> String? {
        let bundle = Bundle.main.bundlePath
        let basePath = URL(fileURLWithPath: bundle)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        let serverPath = "\(basePath)/mcp-servers/\(platform.rawValue)-mcp/dist/index.js"

        // Check if the server exists
        if FileManager.default.fileExists(atPath: serverPath) {
            return serverPath
        }

        // Fallback to source for development
        let srcPath = "\(basePath)/mcp-servers/\(platform.rawValue)-mcp/src/index.ts"
        if FileManager.default.fileExists(atPath: srcPath) {
            return srcPath
        }

        return nil
    }

    // MARK: - Fetching Messages

    /// Fetch all messages from all connected platforms
    func fetchAll() async throws -> [Message] {
        isLoading = true
        defer { isLoading = false }

        var allMessages: [Message] = []

        // Fetch from all connected platforms in parallel
        await withTaskGroup(of: [Message].self) { group in
            for platform in connectedPlatforms {
                group.addTask {
                    do {
                        return try await self.fetchFromPlatform(platform)
                    } catch {
                        print("Failed to fetch from \(platform.displayName): \(error)")
                        return []
                    }
                }
            }

            for await platformMessages in group {
                allMessages.append(contentsOf: platformMessages)
            }
        }

        // Sort by timestamp (newest first)
        let sorted = allMessages.sorted { $0.timestamp > $1.timestamp }
        messages = sorted
        return sorted
    }

    /// Fetch messages from a specific platform
    func fetchFromPlatform(_ platform: Platform) async throws -> [Message] {
        guard let client = mcpClients[platform] else {
            throw InboxError.notConnected(platform)
        }

        let toolName = fetchToolName(for: platform)
        let result = try await client.callTool(name: toolName, arguments: ["limit": 20])

        guard let jsonText = result.text,
              let data = jsonText.data(using: .utf8) else {
            return []
        }

        return try parseMessages(from: data, platform: platform)
    }

    private func fetchToolName(for platform: Platform) -> String {
        switch platform {
        case .gmail: return "gmail_list_unread"
        case .slack: return "slack_get_mentions"
        case .discord: return "discord_list_dms"
        case .twitter: return "twitter_get_mentions"
        case .grok: return "grok_tech_pulse"
        }
    }

    private func parseMessages(from data: Data, platform: Platform) throws -> [Message] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        switch platform {
        case .gmail:
            let emails = try decoder.decode([GmailMessage].self, from: data)
            return emails.map { $0.toMessage() }
        case .slack:
            let slackMessages = try decoder.decode([SlackMessage].self, from: data)
            return slackMessages.map { $0.toMessage() }
        case .discord:
            let discordMessages = try decoder.decode([DiscordMessage].self, from: data)
            return discordMessages.map { $0.toMessage() }
        case .twitter:
            let tweets = try decoder.decode([TwitterMessage].self, from: data)
            return tweets.map { $0.toMessage() }
        case .grok:
            let pulse = try decoder.decode(GrokPulse.self, from: data)
            return [pulse.toMessage()]
        }
    }

    // MARK: - Sending Messages

    func sendReply(to message: Message, content: String) async throws {
        guard let client = mcpClients[message.platform] else {
            throw InboxError.notConnected(message.platform)
        }

        let (toolName, args) = sendToolConfig(for: message, content: content)
        _ = try await client.callTool(name: toolName, arguments: args)
    }

    private func sendToolConfig(for message: Message, content: String) -> (String, [String: Any]) {
        switch message.platform {
        case .gmail:
            return ("gmail_send", [
                "to": message.senderHandle ?? "",
                "subject": "Re: \(message.subject ?? "")",
                "body": content,
                "threadId": message.threadId ?? ""
            ])
        case .slack:
            return ("slack_post", [
                "channel": message.channelName ?? "",
                "text": content,
                "thread_ts": message.threadId ?? ""
            ])
        case .discord:
            return ("discord_send", [
                "channelId": message.platformMessageId,
                "content": content
            ])
        case .twitter:
            return ("twitter_reply", [
                "tweetId": message.platformMessageId,
                "text": content
            ])
        case .grok:
            // Grok is info-only, no replies
            return ("", [:])
        }
    }

    // MARK: - Sample Data (Development)

    func loadSampleData() {
        messages = Message.sampleMessages
    }
}

// MARK: - Errors

enum InboxError: Error, LocalizedError {
    case notConnected(Platform)
    case fetchFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let platform):
            return "\(platform.displayName) is not connected"
        case .fetchFailed(let message):
            return "Failed to fetch messages: \(message)"
        case .sendFailed(let message):
            return "Failed to send message: \(message)"
        }
    }
}

// MARK: - Platform-Specific Message Types

private struct GmailMessage: Codable {
    let id: String
    let from: String
    let fromEmail: String?
    let subject: String
    let snippet: String
    let date: Date?
    let threadId: String?

    func toMessage() -> Message {
        Message(
            id: "gmail:\(id)",
            platform: .gmail,
            platformMessageId: id,
            senderName: from,
            senderHandle: fromEmail,
            senderAvatarURL: nil,
            subject: subject,
            content: snippet,
            timestamp: date ?? Date(),
            channelName: nil,
            threadId: threadId,
            priority: .medium,
            needsResponse: true,
            isRead: false,
            draft: nil
        )
    }
}

private struct SlackMessage: Codable {
    let ts: String
    let user: String
    let text: String
    let channel: String?
    let threadTs: String?

    func toMessage() -> Message {
        Message(
            id: "slack:\(ts)",
            platform: .slack,
            platformMessageId: ts,
            senderName: user,
            senderHandle: "@\(user)",
            senderAvatarURL: nil,
            subject: nil,
            content: text,
            timestamp: Date(timeIntervalSince1970: Double(ts.split(separator: ".").first ?? "0") ?? 0),
            channelName: channel,
            threadId: threadTs,
            priority: .medium,
            needsResponse: true,
            isRead: false,
            draft: nil
        )
    }
}

private struct DiscordMessage: Codable {
    let id: String
    let author: String
    let content: String
    let timestamp: Date?

    func toMessage() -> Message {
        Message(
            id: "discord:\(id)",
            platform: .discord,
            platformMessageId: id,
            senderName: author,
            senderHandle: nil,
            senderAvatarURL: nil,
            subject: nil,
            content: content,
            timestamp: timestamp ?? Date(),
            channelName: nil,
            threadId: nil,
            priority: .low,
            needsResponse: true,
            isRead: false,
            draft: nil
        )
    }
}

private struct TwitterMessage: Codable {
    let id: String
    let authorId: String?
    let text: String
    let createdAt: Date?

    func toMessage() -> Message {
        Message(
            id: "twitter:\(id)",
            platform: .twitter,
            platformMessageId: id,
            senderName: authorId ?? "Unknown",
            senderHandle: authorId.map { "@\($0)" },
            senderAvatarURL: nil,
            subject: nil,
            content: text,
            timestamp: createdAt ?? Date(),
            channelName: nil,
            threadId: nil,
            priority: .low,
            needsResponse: false,
            isRead: false,
            draft: nil
        )
    }
}

private struct GrokPulse: Codable {
    let type: String
    let focus: String?
    let timestamp: String?
    let pulse: String?
    let error: String?

    func toMessage() -> Message {
        let content = pulse ?? error ?? "No pulse data available"
        let timestampDate: Date
        if let ts = timestamp, let date = ISO8601DateFormatter().date(from: ts) {
            timestampDate = date
        } else {
            timestampDate = Date()
        }

        return Message(
            id: "grok:\(UUID().uuidString)",
            platform: .grok,
            platformMessageId: "pulse",
            senderName: "Grok",
            senderHandle: nil,
            senderAvatarURL: nil,
            subject: "Tech Twitter Pulse",
            content: content,
            timestamp: timestampDate,
            channelName: focus,
            threadId: nil,
            priority: .low,
            needsResponse: false,
            isRead: false,
            draft: nil
        )
    }
}
