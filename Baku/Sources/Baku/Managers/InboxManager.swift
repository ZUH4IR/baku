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
        inboxLogger.info("InboxManager initializing...")
        inboxLogger.info("Enabled platforms: \(self.settings.enabledPlatforms.map(\.rawValue))")
        await connectToEnabledPlatforms()
        inboxLogger.info("Connected platforms after init: \(self.connectedPlatforms.map(\.rawValue))")
    }

    private func connectToEnabledPlatforms() async {
        for platform in Platform.allCases {
            let isEnabled = settings.isPlatformEnabled(platform)
            if isEnabled {
                inboxLogger.info("Platform \(platform.displayName) is enabled, connecting...")
                await connectPlatform(platform)
            }
        }
    }

    // MARK: - Platform Connection

    func connectPlatform(_ platform: Platform) async {
        let method = settings.getConnectionMethod(for: platform)
        inboxLogger.info("connectPlatform(\(platform.displayName)) - method: \(method.displayName)")

        // Discord user token - check if token is configured
        if method == .discordUserToken {
            let hasToken = settings.getCredential(platform: .discord, key: "user_token") != nil
            inboxLogger.info("Discord user token check: hasToken=\(hasToken)")
            if hasToken {
                connectedPlatforms.insert(platform)
                inboxLogger.info("✓ Discord added to connectedPlatforms")
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

        // Tech Pulse uses Claude CLI - no MCP server needed
        if method == .techPulseClaude {
            connectedPlatforms.insert(platform)
            inboxLogger.info("Using Claude CLI for \(platform.displayName)")
            return
        }

        // Free public API platforms - connect via MCP but no credentials needed
        if !method.requiresCredentials && platform.isInfoPulse {
            // Try to start MCP server for info pulse
            inboxLogger.info("Looking for MCP server for \(platform.displayName)...")
            if let serverPath = mcpServerPath(for: platform) {
                inboxLogger.info("Found server at \(serverPath), starting client...")
                let client = MCPClient(
                    serverPath: serverPath,
                    environment: [:] // No credentials needed
                )
                do {
                    try await client.start()
                    mcpClients[platform] = client
                    connectedPlatforms.insert(platform)
                    inboxLogger.info("Connected to \(platform.displayName) via MCP (free API)")
                } catch let error as MCPError {
                    inboxLogger.error("Failed to connect \(platform.displayName): \(error.errorDescription ?? error.localizedDescription)")
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
        // Try multiple paths - development vs production
        let possibleBasePaths: [String] = [
            // Development: hardcoded project path
            "/Users/zuhair/conductor/workspaces/zuhair-helper/baku",
            // Production: relative to app bundle
            URL(fileURLWithPath: Bundle.main.bundlePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        ]

        for basePath in possibleBasePaths {
            // Only look for compiled JS - node can't run .ts directly
            let distPath = "\(basePath)/mcp-servers/\(platform.rawValue)-mcp/dist/index.js"
            if FileManager.default.fileExists(atPath: distPath) {
                inboxLogger.info("Found MCP server at: \(distPath)")
                return distPath
            }
        }

        inboxLogger.warning("MCP server not found for \(platform.rawValue)")
        return nil
    }

    // MARK: - Fetching Messages

    /// Fetch all messages from all connected platforms
    func fetchAll() async throws -> [Message] {
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        // Reconnect any newly-enabled platforms (e.g., user added Discord after app started)
        for platform in settings.enabledPlatforms {
            if !connectedPlatforms.contains(platform) {
                inboxLogger.info("Connecting newly-enabled platform: \(platform.displayName)")
                await connectPlatform(platform)
            }
        }

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

        inboxLogger.info("fetchFromPlatform: \(platform.displayName) using method: \(method.displayName)")

        // Use Discord user token if configured
        if method == .discordUserToken {
            inboxLogger.info("Calling DiscordManager.fetchMessages()")
            let messages = try await DiscordManager.shared.fetchMessages()
            inboxLogger.info("DiscordManager returned \(messages.count) messages")
            return messages
        }

        // Use desktop integration if configured
        if method.isDesktopIntegration {
            return try await fetchViaDesktop(platform: platform, method: method)
        }

        // Tech Pulse uses Claude CLI
        if method == .techPulseClaude {
            return try await fetchTechPulse()
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

    /// Fetch Tech Pulse using Claude CLI
    private func fetchTechPulse() async throws -> [Message] {
        let prompt = """
        Generate a brief tech pulse for this morning. Include:
        1. One major AI/ML development or announcement
        2. One notable tech company news
        3. One interesting open source or developer tool update

        Format as a short bulleted list. Be concise (2-3 sentences per item max).
        Only include things that would be happening around January 2025.
        """

        do {
            let response = try await ClaudeManager.shared.callClaudeForPulse(prompt: prompt)
            return [Message(
                id: "grok:\(UUID().uuidString)",
                platform: .grok,
                platformMessageId: "pulse",
                senderName: "Tech Pulse",
                senderHandle: nil,
                senderAvatarURL: nil,
                subject: "Morning Tech Briefing",
                content: response,
                timestamp: Date(),
                channelName: nil,
                threadId: nil,
                priority: .low,
                needsResponse: false,
                isRead: false,
                draft: nil
            )]
        } catch {
            inboxLogger.error("Failed to generate tech pulse: \(error.localizedDescription)")
            return [Message(
                id: "grok:\(UUID().uuidString)",
                platform: .grok,
                platformMessageId: "pulse",
                senderName: "Tech Pulse",
                senderHandle: nil,
                senderAvatarURL: nil,
                subject: "Morning Tech Briefing",
                content: "Unable to generate tech pulse. Make sure Claude Code is installed.",
                timestamp: Date(),
                channelName: nil,
                threadId: nil,
                priority: .low,
                needsResponse: false,
                isRead: false,
                draft: nil
            )]
        }
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

        info += "\nMCP CLIENTS:\n"
        for (platform, _) in mcpClients {
            info += "  • \(platform.displayName): connected\n"
        }
        if mcpClients.isEmpty {
            info += "  (none)\n"
        }

        info += "\n"
        // Use detailed diagnostics to show file contents
        info += await desktopManager.getDetailedDiagnostics()

        return info
    }

    // MARK: - Self-Debugging with Claude

    /// Use Claude CLI to diagnose why pulses aren't loading
    func debugEmptyPulses() async -> Message {
        inboxLogger.info("Starting self-debug for empty pulses")

        // Gather diagnostic info
        var diagnosticInfo = """
        === Baku Self-Diagnostic Report ===

        ENABLED INFO PULSES:
        """

        let infoPulses: [Platform] = [.grok, .markets, .news, .predictions]
        for platform in infoPulses {
            let enabled = settings.isPlatformEnabled(platform)
            let connected = connectedPlatforms.contains(platform)
            let method = settings.getConnectionMethod(for: platform)
            let hasMCP = mcpClients[platform] != nil

            diagnosticInfo += """

            \(platform.displayName):
              - Enabled: \(enabled)
              - Connected: \(connected)
              - Method: \(method.displayName)
              - MCP Client: \(hasMCP ? "yes" : "no")
            """

            // Check MCP server path for non-Claude platforms
            if platform != .grok {
                if let path = mcpServerPath(for: platform) {
                    diagnosticInfo += "\n  - Server: \(path)"
                } else {
                    diagnosticInfo += "\n  - Server: NOT FOUND"
                }
            }
        }

        // Check node availability
        let nodeCheck = checkNodeAvailability()
        diagnosticInfo += """

        NODE.JS:
          \(nodeCheck)

        LAST ERROR: \(lastErrorMessage ?? "none")
        """

        // Try to use Claude to analyze
        let prompt = """
        Analyze this diagnostic report from a macOS app that shows info pulses (Markets, News, Predictions, Tech Pulse).

        The user sees "No pulse data" in the Pulse tab. Based on this diagnostic info, explain:
        1. What's likely wrong
        2. How to fix it

        Be concise and actionable. If MCP servers aren't connecting, explain that the app needs node.js.
        If everything looks connected but no data shows, suggest refreshing.

        \(diagnosticInfo)
        """

        do {
            let analysis = try await ClaudeManager.shared.callClaudeForPulse(prompt: prompt)
            return Message(
                id: "debug:\(UUID().uuidString)",
                platform: .grok,
                platformMessageId: "debug",
                senderName: "Baku Diagnostics",
                senderHandle: nil,
                senderAvatarURL: nil,
                subject: "Why Pulses Are Empty",
                content: analysis,
                timestamp: Date(),
                channelName: nil,
                threadId: nil,
                priority: .medium,
                needsResponse: false,
                isRead: false,
                draft: nil
            )
        } catch {
            // Claude not available - return manual diagnostic
            inboxLogger.warning("Claude not available for self-debug: \(error.localizedDescription)")
            return Message(
                id: "debug:\(UUID().uuidString)",
                platform: .grok,
                platformMessageId: "debug",
                senderName: "Baku Diagnostics",
                senderHandle: nil,
                senderAvatarURL: nil,
                subject: "Pulse Connection Status",
                content: generateManualDiagnostic(diagnosticInfo),
                timestamp: Date(),
                channelName: nil,
                threadId: nil,
                priority: .medium,
                needsResponse: false,
                isRead: false,
                draft: nil
            )
        }
    }

    private func checkNodeAvailability() -> String {
        let paths = [
            "\(NSHomeDirectory())/.nvm/versions/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ]

        for path in paths {
            if path.contains("nvm") {
                if let versions = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    return "Found via nvm: \(versions.sorted().last ?? "unknown version")"
                }
            } else if FileManager.default.isExecutableFile(atPath: path) {
                return "Found at \(path)"
            }
        }
        return "NOT FOUND - install with: brew install node"
    }

    private func generateManualDiagnostic(_ info: String) -> String {
        var issues: [String] = []
        var fixes: [String] = []

        // Check for common issues
        if info.contains("MCP Client: no") && !info.contains("MCP Client: yes") {
            issues.append("MCP servers not connected")
            fixes.append("Ensure Node.js is installed (brew install node)")
        }

        if info.contains("Server: NOT FOUND") {
            issues.append("MCP server files missing")
            fixes.append("Run setup.sh to install MCP servers")
        }

        if info.contains("NODE.JS:\n  NOT FOUND") {
            issues.append("Node.js not installed")
            fixes.append("Install Node.js: brew install node")
        }

        if info.contains("Connected: false") {
            issues.append("Some platforms failed to connect")
            fixes.append("Check Console.app for detailed error logs (filter: com.baku.app)")
        }

        if issues.isEmpty {
            return """
            Everything appears configured correctly.

            Try:
            1. Click the Refresh button
            2. Quit and relaunch Baku
            3. Check Console.app for errors (subsystem: com.baku.app)

            Raw diagnostics:
            \(info)
            """
        }

        return """
        Issues Found:
        \(issues.map { "• \($0)" }.joined(separator: "\n"))

        How to Fix:
        \(fixes.map { "• \($0)" }.joined(separator: "\n"))

        After fixing, restart Baku and click Refresh.
        """
    }

    // MARK: - Auto-Fix

    /// Automatically fix common pulse issues (build MCP servers, etc.)
    func autoFixPulses(progress: @escaping (String) -> Void) async -> String {
        inboxLogger.info("Starting auto-fix for pulses")

        // Find the project root (where mcp-servers directory is)
        guard let projectPath = findProjectRoot() else {
            return "Could not find project directory"
        }

        let mcpServersPath = "\(projectPath)/mcp-servers"
        let servers = ["markets-mcp", "news-mcp", "predictions-mcp"]

        var results: [String] = []

        for server in servers {
            let serverPath = "\(mcpServersPath)/\(server)"
            let distPath = "\(serverPath)/dist/index.js"

            // Check if server directory exists
            guard FileManager.default.fileExists(atPath: serverPath) else {
                results.append("\(server): not found")
                continue
            }

            // Check if already built
            if FileManager.default.fileExists(atPath: distPath) {
                results.append("\(server): already built")
                continue
            }

            progress("Building \(server)...")

            // Run npm install && npm run build
            let buildResult = await runShellCommand(
                "cd '\(serverPath)' && npm install --silent 2>/dev/null && npm run build 2>&1"
            )

            if buildResult.success {
                results.append("\(server): built successfully")
            } else {
                results.append("\(server): build failed - \(buildResult.output.prefix(100))")
            }
        }

        // Reconnect platforms
        progress("Reconnecting platforms...")
        await reconnectInfoPulses()

        let summary = results.joined(separator: "\n")
        inboxLogger.info("Auto-fix complete: \(summary)")

        return "Fix complete:\n\(summary)"
    }

    private func findProjectRoot() -> String? {
        // Try to find the project root by looking for mcp-servers directory
        // Start from the app bundle and work up
        let bundlePath = Bundle.main.bundlePath

        // During development, the app is in DerivedData, so check common locations
        let possibleRoots = [
            // Check if there's a BAKU_PROJECT_ROOT environment variable
            ProcessInfo.processInfo.environment["BAKU_PROJECT_ROOT"],
            // Common development paths
            "\(NSHomeDirectory())/conductor/workspaces/zuhair-helper/baku",
            "\(NSHomeDirectory())/Developer/baku",
            "\(NSHomeDirectory())/Projects/baku",
            // Try to derive from bundle path (won't work for DerivedData builds)
            URL(fileURLWithPath: bundlePath).deletingLastPathComponent().deletingLastPathComponent().path
        ].compactMap { $0 }

        for root in possibleRoots {
            let mcpPath = "\(root)/mcp-servers"
            if FileManager.default.fileExists(atPath: mcpPath) {
                inboxLogger.info("Found project root: \(root)")
                return root
            }
        }

        inboxLogger.warning("Could not find project root")
        return nil
    }

    private func runShellCommand(_ command: String) async -> (success: Bool, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", command]

                // Set PATH to include nvm node
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                let nvmPath = "\(home)/.nvm/versions/node"
                if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmPath),
                   let newest = versions.sorted().last {
                    let nodeBin = "\(nvmPath)/\(newest)/bin"
                    env["PATH"] = "\(nodeBin):\(env["PATH"] ?? "/usr/bin:/bin")"
                }
                process.environment = env

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    continuation.resume(returning: (process.terminationStatus == 0, output))
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }

    private func reconnectInfoPulses() async {
        // Disconnect and reconnect info pulse platforms
        let infoPulses: [Platform] = [.markets, .news, .predictions]

        inboxLogger.info("Disconnecting \(infoPulses.count) info pulse platforms...")

        for platform in infoPulses {
            if let client = mcpClients[platform] {
                inboxLogger.info("Stopping \(platform.displayName) client...")
                await client.stop()
                mcpClients.removeValue(forKey: platform)
            }
            connectedPlatforms.remove(platform)
        }

        inboxLogger.info("Reconnecting info pulse platforms in parallel...")

        // Reconnect in parallel with timeout to avoid long hangs
        let enabledPulses = infoPulses.filter { settings.isPlatformEnabled($0) }

        await withTaskGroup(of: Void.self) { group in
            for platform in enabledPulses {
                group.addTask {
                    // Individual timeout per platform (10 seconds)
                    let connectTask = Task {
                        await self.connectPlatform(platform)
                    }

                    let timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                        connectTask.cancel()
                    }

                    await connectTask.value
                    timeoutTask.cancel()
                }
            }
        }

        inboxLogger.info("Reconnect complete. Connected: \(self.connectedPlatforms.map(\.rawValue))")
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
