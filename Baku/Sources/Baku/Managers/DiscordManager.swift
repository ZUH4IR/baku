import Foundation
import os.log

private let discordLogger = Logger(subsystem: "com.baku.app", category: "DiscordManager")

/// Manages Discord API integration using user token
@MainActor
class DiscordManager: ObservableObject {
    static let shared = DiscordManager()

    // MARK: - Published Properties

    @Published var guilds: [DiscordGuild] = []
    @Published var dmChannels: [DiscordDMChannel] = []
    @Published var isLoading: Bool = false
    @Published var error: String?

    // MARK: - API

    private let baseURL = "https://discord.com/api/v10"
    private let settings = SettingsManager.shared

    /// Fetch user's guilds (servers)
    func fetchGuilds() async throws -> [DiscordGuild] {
        guard let token = settings.getCredential(platform: .discord, key: "user_token") else {
            throw DiscordError.noToken
        }

        isLoading = true
        defer { isLoading = false }

        let url = URL(string: "\(baseURL)/users/@me/guilds")!
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscordError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw DiscordError.invalidToken
        }

        if httpResponse.statusCode != 200 {
            discordLogger.error("Discord API error: \(httpResponse.statusCode)")
            throw DiscordError.apiError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guilds = try decoder.decode([DiscordGuild].self, from: data)

        discordLogger.info("Fetched \(self.guilds.count) guilds")
        return guilds
    }

    /// Fetch user's DM channels
    func fetchDMChannels() async throws -> [DiscordDMChannel] {
        guard let token = settings.getCredential(platform: .discord, key: "user_token") else {
            throw DiscordError.noToken
        }

        isLoading = true
        defer { isLoading = false }

        let url = URL(string: "\(baseURL)/users/@me/channels")!
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscordError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw DiscordError.invalidToken
        }

        if httpResponse.statusCode != 200 {
            throw DiscordError.apiError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let channels = try decoder.decode([DiscordDMChannel].self, from: data)

        // Filter to DM and group DM channels only
        dmChannels = channels.filter { $0.type == 1 || $0.type == 3 }

        discordLogger.info("Fetched \(self.dmChannels.count) DM channels")
        return dmChannels
    }

