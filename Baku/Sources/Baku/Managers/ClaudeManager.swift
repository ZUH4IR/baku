import Foundation
import os

private let claudeLogger = Logger(subsystem: "com.baku.app", category: "claude")

/// Manages communication with Claude via the claude CLI
@MainActor
class ClaudeManager: ObservableObject {
    static let shared = ClaudeManager()

    @Published var isGenerating: Bool = false
    @Published var lastError: Error?

    // Self-healing agent state
    @Published var isRepairing: Bool = false
    @Published var repairOutput: String = ""
    @Published var currentAction: String = ""  // Current tool/action being performed
    @Published var lastRepairResult: RepairResult?

    private let settings = SettingsManager.shared
    private var agentProcess: Process?

    /// Path to claude CLI - checks common install locations
    private var claudePath: String? {
        let home = NSHomeDirectory()

        // Check nvm versions FIRST (most common for claude-code)
        let nvmVersionsPath = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsPath) {
            for version in versions.sorted().reversed() { // Check newest versions first
                let claudeInNvm = "\(nvmVersionsPath)/\(version)/bin/claude"
                // Check both isExecutableFile and fileExists (symlinks can be tricky)
                if FileManager.default.isExecutableFile(atPath: claudeInNvm) ||
                   FileManager.default.fileExists(atPath: claudeInNvm) {
                    claudeLogger.info("Found Claude CLI via nvm: \(claudeInNvm)")
                    return claudeInNvm
                }
            }
        }

