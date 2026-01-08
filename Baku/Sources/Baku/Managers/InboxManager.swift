import Foundation
import Combine
import os.log

private let inboxLogger = Logger(subsystem: "com.baku.app", category: "InboxManager")

/// Manages fetching messages from all connected platforms
@MainActor
class InboxManager: ObservableObject {
    static let shared = InboxManager()

    @Published var messages: [Message] = []
    @Published var isLoading: Bool = false
    @Published var lastError: Error?
    @Published var lastErrorMessage: String?
    @Published var connectedPlatforms: Set<Platform> = []

    private var mcpClients: [Platform: MCPClient] = [:]
    private let settings = SettingsManager.shared
    private let desktopManager = DesktopAppManager.shared

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
        let method = settings.getConnectionMethod(for: platform)

        // Discord user token - check if token is configured
        if method == .discordUserToken {
            if settings.getCredential(platform: .discord, key: "user_token") != nil {
                connectedPlatforms.insert(platform)
                inboxLogger.info("Using Discord user token for \(platform.displayName)")
            } else {
                inboxLogger.warning("Discord user token not configured")
            }
            return
        }

        // Desktop integrations don't need MCP connection
        if method.isDesktopIntegration {
            connectedPlatforms.insert(platform)
            inboxLogger.info("Using desktop integration for \(platform.displayName)")
            return
        }

        // Free public API platforms - connect via MCP but no credentials needed
        if !method.requiresCredentials && platform.isInfoPulse {
            // Try to start MCP server for info pulse
            if let serverPath = mcpServerPath(for: platform) {
                let client = MCPClient(
                    serverPath: serverPath,
                    environment: [:] // No credentials needed
                )
                do {
                    try await client.start()
                    mcpClients[platform] = client
                    connectedPlatforms.insert(platform)
                    inboxLogger.info("Connected to \(platform.displayName) via MCP (free API)")
                } catch {
                    inboxLogger.error("Failed to connect \(platform.displayName): \(error.localizedDescription)")
                }
            } else {
                inboxLogger.warning("No MCP server found for \(platform.displayName)")
            }
            return
        }

        // MCP server connection (requires credentials)
        guard let serverPath = mcpServerPath(for: platform) else {
            inboxLogger.warning("No MCP server found for \(platform.displayName)")
            return
        }

        let client = MCPClient(
            serverPath: serverPath,
            environment: settings.environmentVariables(for: platform)
        )

        do {
            try await client.start()
            mcpClients[platform] = client
            connectedPlatforms.insert(platform)
            inboxLogger.info("Connected to \(platform.displayName) via MCP")
        } catch {
            inboxLogger.error("Failed to connect \(platform.displayName): \(error.localizedDescription)")
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

        if FileManager.default.fileExists(atPath: serverPath) {
            return serverPath
        }

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
        lastErrorMessage = nil
        defer { isLoading = false }

        var allMessages: [Message] = []
        var errors: [String] = []

        inboxLogger.info("Fetching from \(self.connectedPlatforms.count) platforms: \(self.connectedPlatforms.map(\.rawValue))")

        // Log diagnostics before fetch
        await desktopManager.logDiagnostics()

        // Fetch from all connected platforms in parallel
        await withTaskGroup(of: (Platform, Result<[Message], Error>).self) { group in
            for platform in connectedPlatforms {
                group.addTask {
                    do {
                        inboxLogger.info("Fetching from \(platform.displayName)...")
                        let messages = try await self.fetchFromPlatform(platform)
                        inboxLogger.info("Got \(messages.count) messages from \(platform.displayName)")
                        return (platform, .success(messages))
                    } catch {
                        inboxLogger.error("Failed to fetch from \(platform.displayName): \(error.localizedDescription)")
                        return (platform, .failure(error))
                    }
                }
            }

            for await (platform, result) in group {
                switch result {
                case .success(let msgs):
                    allMessages.append(contentsOf: msgs)
                case .failure(let error):
                    errors.append("\(platform.displayName): \(error.localizedDescription)")
                }
            }
        }

        // Store error summary for UI display
        if !errors.isEmpty {
            lastErrorMessage = errors.joined(separator: "\n")
            inboxLogger.warning("Errors during fetch: \(errors)")
        }

        // Sort by timestamp (newest first)
        let sorted = allMessages.sorted { $0.timestamp > $1.timestamp }
        messages = sorted
        inboxLogger.info("Total messages fetched: \(sorted.count)")
        return sorted
    }