    /// Fetch messages from selected sources
    func fetchMessages() async throws -> [Message] {
        discordLogger.info("fetchMessages() called")

        guard let token = settings.getCredential(platform: .discord, key: "user_token") else {
            discordLogger.error("No Discord user token found in keychain")
            throw DiscordError.noToken
        }

        discordLogger.info("Got Discord token (length: \(token.count))")

        isLoading = true
        defer { isLoading = false }

        var messages: [Message] = []

        // Get selected guilds and DMs
        let selectedGuildIds = settings.getDiscordSelectedGuilds()
        let selectedDMIds = settings.getDiscordSelectedDMs()
        let includeDMs = settings.discordIncludeDMs

        discordLogger.info("Selected guilds: \(selectedGuildIds.count) - IDs: \(Array(selectedGuildIds))")
        discordLogger.info("Selected DMs: \(selectedDMIds.count), Include DMs: \(includeDMs)")

        // Fetch from selected guilds
        for guildId in selectedGuildIds {
            do {
                let guildMessages = try await fetchGuildMessages(guildId: guildId, token: token)
                messages.append(contentsOf: guildMessages)
            } catch {
                discordLogger.warning("Failed to fetch from guild \(guildId): \(error.localizedDescription)")
            }
        }

        // Always fetch DMs by default (primary Discord content)
        if includeDMs {
            // Ensure we have DM channels loaded
            if dmChannels.isEmpty {
                discordLogger.info("Loading DM channels...")
                _ = try? await fetchDMChannels()
            }

            if !selectedDMIds.isEmpty {
                // Fetch from specifically selected DMs
                for dmId in selectedDMIds {
                    do {
                        let dmMessages = try await fetchChannelMessages(channelId: dmId, token: token)
                        messages.append(contentsOf: dmMessages)
                    } catch {
                        discordLogger.warning("Failed to fetch from DM \(dmId): \(error.localizedDescription)")
                    }
                }
            } else {
                // Fetch from recent DMs by default
                discordLogger.info("Fetching from \(self.dmChannels.count) recent DM channels")
                for dm in self.dmChannels.prefix(5) {
                    do {
                        let dmMessages = try await fetchChannelMessages(channelId: dm.id, token: token)
                        messages.append(contentsOf: dmMessages)
                    } catch {
                        discordLogger.warning("Failed to fetch from DM \(dm.id): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Add hint message if no servers selected
        if selectedGuildIds.isEmpty && messages.isEmpty {
            messages.append(Message(
                id: "discord:hint:\(UUID().uuidString)",
                platform: .discord,
                platformMessageId: "hint",
                senderName: "Discord",
                senderHandle: nil,
                senderAvatarURL: nil,
                subject: nil,
                content: "No servers selected. Go to Settings → Discord to select servers to monitor.",
                timestamp: Date(),
                channelName: "Setup",
                threadId: nil,
                priority: .low,
                needsResponse: false,
                isRead: false,
                draft: nil
            ))
        }

        // Sort by timestamp
        messages.sort { $0.timestamp > $1.timestamp }

        discordLogger.info("Fetched \(messages.count) total Discord messages")
        return messages
    }

    /// Fetch messages from a guild (server) - gets from channels with unread mentions
    private func fetchGuildMessages(guildId: String, token: String) async throws -> [Message] {
        discordLogger.info("Fetching channels for guild: \(guildId)")

        // Get guild channels
        let channelsURL = URL(string: "\(baseURL)/guilds/\(guildId)/channels")!
        var request = URLRequest(url: channelsURL)
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            discordLogger.error("Invalid response for guild \(guildId) channels")
            return []
        }

        if httpResponse.statusCode != 200 {
            discordLogger.error("Guild \(guildId) channels returned status \(httpResponse.statusCode)")
            if let errorText = String(data: data, encoding: .utf8) {
                discordLogger.error("Error response: \(errorText)")
            }
            return []
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let channels = try decoder.decode([DiscordChannel].self, from: data)

        // Get text channels only
        let textChannels = channels.filter { $0.type == 0 }
        discordLogger.info("Guild \(guildId): found \(channels.count) channels, \(textChannels.count) text channels")

        var messages: [Message] = []

        // Fetch from first few text channels
        for channel in textChannels.prefix(3) {
            discordLogger.info("Fetching messages from channel: \(channel.name ?? channel.id)")
            let channelMessages = try await fetchChannelMessages(channelId: channel.id, token: token, guildName: channel.name)
            discordLogger.info("Got \(channelMessages.count) messages from \(channel.name ?? channel.id)")
            messages.append(contentsOf: channelMessages)
        }

        discordLogger.info("Guild \(guildId) total messages: \(messages.count)")
        return messages
    }

    /// Fetch messages from a specific channel
    private func fetchChannelMessages(channelId: String, token: String, guildName: String? = nil) async throws -> [Message] {
        let url = URL(string: "\(baseURL)/channels/\(channelId)/messages?limit=10")!
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            discordLogger.error("Invalid response fetching messages from channel \(channelId)")
            return []
        }

        if httpResponse.statusCode != 200 {
            discordLogger.error("Channel \(channelId) messages returned status \(httpResponse.statusCode)")
            return []
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let discordMessages = try decoder.decode([DiscordAPIMessage].self, from: data)

        return discordMessages.map { msg in
            Message(
                id: "discord:\(msg.id)",
                platform: .discord,
                platformMessageId: msg.id,
                senderName: msg.author.globalName ?? msg.author.username,
                senderHandle: "@\(msg.author.username)",
                senderAvatarURL: msg.author.avatarURL,
                subject: nil,
                content: msg.content,
                timestamp: msg.timestamp,
                channelName: guildName ?? channelId,
                threadId: nil,
                priority: .low,
                needsResponse: true,
                isRead: false,
                draft: nil
            )
        }
    }

    /// Test the token by fetching user info
    func testToken(_ token: String) async throws -> DiscordUser {
        let url = URL(string: "\(baseURL)/users/@me")!
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscordError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw DiscordError.invalidToken
        }

        if httpResponse.statusCode != 200 {
            throw DiscordError.apiError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DiscordUser.self, from: data)
    }
}

// MARK: - Discord Models

struct DiscordGuild: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String?
    let owner: Bool?

    var iconURL: URL? {
        guard let icon = icon else { return nil }
        return URL(string: "https://cdn.discordapp.com/icons/\(id)/\(icon).png")
    }
}

struct DiscordDMChannel: Codable, Identifiable {
    let id: String
    let type: Int // 1 = DM, 3 = Group DM
    let recipients: [DiscordUser]?
    let name: String?

    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        if let recipients = recipients, !recipients.isEmpty {
            return recipients.map { $0.globalName ?? $0.username }.joined(separator: ", ")
        }
        return "DM"
    }
}

struct DiscordChannel: Codable, Identifiable {
    let id: String
    let name: String?
    let type: Int // 0 = text, 2 = voice, etc.
}

struct DiscordUser: Codable, Identifiable {
    let id: String
    let username: String
    let globalName: String?
    let avatar: String?
    let discriminator: String?

    var avatarURL: URL? {
        guard let avatar = avatar else { return nil }
        return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).png")
    }
}

struct DiscordAPIMessage: Codable {
    let id: String
    let content: String
    let author: DiscordUser
    let timestamp: Date
    let channelId: String

    enum CodingKeys: String, CodingKey {
        case id, content, author, timestamp
        case channelId = "channel_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        author = try container.decode(DiscordUser.self, forKey: .author)
        channelId = try container.decode(String.self, forKey: .channelId)

        // Parse Discord timestamp format
        let timestampString = try container.decode(String.self, forKey: .timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestampString) {
            timestamp = date
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            timestamp = formatter.date(from: timestampString) ?? Date()
        }
    }
}

// MARK: - Errors

enum DiscordError: Error, LocalizedError {
    case noToken
    case invalidToken
    case invalidResponse
    case apiError(Int)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No Discord token configured. Add your user token in Settings."
        case .invalidToken:
            return "Invalid Discord token. Please update it in Settings."
        case .invalidResponse:
            return "Invalid response from Discord API."
        case .apiError(let code):
            return "Discord API error: \(code)"
        }
    }
}