        // Fallback paths
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude"
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                claudeLogger.info("Found Claude CLI at: \(path)")
                return path
            }
        }

        claudeLogger.warning("Claude CLI not found. Checked nvm at \(nvmVersionsPath) and standard paths")
        return nil
    }

    /// Find node executable path - needed to set PATH for claude CLI
    private var nodeBinPath: String? {
        let home = NSHomeDirectory()

        // Check nvm versions FIRST
        let nvmVersionsPath = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsPath) {
            for version in versions.sorted().reversed() {
                let nodeBin = "\(nvmVersionsPath)/\(version)/bin"
                let nodePath = "\(nodeBin)/node"
                if FileManager.default.isExecutableFile(atPath: nodePath) ||
                   FileManager.default.fileExists(atPath: nodePath) {
                    return nodeBin
                }
            }
        }

        // Homebrew
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/node") {
            return "/opt/homebrew/bin"
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/node") {
            return "/usr/local/bin"
        }

        return nil
    }

    /// Build environment with PATH including node
    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Add node bin directory to PATH so `env node` works
        if let nodeBin = nodeBinPath {
            let currentPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(nodeBin):\(currentPath)"
            claudeLogger.info("Added \(nodeBin) to PATH")
        }

        return env
    }

    // MARK: - Draft Generation

    /// Generate a response draft for a message
    func generateDraft(for message: Message, tone: Draft.Tone = .professional) async throws -> Draft {
        isGenerating = true
        defer { isGenerating = false }

        let prompt = buildPrompt(for: message, tone: tone)

        do {
            let response = try await callClaudeAPI(prompt: prompt)
            return Draft(
                content: response,
                tone: tone,
                generatedAt: Date()
            )
        } catch {
            lastError = error
            throw error
        }
    }

    /// Generate drafts for multiple messages in parallel
    func generateDrafts(for messages: [Message]) async -> [String: Draft] {
        var drafts: [String: Draft] = [:]

        await withTaskGroup(of: (String, Draft?).self) { group in
            for message in messages where message.needsResponse && message.draft == nil {
                group.addTask {
                    let draft = try? await self.generateDraft(for: message)
                    return (message.id, draft)
                }
            }

            for await (id, draft) in group {
                if let draft = draft {
                    drafts[id] = draft
                }
            }
        }

        return drafts
    }

    /// Prioritize messages by urgency using Claude
    func prioritizeMessages(_ messages: [Message]) async throws -> [Message] {
        guard !messages.isEmpty else { return [] }

        let prompt = buildPrioritizationPrompt(for: messages)
        let response = try await callClaudeAPI(prompt: prompt)

        // Parse the response to get priority order
        return parsePrioritizedMessages(response: response, original: messages)
    }

    // MARK: - Prompt Building

    private func buildPrompt(for message: Message, tone: Draft.Tone) -> String {
        let toneGuide = toneGuidance(for: tone)
        let platformGuide = platformGuidance(for: message.platform)

        return """
        Generate a response to this message.

        Platform: \(message.platform.displayName)
        \(platformGuide)

        Sender: \(message.senderName)\(message.senderHandle.map { " (\($0))" } ?? "")
        \(message.channelName.map { "Channel: \($0)" } ?? "")
        \(message.subject.map { "Subject: \($0)" } ?? "")

        Message:
        \(message.content)

        Tone: \(tone.displayName)
        \(toneGuide)

        Generate ONLY the response text, no explanations or meta-commentary. Keep it concise.
        """
    }

    private func buildPrioritizationPrompt(for messages: [Message]) -> String {
        var prompt = """
        Analyze these messages and return them ordered by urgency/priority.
        Consider: time sensitivity, sender importance, action required.

        Messages:
        """

        for (index, message) in messages.enumerated() {
            prompt += """

            [\(index)] Platform: \(message.platform.displayName)
            From: \(message.senderName)
            Content: \(message.content.prefix(200))
            Time: \(message.timestamp)
            """
        }

        prompt += """

        Return ONLY a comma-separated list of indices in priority order (highest first).
        Example: 2,0,3,1
        """

        return prompt
    }

    private func toneGuidance(for tone: Draft.Tone) -> String {
        switch tone {
        case .professional:
            return "Write in a professional, business-appropriate tone. Be clear and concise."
        case .casual:
            return "Write in a casual, friendly tone. Be conversational but still helpful."
        case .friendly:
            return "Write in a warm, personable tone. Show genuine interest and care."
        case .brief:
            return "Keep it very short and to the point. Just the essential information."
        }
    }

    private func platformGuidance(for platform: Platform) -> String {
        switch platform {
        case .gmail:
            return "This is an email. Include appropriate greeting and sign-off."
        case .slack:
            return "This is a Slack message. Keep it concise. Emoji are acceptable."
        case .discord:
            return "This is a Discord message. Can be casual and playful."
        case .twitter:
            return "This is a Twitter DM. Keep it brief (under 280 chars if possible)."
        case .imessage:
            return "This is an iMessage. Keep it casual and conversational."
        case .grok:
            return "This is a tech pulse summary. Focus on key insights and trends."
        case .markets:
            return "This is market data. Focus on key numbers and trends."
        case .news:
            return "This is a news summary. Be factual and concise."
        case .predictions:
            return "This is a prediction market update. Focus on probability changes."
        }
    }

    // MARK: - Public API for Info Pulses

    /// Call Claude for generating info pulse content
    func callClaudeForPulse(prompt: String) async throws -> String {
        return try await callClaudeAPI(prompt: prompt)
    }

    // MARK: - Chat Interface

    /// Chat with Claude about the app, debugging, or anything
    func chat(message: String) async throws -> String {
        // Build context about the app state for debugging
        let context = await buildAppContext()

        let prompt = """
        You are the assistant for Baku, a macOS notch-based unified inbox app.
        You have full context about the app's current state and can help debug issues.

        APP STATE:
        \(context)

        USER MESSAGE:
        \(message)

        INSTRUCTIONS:
        - If the user asks about debugging or why something isn't working, analyze the app state above
        - Be concise but helpful
        - For technical questions about the app, reference the state data
        - For general questions (math, facts, etc), just answer directly
        - Don't repeat the app state back unless relevant
        """

        return try await callClaudeAPI(prompt: prompt)
    }

    /// Build context about the app's current state for debugging
    private func buildAppContext() async -> String {
        let inboxManager = InboxManager.shared
        let settingsManager = SettingsManager.shared

        var context = """
        CONNECTED PLATFORMS: \(inboxManager.connectedPlatforms.map(\.displayName).joined(separator: ", "))
        ENABLED PLATFORMS: \(settingsManager.enabledPlatforms.map(\.displayName).joined(separator: ", "))

        PLATFORM STATUS:
        """

        for platform in Platform.allCases {
            let isEnabled = settingsManager.isPlatformEnabled(platform)
            let isConnected = inboxManager.connectedPlatforms.contains(platform)
            let method = settingsManager.getConnectionMethod(for: platform)

            var status = "  \(platform.displayName): "
            status += isEnabled ? "enabled" : "disabled"
            if isEnabled {
                status += ", \(isConnected ? "connected" : "NOT CONNECTED")"
                status += ", method: \(method.displayName)"

                // Check for credentials if needed
                if method.requiresCredentials {
                    let hasCredentials = method.credentialFields.allSatisfy { field in
                        settingsManager.getCredential(platform: platform, key: field.key) != nil
                    }
                    status += hasCredentials ? ", credentials: ✓" : ", credentials: MISSING"
                }
            }
            context += "\n\(status)"
        }

        // Discord specific
        if settingsManager.isPlatformEnabled(.discord) {
            let hasToken = settingsManager.getCredential(platform: .discord, key: "user_token") != nil
            let selectedGuilds = settingsManager.discordSelectedGuilds.count
            let includeDMs = settingsManager.discordIncludeDMs

            context += """

            DISCORD DETAILS:
              Token: \(hasToken ? "✓ configured" : "✗ not configured")
              Selected servers: \(selectedGuilds)
              Include DMs: \(includeDMs)
            """
        }

        context += """

        MESSAGE COUNTS:
          Total messages: \(inboxManager.messages.count)
          Inbox (non-pulse): \(inboxManager.messages.filter { !$0.platform.isInfoPulse }.count)
          Pulse: \(inboxManager.messages.filter { $0.platform.isInfoPulse }.count)

        LAST ERROR: \(inboxManager.lastErrorMessage ?? "none")
        """

        return context
    }

    // MARK: - Claude CLI Communication

    private func callClaudeAPI(prompt: String) async throws -> String {
        // Try to use claude CLI first (uses existing authentication)
        if let path = claudePath {
            claudeLogger.info("Found Claude CLI at: \(path)")
            return try await callClaudeCLI(path: path, prompt: prompt)
        }

        claudeLogger.warning("Claude CLI not found, checking for API key...")

        // Fall back to direct API if CLI not found but API key is available
        if let apiKey = settings.getCredential(platform: .gmail, key: "claude_api_key")
                ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            claudeLogger.info("Using direct API with key")
            return try await callClaudeDirectAPI(apiKey: apiKey, prompt: prompt)
        }

        claudeLogger.warning("No Claude CLI or API key found, using simulated response")
        // No claude CLI and no API key - return simulated response for development
        return await simulatedResponse(for: prompt)
    }

    /// Call claude CLI with prompt - uses existing authentication
    private func callClaudeCLI(path: String, prompt: String) async throws -> String {
        claudeLogger.info("Calling Claude CLI...")
        let env = buildEnvironment()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["-p", prompt, "--output-format", "text"]
                process.environment = env

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    claudeLogger.info("Claude CLI process started, waiting...")
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    claudeLogger.info("Claude CLI exited with status \(process.terminationStatus), output length: \(output.count)")

                    if process.terminationStatus == 0 && !output.isEmpty {
                        continuation.resume(returning: output)
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        claudeLogger.error("Claude CLI error: \(errorOutput)")
                        continuation.resume(throwing: ClaudeError.cliError(message: errorOutput))
                    }
                } catch {
                    claudeLogger.error("Claude CLI failed to run: \(error.localizedDescription)")
                    continuation.resume(throwing: ClaudeError.cliError(message: error.localizedDescription))
                }
            }
        }
    }

    /// Direct API call as fallback
    private func callClaudeDirectAPI(apiKey: String, prompt: String) async throws -> String {
        let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw ClaudeError.invalidResponse
        }

        return text
    }

    // MARK: - Response Parsing

    private func parsePrioritizedMessages(response: String, original: [Message]) -> [Message] {
        // Parse comma-separated indices
        let indices = response.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 >= 0 && $0 < original.count }

        // Build prioritized list
        var result: [Message] = []
        var used = Set<Int>()

        for index in indices {
            if !used.contains(index) {
                var message = original[index]
                // Update priority based on position
                if result.count < 2 {
                    message.priority = .high
                } else if result.count < 5 {
                    message.priority = .medium
                }
                result.append(message)
                used.insert(index)
            }
        }

        // Add any remaining messages
        for (index, message) in original.enumerated() {
            if !used.contains(index) {
                result.append(message)
            }
        }

        return result
    }

    // MARK: - Development Simulation

    private func simulatedResponse(for prompt: String) async -> String {
        // Simulate API delay
        try? await Task.sleep(nanoseconds: 800_000_000)

        if prompt.contains("tech pulse") || prompt.contains("Tech Pulse") || prompt.contains("AI/ML") {
            return """
            Claude CLI not installed. To enable Tech Pulse:

            1. Install Claude Code: npm install -g @anthropic-ai/claude-code
            2. Run 'claude' once to authenticate
            3. Refresh to see your personalized tech briefing
            """
        } else if prompt.contains("Gmail") || prompt.contains("email") {
            return """
            Hi,

            Thanks for reaching out. I've reviewed your message and will get back to you with a detailed response shortly.

            Best regards
            """
        } else if prompt.contains("Slack") {
            return "Thanks for the heads up! I'll take a look and get back to you shortly."
        } else if prompt.contains("Discord") {
            return "Hey! Yeah, sounds good. Let me check my schedule and I'll confirm."
        } else if prompt.contains("Twitter") {
            return "Thanks for reaching out! I'll get back to you soon."
        } else if prompt.contains("priority") || prompt.contains("urgency") {
            return "0,1,2,3" // Default order
        } else {
            return "Thanks for your message! I'll respond properly soon."
        }
    }

    // MARK: - Self-Healing Agent

    /// Repair a Swift build error using Claude Agent
    func repairBuildError(_ error: String, projectPath: String? = nil) async throws -> RepairResult {
        guard let path = claudePath else {
            throw ClaudeError.noCLI
        }

        isRepairing = true
        repairOutput = ""
        claudeLogger.info("Starting self-healing repair for error")

        defer { isRepairing = false }

        let workingDir = projectPath ?? FileManager.default.currentDirectoryPath
        let prompt = buildRepairPrompt(error: error)
        var env = buildEnvironment()
        env["FORCE_COLOR"] = "0"

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = [
                    "--print",
                    "--output-format", "stream-json",
                    "--dangerously-skip-permissions",
                    "--allowedTools", "Read,Edit,Glob,Grep,Bash",
                    "--max-turns", "15",
                    prompt
                ]
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
                process.environment = env

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                self?.agentProcess = process

                // Stream JSON output and parse for status updates
                var lineBuffer = ""
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        lineBuffer += str

                        // Process complete JSON lines
                        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                            let line = String(lineBuffer[..<newlineIndex])
                            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])

                            self?.parseStreamLine(line)
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    outputPipe.fileHandleForReading.readabilityHandler = nil

                    let output = self?.repairOutput ?? ""
                    let success = process.terminationStatus == 0

                    DispatchQueue.main.async {
                        let result = RepairResult(
                            success: success,
                            output: output,
                            filesChanged: self?.parseChangedFiles(from: output) ?? [],
                            timestamp: Date()
                        )
                        self?.lastRepairResult = result
                        self?.agentProcess = nil

                        if success {
                            claudeLogger.info("Repair completed successfully")
                            continuation.resume(returning: result)
                        } else {
                            claudeLogger.warning("Repair failed with exit code \(process.terminationStatus)")
                            continuation.resume(returning: result)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.agentProcess = nil
                        claudeLogger.error("Repair process error: \(error.localizedDescription)")
                        continuation.resume(throwing: ClaudeError.cliError(message: error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Cancel ongoing repair
    func cancelRepair() {
        agentProcess?.terminate()
        agentProcess = nil
        isRepairing = false
        claudeLogger.info("Repair cancelled by user")
    }

    /// Check if Claude CLI is available for self-healing
    var canSelfHeal: Bool {
        claudePath != nil
    }

    private func buildRepairPrompt(error: String) -> String {
        """
        You are debugging a Swift/SwiftUI macOS app called Baku.

        BUILD ERROR:
        \(error)

        INSTRUCTIONS:
        1. Read the file(s) mentioned in the error to understand the context
        2. Identify the root cause of the compilation error
        3. Fix the error by editing the necessary file(s)
        4. Be minimal - only change what's necessary to fix the error
        5. Don't add new features or refactor unrelated code

        Common Swift errors to watch for:
        - Missing imports
        - Type mismatches
        - Actor isolation issues (add @MainActor or use Task)
        - Optional handling (use ?. or ?? or if-let)
        - Missing protocol conformances

        Fix the error now.
        """
    }

    /// Parse a line from Claude Code's stream-json output
    private func parseStreamLine(_ line: String) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let eventType = json["type"] as? String ?? ""

        DispatchQueue.main.async { [weak self] in
            switch eventType {
            case "assistant":
                // Assistant message - could contain tool use
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        if let type = item["type"] as? String {
                            if type == "tool_use" {
                                let toolName = item["name"] as? String ?? "tool"
                                let input = item["input"] as? [String: Any] ?? [:]
                                let action = self?.formatToolAction(tool: toolName, input: input) ?? toolName
                                self?.currentAction = action
                                self?.repairOutput += "→ \(action)\n"
                                claudeLogger.info("[Claude Code] \(action)")
                            } else if type == "text", let text = item["text"] as? String {
                                // Claude's reasoning/response text
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    self?.repairOutput += "\(text)\n"
                                    claudeLogger.info("[Claude Code] \(text)")
                                }
                            }
                        }
                    }
                }

            case "content_block_start":
                // Tool starting
                if let contentBlock = json["content_block"] as? [String: Any],
                   contentBlock["type"] as? String == "tool_use" {
                    let toolName = contentBlock["name"] as? String ?? "tool"
                    self?.currentAction = "Starting \(toolName)..."
                }

            case "content_block_delta":
                // Streaming content - could be tool input or text
                if let delta = json["delta"] as? [String: Any],
                   let type = delta["type"] as? String {
                    if type == "text_delta", let text = delta["text"] as? String {
                        self?.repairOutput += text
                    }
                }

            case "result":
                // Final result
                if let result = json["result"] as? String {
                    self?.repairOutput += "\n✓ \(result)\n"
                    self?.currentAction = "Done"
                    claudeLogger.info("[Claude Code] Result: \(result)")
                }

            default:
                break
            }
        }
    }

    /// Format tool action for display
    private func formatToolAction(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read":
            if let filePath = input["file_path"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Reading \(fileName)..."
            }
            return "Reading file..."

        case "Edit":
            if let filePath = input["file_path"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Editing \(fileName)..."
            }
            return "Editing file..."

        case "Write":
            if let filePath = input["file_path"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Writing \(fileName)..."
            }
            return "Writing file..."

        case "Glob":
            if let pattern = input["pattern"] as? String {
                return "Searching for \(pattern)..."
            }
            return "Searching files..."

        case "Grep":
            if let pattern = input["pattern"] as? String {
                return "Searching for '\(pattern)'..."
            }
            return "Searching code..."

        case "Bash":
            if let command = input["command"] as? String {
                let shortCmd = command.prefix(40)
                return "Running: \(shortCmd)\(command.count > 40 ? "..." : "")"
            }
            return "Running command..."

        case "computer":
            if let action = input["action"] as? String {
                switch action {
                case "screenshot":
                    return "Taking screenshot..."
                case "click":
                    return "Clicking..."
                case "type":
                    if let text = input["text"] as? String {
                        let shortText = text.prefix(20)
                        return "Typing: \(shortText)\(text.count > 20 ? "..." : "")"
                    }
                    return "Typing..."
                case "key":
                    if let key = input["key"] as? String {
                        return "Pressing \(key)..."
                    }
                    return "Pressing key..."
                case "scroll":
                    return "Scrolling..."
                case "move":
                    return "Moving cursor..."
                default:
                    return "\(action)..."
                }
            }
            return "Using computer..."

        default:
            return "\(tool)..."
        }
    }

    private func parseChangedFiles(from output: String) -> [String] {
        // Parse Claude's output to find edited files
        var files: [String] = []
        let patterns = [
            "Editing (.+\\.swift)",
            "Edited (.+\\.swift)",
            "Modified (.+\\.swift)",
            "Updated (.+\\.swift)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(output.startIndex..., in: output)
                let matches = regex.matches(in: output, range: range)
                for match in matches {
                    if let fileRange = Range(match.range(at: 1), in: output) {
                        files.append(String(output[fileRange]))
                    }
                }
            }
        }

        return files
    }

    // MARK: - Automation Tasks

    /// State for automation tasks
    @Published var isAutomating: Bool = false
    @Published var automationOutput: String = ""

    /// Fetch Discord token automatically using Claude with browser
    func fetchDiscordToken() async throws -> String {
        guard let path = claudePath else {
            throw ClaudeError.noCLI
        }

        isAutomating = true
        automationOutput = ""
        claudeLogger.info("Starting Discord token fetch automation")

        defer { isAutomating = false }

        let prompt = """
        I need you to help me get my Discord user token from Chrome. Here's exactly what to do:

        1. Open Chrome to https://discord.com/app (user should already be logged in)
        2. Open Chrome DevTools (Cmd+Option+I)
        3. Go to the Network tab
        4. Filter requests by typing "api" in the filter box
        5. Click on any API request (like @me or guilds)
        6. In the Headers section, find the "Authorization" header
        7. Copy that token value

        The token is a long string that looks like: "MTI3NjM4..." (starts with letters/numbers, no "Bot " prefix)

        Return ONLY the token string, nothing else. No quotes, no explanation, just the raw token.
        If you can't get it, return "ERROR: " followed by the reason.
        """

        var env = buildEnvironment()
        env["FORCE_COLOR"] = "0"

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = [
                    "--print",
                    "--output-format", "stream-json",
                    "--dangerously-skip-permissions",
                    "--allowedTools", "Bash,computer",
                    "--max-turns", "20",
                    prompt
                ]
                process.environment = env

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                // Stream JSON output and parse for status updates
                var lineBuffer = ""
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        lineBuffer += str

                        // Process complete JSON lines
                        while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                            let line = String(lineBuffer[..<newlineIndex])
                            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])

                            self?.parseAutomationStreamLine(line)
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    outputPipe.fileHandleForReading.readabilityHandler = nil

                    let output = self?.automationOutput ?? ""

                    DispatchQueue.main.async {
                        // Extract token from output - it should be a long alphanumeric string
                        let token = self?.extractToken(from: output)

                        if let token = token, !token.isEmpty, !token.starts(with: "ERROR") {
                            claudeLogger.info("Successfully fetched Discord token")
                            continuation.resume(returning: token)
                        } else {
                            let error = token ?? "Could not extract token from output"
                            claudeLogger.warning("Failed to fetch Discord token: \(error)")
                            continuation.resume(throwing: ClaudeError.cliError(message: error))
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        claudeLogger.error("Automation error: \(error.localizedDescription)")
                        continuation.resume(throwing: ClaudeError.cliError(message: error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Parse automation stream line (similar to repair but for automationOutput)
    private func parseAutomationStreamLine(_ line: String) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let eventType = json["type"] as? String ?? ""

        DispatchQueue.main.async { [weak self] in
            switch eventType {
            case "assistant":
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        if let type = item["type"] as? String {
                            if type == "tool_use" {
                                let toolName = item["name"] as? String ?? "tool"
                                let input = item["input"] as? [String: Any] ?? [:]
                                let action = self?.formatToolAction(tool: toolName, input: input) ?? toolName
                                self?.automationOutput += "→ \(action)\n"
                                claudeLogger.info("[Claude Code] \(action)")
                            } else if type == "text", let text = item["text"] as? String {
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    self?.automationOutput += "\(text)\n"
                                    claudeLogger.info("[Claude Code] \(text)")
                                }
                            }
                        }
                    }
                }

            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   let type = delta["type"] as? String {
                    if type == "text_delta", let text = delta["text"] as? String {
                        self?.automationOutput += text
                    }
                }

            case "result":
                if let result = json["result"] as? String {
                    self?.automationOutput += "\n✓ \(result)\n"
                    claudeLogger.info("[Claude Code] Result: \(result)")
                }

            default:
                break
            }
        }
    }

    /// Extract token from Claude's output
    private func extractToken(from output: String) -> String? {
        // Look for a line that looks like a Discord token
        // Discord tokens are base64-ish strings, typically 50-100 chars
        let lines = output.components(separatedBy: .newlines)

        for line in lines.reversed() { // Check from end, token is usually last
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

            // Discord tokens: alphanumeric with dots, typically 50-100 chars
            if trimmed.count >= 50 && trimmed.count <= 150 {
                let tokenPattern = "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$"
                if let regex = try? NSRegularExpression(pattern: tokenPattern),
                   regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    return trimmed
                }
            }

            // Also check for simpler pattern (just long alphanumeric)
            if trimmed.count >= 50 && trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) {
                return trimmed
            }

            // Check for ERROR prefix
            if trimmed.starts(with: "ERROR:") {
                return trimmed
            }
        }

        return nil
    }
}

// MARK: - Repair Result

struct RepairResult {
    let success: Bool
    let output: String
    let filesChanged: [String]
    let timestamp: Date

    var summary: String {
        if success {
            if filesChanged.isEmpty {
                return "Repair completed"
            } else {
                return "Fixed \(filesChanged.count) file\(filesChanged.count == 1 ? "" : "s")"
            }
        } else {
            return "Repair failed - manual fix needed"
        }
    }
}

// MARK: - Errors

enum ClaudeError: Error, LocalizedError {
    case noAPIKey
    case noCLI
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case cliError(message: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Claude API key configured. Install Claude Code or add API key in Settings."
        case .noCLI:
            return "Claude CLI not found. Install Claude Code: npm install -g @anthropic-ai/claude-code"
        case .invalidResponse:
            return "Invalid response from Claude"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        case .cliError(let message):
            return "Claude CLI error: \(message)"
        }
    }
}