    /// Fetch messages from a specific platform
    func fetchFromPlatform(_ platform: Platform) async throws -> [Message] {
        let method = settings.getConnectionMethod(for: platform)

        // Use Discord user token if configured
        if method == .discordUserToken {
            return try await DiscordManager.shared.fetchMessages()
        }

        // Use desktop integration if configured
        if method.isDesktopIntegration {
            return try await fetchViaDesktop(platform: platform, method: method)
        }

        // Use MCP server
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

    /// Fetch via desktop app integration
    private func fetchViaDesktop(platform: Platform, method: ConnectionMethod) async throws -> [Message] {
        switch method {
        case .gmailMailApp:
            return try await desktopManager.fetchMailUnread()
        case .slackDesktop:
            return try await desktopManager.fetchSlackUnread()
        case .discordDesktop:
            return try await desktopManager.fetchDiscordUnread()
        case .imessageLocal:
            return try await desktopManager.fetchIMessageUnread()
        default:
            return []
        }
    }

    private func fetchToolName(for platform: Platform) -> String {
        switch platform {
        case .gmail: return "gmail_list_unread"
        case .slack: return "slack_get_mentions"
        case .discord: return "discord_list_dms"
        case .imessage: return "imessage_list_recent" // Desktop integration only
        case .twitter: return "twitter_get_mentions"
        case .grok: return "grok_tech_pulse"
        case .markets: return "markets_pulse"
        case .news: return "news_pulse"
        case .predictions: return "predictions_pulse"
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
        case .imessage:
            // iMessage is desktop-only, handled by fetchViaDesktop
            return []
        case .twitter:
            let tweets = try decoder.decode([TwitterMessage].self, from: data)
            return tweets.map { $0.toMessage() }
        case .grok:
            let pulse = try decoder.decode(GrokPulse.self, from: data)
            return [pulse.toMessage()]
        case .markets:
            let pulse = try decoder.decode(MarketsPulse.self, from: data)
            return [pulse.toMessage()]
        case .news:
            let pulse = try decoder.decode(NewsPulse.self, from: data)
            return [pulse.toMessage()]
        case .predictions:
            let pulse = try decoder.decode(PredictionsPulse.self, from: data)
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
        case .imessage:
            // iMessage sends via AppleScript, handled separately
            return ("imessage_send", [
                "recipient": message.senderHandle ?? "",
                "content": content
            ])
        case .twitter:
            return ("twitter_reply", [
                "tweetId": message.platformMessageId,
                "text": content
            ])
        case .grok, .markets, .news, .predictions:
            // Info pulses are read-only, no replies
            return ("", [:])
        }
    }

    // MARK: - Sample Data (Development)

    func loadSampleData() {
        messages = Message.sampleMessages
    }

    // MARK: - Diagnostics

    /// Get diagnostic info about platform connections
    func getDiagnostics() async -> String {
        var info = "=== Inbox Manager Diagnostics ===\n\n"

        info += "CONNECTED PLATFORMS:\n"
        for platform in connectedPlatforms {
            let method = settings.getConnectionMethod(for: platform)
            info += "  • \(platform.displayName) via \(method.displayName)\n"
        }

        if connectedPlatforms.isEmpty {
            info += "  (none)\n"
        }

        info += "\nENABLED PLATFORMS:\n"
        for platform in Platform.allCases where settings.isPlatformEnabled(platform) {
            info += "  • \(platform.displayName)\n"
        }

        info += "\n"
        // Use detailed diagnostics to show file contents
        info += await desktopManager.getDetailedDiagnostics()

        return info
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

private struct MarketsPulse: Codable {
    let type: String
    let timestamp: String?
    let summary: String?
    let error: String?

    func toMessage() -> Message {
        let content = summary ?? error ?? "No market data available"
        let timestampDate: Date
        if let ts = timestamp, let date = ISO8601DateFormatter().date(from: ts) {
            timestampDate = date
        } else {
            timestampDate = Date()
        }

        return Message(
            id: "markets:\(UUID().uuidString)",
            platform: .markets,
            platformMessageId: "pulse",
            senderName: "Markets",
            senderHandle: nil,
            senderAvatarURL: nil,
            subject: "Markets Snapshot",
            content: content,
            timestamp: timestampDate,
            channelName: nil,
            threadId: nil,
            priority: .low,
            needsResponse: false,
            isRead: false,
            draft: nil
        )
    }
}

private struct NewsPulse: Codable {
    let type: String
    let timestamp: String?
    let topHeadlines: [NewsHeadline]?
    let error: String?

    struct NewsHeadline: Codable {
        let title: String
        let source: String?
        let time: String?
    }

    func toMessage() -> Message {
        let content: String
        if let headlines = topHeadlines, !headlines.isEmpty {
            content = headlines.prefix(5).map { "• \($0.title)" }.joined(separator: "\n")
        } else {
            content = error ?? "No news available"
        }

        let timestampDate: Date
        if let ts = timestamp, let date = ISO8601DateFormatter().date(from: ts) {
            timestampDate = date
        } else {
            timestampDate = Date()
        }

        return Message(
            id: "news:\(UUID().uuidString)",
            platform: .news,
            platformMessageId: "pulse",
            senderName: "News",
            senderHandle: nil,
            senderAvatarURL: nil,
            subject: "Tech Headlines",
            content: content,
            timestamp: timestampDate,
            channelName: nil,
            threadId: nil,
            priority: .low,
            needsResponse: false,
            isRead: false,
            draft: nil
        )
    }
}

private struct PredictionsPulse: Codable {
    let type: String
    let timestamp: String?
    let summary: String?
    let markets: [PredictionMarket]?
    let error: String?

    struct PredictionMarket: Codable {
        let title: String
        let volume: String?
        let topOutcome: String?
    }

    func toMessage() -> Message {
        let content: String
        if let markets = markets, !markets.isEmpty {
            content = markets.prefix(5).map { m in
                "• \(m.title): \(m.topOutcome ?? "N/A")"
            }.joined(separator: "\n")
        } else if let summary = summary {
            content = summary
        } else {
            content = error ?? "No prediction data available"
        }

        let timestampDate: Date
        if let ts = timestamp, let date = ISO8601DateFormatter().date(from: ts) {
            timestampDate = date
        } else {
            timestampDate = Date()
        }

        return Message(
            id: "predictions:\(UUID().uuidString)",
            platform: .predictions,
            platformMessageId: "pulse",
            senderName: "Polymarket",
            senderHandle: nil,
            senderAvatarURL: nil,
            subject: "Prediction Markets",
            content: content,
            timestamp: timestampDate,
            channelName: nil,
            threadId: nil,
            priority: .low,
            needsResponse: false,
            isRead: false,
            draft: nil
        )
    }
}
