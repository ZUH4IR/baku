import Foundation
import AppKit
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.baku.app", category: "DesktopAppManager")

/// Manages integration with macOS desktop apps via AppleScript and local cache reading
actor DesktopAppManager {
    static let shared = DesktopAppManager()

    // MARK: - Local Cache Paths

    private let home = FileManager.default.homeDirectoryForCurrentUser

    // Slack paths - try multiple locations
    private var slackCachePaths: [URL] {
        [
            home.appendingPathComponent("Library/Application Support/Slack"),
            home.appendingPathComponent("Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack")
        ]
    }

    // Discord paths - try multiple variations (capitalization varies)
    private var discordCachePaths: [URL] {
        [
            home.appendingPathComponent("Library/Application Support/Discord"),
            home.appendingPathComponent("Library/Application Support/discord"),
            home.appendingPathComponent("Library/Application Support/DiscordCanary"),
            home.appendingPathComponent("Library/Application Support/discordcanary"),
            home.appendingPathComponent("Library/Application Support/DiscordPTB"),
            home.appendingPathComponent("Library/Application Support/discordptb")
        ]
    }

    private var iMessageDBPath: URL {
        home.appendingPathComponent("Library/Messages/chat.db")
    }

    // MARK: - Debug Info

    /// Get diagnostic info about what paths exist
    func getDiagnosticInfo() -> String {
        var info = "=== Desktop Integration Diagnostics ===\n\n"

        // Slack
        info += "SLACK:\n"
        info += "  Running: \(isSlackRunning)\n"
        for path in slackCachePaths {
            let exists = FileManager.default.fileExists(atPath: path.path)
            info += "  \(exists ? "✓" : "✗") \(path.path)\n"
        }

        // Discord
        info += "\nDISCORD:\n"
        info += "  Running: \(isDiscordRunning)\n"
        for path in discordCachePaths {
            let exists = FileManager.default.fileExists(atPath: path.path)
            info += "  \(exists ? "✓" : "✗") \(path.path)\n"
        }

        // Discord cache variants
        info += "\nDISCORD CACHE DB:\n"
        for variant in ["com.hnc.Discord", "com.hnc.DiscordCanary", "com.hnc.DiscordPTB"] {
            let cachePath = home.appendingPathComponent("Library/Caches/\(variant)/Cache.db")
            let exists = FileManager.default.fileExists(atPath: cachePath.path)
            info += "  \(exists ? "✓" : "✗") \(cachePath.path)\n"
        }

        // iMessage
        info += "\niMESSAGE:\n"
        let imessageExists = FileManager.default.fileExists(atPath: iMessageDBPath.path)
        info += "  \(imessageExists ? "✓" : "✗") \(iMessageDBPath.path)\n"

        return info
    }

    /// Print diagnostic info to console log
    func logDiagnostics() {
        let info = getDiagnosticInfo()
        logger.info("\(info)")
        print(info) // Also print to stdout for Xcode console
    }

    /// Find first existing path from a list
    private func findExistingPath(from paths: [URL]) -> URL? {
        paths.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - App Detection

    /// Check if an app is running
    func isAppRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    /// Check if an app is installed (has local data)
    func isAppInstalled(_ app: DesktopApp) -> Bool {
        switch app {
        case .slack:
            return findExistingPath(from: slackCachePaths) != nil
        case .discord:
            return findExistingPath(from: discordCachePaths) != nil
        case .iMessage:
            return FileManager.default.fileExists(atPath: iMessageDBPath.path)
        case .mail:
            return true // Mail.app is always available on macOS
        }
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
        isAppRunning("com.hnc.Discord") || isAppRunning("com.hnc.DiscordCanary")
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
                platformMessageId: String(id),
                senderName: senderName,
                senderHandle: senderHandle,
                senderAvatarURL: nil,
                subject: subject,
                content: content.prefix(500).description,
                timestamp: date,
                channelName: nil,
                threadId: nil,
                priority: .medium,
                needsResponse: true,
                isRead: false,
                draft: nil
            )
        }
    }

    // MARK: - Slack Integration (Local Cache)

    /// Fetch recent Slack messages from local cache (no API needed)
    func fetchSlackUnread() async throws -> [Message] {
        logger.info("Fetching Slack messages...")

        // Find Slack's cache directory
        guard let slackPath = findExistingPath(from: slackCachePaths) else {
            logger.warning("No Slack cache found. Paths checked: \(slackCachePaths.map(\.path))")

            // If Slack is running, try badge count
            if isSlackRunning {
                logger.info("Slack is running, trying badge count...")
                let badgeCount = try await getSlackBadgeCount()
                if badgeCount > 0 {
                    return [Message(
                        id: "slack:unread",
                        platform: .slack,
                        platformMessageId: "badge",
                        senderName: "Slack",
                        senderHandle: nil,
                        senderAvatarURL: nil,
                        subject: nil,
                        content: "You have \(badgeCount) unread message\(badgeCount == 1 ? "" : "s"). Open Slack to see details.",
                        timestamp: Date(),
                        channelName: nil,
                        threadId: nil,
                        priority: .medium,
                        needsResponse: true,
                        isRead: false,
                        draft: nil
                    )]
                }
            }

            throw DesktopAppError.appNotInstalled("Slack")
        }

        logger.info("Found Slack cache at: \(slackPath.path)")

        // Try to read from local cache
        let cachedMessages = try? readSlackLocalCache(from: slackPath)
        if let messages = cachedMessages, !messages.isEmpty {
            logger.info("Found \(messages.count) Slack messages in cache")
            return messages
        }

        logger.info("No messages in cache, checking badge count...")

        // Fallback to badge count
        if isSlackRunning {
            let badgeCount = try await getSlackBadgeCount()
            logger.info("Slack badge count: \(badgeCount)")

            if badgeCount > 0 {
                return [Message(
                    id: "slack:unread",
                    platform: .slack,
                    platformMessageId: "badge",
                    senderName: "Slack",
                    senderHandle: nil,
                    senderAvatarURL: nil,
                    subject: nil,
                    content: "You have \(badgeCount) unread message\(badgeCount == 1 ? "" : "s"). Open Slack to see details.",
                    timestamp: Date(),
                    channelName: nil,
                    threadId: nil,
                    priority: .medium,
                    needsResponse: true,
                    isRead: false,
                    draft: nil
                )]
            }
        }

        logger.info("No Slack messages found")
        return []
    }

    /// Read Slack's local JSON cache files
    private func readSlackLocalCache(from basePath: URL) throws -> [Message] {
        var messages: [Message] = []

        logger.info("Reading Slack cache from: \(basePath.path)")

        // Try multiple possible cache structures

        // 1. Try root-state.json for workspace/user context
        let rootStatePath = basePath.appendingPathComponent("storage/root-state.json")
        if FileManager.default.fileExists(atPath: rootStatePath.path) {
            logger.info("Found root-state.json")
            if let rootStateData = try? Data(contentsOf: rootStatePath),
               let rootState = try? JSONSerialization.jsonObject(with: rootStateData) as? [String: Any] {

                // Parse workspaces and recent messages from cache
                if let teams = rootState["teams"] as? [String: Any] {
                    logger.info("Found \(teams.count) teams in cache")
                    for (teamId, teamData) in teams {
                        guard let team = teamData as? [String: Any],
                              let teamName = team["name"] as? String else { continue }

                        // Read team-specific local storage
                        let teamStoragePath = basePath.appendingPathComponent("storage/\(teamId)")
                        if let teamMessages = readSlackTeamMessages(from: teamStoragePath, teamName: teamName) {
                            messages.append(contentsOf: teamMessages)
                        }
                    }
                }
            }
        }

        // 2. Try local-settings.json for recent activity
        let localSettingsPath = basePath.appendingPathComponent("local-settings.json")
        if FileManager.default.fileExists(atPath: localSettingsPath.path) {
            logger.info("Found local-settings.json")
            if let settingsData = try? Data(contentsOf: localSettingsPath),
               let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any] {

                // Extract recent channel activity
                if let recentChannels = settings["recentChannels"] as? [[String: Any]] {
                    for channel in recentChannels.prefix(10) {
                        if let channelName = channel["name"] as? String,
                           let hasUnread = channel["hasUnread"] as? Bool,
                           hasUnread {
                            messages.append(Message(
                                id: "slack:channel:\(channelName)",
                                platform: .slack,
                                platformMessageId: channelName,
                                senderName: "Slack",
                                senderHandle: nil,
                                senderAvatarURL: nil,
                                subject: nil,
                                content: "Unread messages in #\(channelName)",
                                timestamp: Date(),
                                channelName: channelName,
                                threadId: nil,
                                priority: .medium,
                                needsResponse: true,
                                isRead: false,
                                draft: nil
                            ))
                        }
                    }
                }
            }
        }

        // 3. Try IndexedDB files
        let indexedDBPath = basePath.appendingPathComponent("IndexedDB")
        if FileManager.default.fileExists(atPath: indexedDBPath.path) {
            logger.info("Found IndexedDB directory - Slack uses encrypted storage, limited access")
        }

        // 4. Check for notification count in storage
        let storagePath = basePath.appendingPathComponent("storage")
        if FileManager.default.fileExists(atPath: storagePath.path) {
            logger.info("Found storage directory at: \(storagePath.path)")
            // List contents for debugging
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: storagePath.path) {
                logger.info("Storage contents: \(contents.prefix(10))")
            }
        }

        return messages
    }

    private func readSlackTeamMessages(from path: URL, teamName: String) -> [Message]? {
        // Slack stores IndexedDB data - we'll extract what we can from JSON files
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        var messages: [Message] = []

        // Look for conversation cache files
        let fileManager = FileManager.default
        if let enumerator = fileManager.enumerator(at: path, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "json" && fileURL.lastPathComponent.contains("message") {
                    if let data = try? Data(contentsOf: fileURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let text = json["text"] as? String,
                       let user = json["user"] as? String {

                        let ts = json["ts"] as? String ?? ""
                        let timestamp = Double(ts.split(separator: ".").first ?? "0") ?? 0

                        messages.append(Message(
                            id: "slack:\(ts)",
                            platform: .slack,
                            platformMessageId: ts,
                            senderName: user,
                            senderHandle: "@\(user)",
                            senderAvatarURL: nil,
                            subject: nil,
                            content: text,
                            timestamp: Date(timeIntervalSince1970: timestamp),
                            channelName: teamName,
                            threadId: json["thread_ts"] as? String,
                            priority: .medium,
                            needsResponse: true,
                            isRead: false,
                            draft: nil
                        ))
                    }
                }
            }
        }

        return messages.isEmpty ? nil : messages
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

    // MARK: - Discord Integration (Local Cache)

    /// Fetch recent Discord messages from local cache (no API needed)
    func fetchDiscordUnread() async throws -> [Message] {
        logger.info("Fetching Discord messages...")

        // Find Discord's cache directory
        guard let discordPath = findExistingPath(from: discordCachePaths) else {
            logger.warning("No Discord cache found. Paths checked: \(discordCachePaths.map(\.path))")
            throw DesktopAppError.appNotInstalled("Discord")
        }

        logger.info("Found Discord cache at: \(discordPath.path)")

        // Try to read from local cache
        let cachedMessages = try? readDiscordLocalCache(from: discordPath)
        if let messages = cachedMessages, !messages.isEmpty {
            logger.info("Found \(messages.count) Discord messages in cache")
            return messages
        }

        // Also check other Discord variants (Canary, PTB)
        for otherPath in discordCachePaths where otherPath != discordPath {
            if FileManager.default.fileExists(atPath: otherPath.path) {
                logger.info("Also checking: \(otherPath.path)")
                if let messages = try? readDiscordLocalCache(from: otherPath), !messages.isEmpty {
                    logger.info("Found \(messages.count) messages in \(otherPath.lastPathComponent)")
                    return messages
                }
            }
        }

        logger.info("No Discord messages found in cache")
        return []
    }

    /// Read Discord's local storage files
    private func readDiscordLocalCache(from basePath: URL) throws -> [Message] {
        var messages: [Message] = []

        logger.info("Reading Discord cache from: \(basePath.path)")

        // Check what's in this directory
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath.path) {
            logger.info("Discord directory contents: \(contents.prefix(10))")
        }

        // Read local storage for recent DMs and mentions
        let localStoragePath = basePath.appendingPathComponent("Local Storage/leveldb")
        if FileManager.default.fileExists(atPath: localStoragePath.path) {
            logger.info("Found LevelDB at: \(localStoragePath.path)")
            if let localMessages = readDiscordLevelDB(at: localStoragePath) {
                logger.info("Extracted \(localMessages.count) messages from LevelDB")
                messages.append(contentsOf: localMessages)
            }
        } else {
            logger.info("No LevelDB found at: \(localStoragePath.path)")
        }

        // Read settings for user info and recent activity
        let settingsPath = basePath.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            logger.info("Found settings.json")
            if let data = try? Data(contentsOf: settingsPath),
               let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Extract recent guild/server info
                if let recentGuilds = settings["RECENT_GUILDS"] as? [String] {
                    logger.info("Found \(recentGuilds.count) recent guilds")
                    for guildId in recentGuilds.prefix(5) {
                        messages.append(Message(
                            id: "discord:guild:\(guildId)",
                            platform: .discord,
                            platformMessageId: guildId,
                            senderName: "Discord",
                            senderHandle: nil,
                            senderAvatarURL: nil,
                            subject: nil,
                            content: "Recent activity in server",
                            timestamp: Date(),
                            channelName: guildId,
                            threadId: nil,
                            priority: .low,
                            needsResponse: false,
                            isRead: false,
                            draft: nil
                        ))
                    }
                }
            }
        } else {
            logger.info("No settings.json found at: \(settingsPath.path)")
        }

        // Read from Cache.db (SQLite HTTP cache) - check multiple variants
        let cacheVariants = [
            "com.hnc.Discord",
            "com.hnc.DiscordCanary",
            "com.hnc.DiscordPTB"
        ]

        for variant in cacheVariants {
            let cacheDBPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/\(variant)/Cache.db")

            if FileManager.default.fileExists(atPath: cacheDBPath.path) {
                logger.info("Found Discord cache DB at: \(cacheDBPath.path)")
                if let cacheMessages = readDiscordCacheDB(at: cacheDBPath) {
                    messages.append(contentsOf: cacheMessages)
                    break // Found messages, stop searching
                }
            }
        }

        return messages
    }

    /// Read Discord's LevelDB local storage (basic extraction)
    private func readDiscordLevelDB(at path: URL) -> [Message]? {
        // LevelDB is complex - we'll look for .log files which contain recent writes
        var messages: [Message] = []

        let fileManager = FileManager.default
        if let enumerator = fileManager.enumerator(at: path, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "log" {
                    // LevelDB log files contain key-value pairs with recent data
                    if let data = try? Data(contentsOf: fileURL) {
                        // Look for JSON patterns in the binary data
                        let extracted = extractJSONFromBinary(data)
                        for json in extracted {
                            if let content = json["content"] as? String,
                               let author = json["author"] as? [String: Any],
                               let username = author["username"] as? String {

                                let messageId = json["id"] as? String ?? UUID().uuidString
                                let timestamp = parseDiscordTimestamp(json["timestamp"] as? String)

                                messages.append(Message(
                                    id: "discord:\(messageId)",
                                    platform: .discord,
                                    platformMessageId: messageId,
                                    senderName: username,
                                    senderHandle: author["discriminator"] as? String,
                                    senderAvatarURL: nil,
                                    subject: nil,
                                    content: content,
                                    timestamp: timestamp,
                                    channelName: json["channel_id"] as? String,
                                    threadId: nil,
                                    priority: .low,
                                    needsResponse: true,
                                    isRead: false,
                                    draft: nil
                                ))
                            }
                        }
                    }
                }
            }
        }

        return messages.isEmpty ? nil : messages
    }

    /// Read Discord's HTTP cache SQLite database
    private func readDiscordCacheDB(at path: URL) -> [Message]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        var messages: [Message] = []

        // Query for cached API responses that might contain messages
        let query = """
            SELECT response_data FROM cfurl_cache_response
            WHERE request_key LIKE '%/messages%'
            ORDER BY time_stamp DESC
            LIMIT 50
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let size = sqlite3_column_bytes(stmt, 0)
                let data = Data(bytes: blob, count: Int(size))

                // Try to parse as JSON
                if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for json in jsonArray {
                        if let content = json["content"] as? String,
                           let author = json["author"] as? [String: Any],
                           let username = author["username"] as? String {

                            let messageId = json["id"] as? String ?? UUID().uuidString

                            messages.append(Message(
                                id: "discord:\(messageId)",
                                platform: .discord,
                                platformMessageId: messageId,
                                senderName: username,
                                senderHandle: nil,
                                senderAvatarURL: nil,
                                subject: nil,
                                content: content,
                                timestamp: parseDiscordTimestamp(json["timestamp"] as? String),
                                channelName: json["channel_id"] as? String,
                                threadId: nil,
                                priority: .low,
                                needsResponse: true,
                                isRead: false,
                                draft: nil
                            ))
                        }
                    }
                }
            }
        }

        return messages.isEmpty ? nil : messages
    }

    /// Extract JSON objects from binary data (for LevelDB)
    private func extractJSONFromBinary(_ data: Data) -> [[String: Any]] {
        var results: [[String: Any]] = []

        // Look for JSON object patterns in binary data
        guard let string = String(data: data, encoding: .utf8) else { return [] }

        // Find JSON objects that look like Discord messages
        let pattern = #"\{"id":"[0-9]+","type":[0-9]+,"content":"[^"]*","channel_id":"[0-9]+""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(string.startIndex..., in: string)
        let matches = regex.matches(in: string, range: range)

        for match in matches.prefix(20) {
            if let matchRange = Range(match.range, in: string) {
                // Try to find the complete JSON object
                let startIndex = matchRange.lowerBound
                var braceCount = 0
                var endIndex = startIndex

                for idx in string[startIndex...].indices {
                    let char = string[idx]
                    if char == "{" { braceCount += 1 }
                    if char == "}" { braceCount -= 1 }
                    if braceCount == 0 {
                        endIndex = string.index(after: idx)
                        break
                    }
                }

                let jsonString = String(string[startIndex..<endIndex])
                if let jsonData = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    results.append(json)
                }
            }
        }

        return results
    }

    private func parseDiscordTimestamp(_ ts: String?) -> Date {
        guard let ts = ts else { return Date() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: ts) ?? Date()
    }

    // MARK: - iMessage Integration (Local Database)

    /// Fetch recent iMessages from local SQLite database
    /// Note: Requires Full Disk Access permission
    func fetchIMessageUnread() async throws -> [Message] {
        guard FileManager.default.fileExists(atPath: iMessageDBPath.path) else {
            throw DesktopAppError.appNotRunning("Messages")
        }

        return try readIMessageDatabase()
    }

    /// Read from iMessage's chat.db SQLite database
    private func readIMessageDatabase() throws -> [Message] {
        var db: OpaquePointer?

        // Open database in read-only mode
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(iMessageDBPath.path, &db, flags, nil) == SQLITE_OK else {
            throw DesktopAppError.permissionDenied
        }
        defer { sqlite3_close(db) }

        var messages: [Message] = []

        // Query for recent messages from the last 7 days
        // Join message, chat, and handle tables to get full context
        let query = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date / 1000000000 + 978307200 as timestamp,
                m.is_from_me,
                m.is_read,
                h.id as sender_id,
                COALESCE(h.uncanonicalized_id, h.id) as sender_display,
                c.display_name as chat_name,
                c.chat_identifier
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.text IS NOT NULL
                AND m.text != ''
                AND m.is_from_me = 0
                AND m.date / 1000000000 + 978307200 > strftime('%s', 'now') - 604800
            ORDER BY m.date DESC
            LIMIT 50
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw DesktopAppError.scriptError("SQLite error: \(errorMsg)")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let guid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let timestamp = sqlite3_column_double(stmt, 3)
            let isRead = sqlite3_column_int(stmt, 5) != 0
            let senderId = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let senderDisplay = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let chatName = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let chatIdentifier = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

            // Determine sender name
            let senderName = chatName ?? senderDisplay ?? senderId ?? "Unknown"

            // Determine if this is a group chat
            let isGroup = chatIdentifier?.contains("chat") ?? false

            messages.append(Message(
                id: "imessage:\(rowId)",
                platform: .imessage,
                platformMessageId: guid,
                senderName: senderName,
                senderHandle: senderId,
                senderAvatarURL: nil,
                subject: isGroup ? chatName : nil,
                content: text,
                timestamp: Date(timeIntervalSince1970: timestamp),
                channelName: isGroup ? chatName : nil,
                threadId: chatIdentifier,
                priority: .medium,
                needsResponse: !isRead,
                isRead: isRead,
                draft: nil
            ))
        }

        return messages
    }

    /// Send a message via iMessage using AppleScript
    func sendIMessage(to recipient: String, content: String) async throws {
        let escapedContent = content.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRecipient = recipient.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(escapedRecipient)" of targetService
            send "\(escapedContent)" to targetBuddy
        end tell
        """

        _ = try await runAppleScript(script)
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

// MARK: - Desktop App Types

enum DesktopApp {
    case slack
    case discord
    case iMessage
    case mail
}

// MARK: - Errors

enum DesktopAppError: Error, LocalizedError {
    case appNotRunning(String)
    case appNotInstalled(String)
    case scriptError(String)
    case permissionDenied
    case fullDiskAccessRequired

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let app):
            return "\(app) is not running. Please open \(app) and try again."
        case .appNotInstalled(let app):
            return "\(app) is not installed or has no local data."
        case .scriptError(let message):
            return "Script error: \(message)"
        case .permissionDenied:
            return "Baku needs permission to control other apps. Enable in System Settings > Privacy & Security > Automation."
        case .fullDiskAccessRequired:
            return "Full Disk Access required to read iMessage history. Enable in System Settings > Privacy & Security > Full Disk Access."
        }
    }
}
