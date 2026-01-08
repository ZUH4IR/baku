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
    @Published var lastRepairResult: RepairResult?

    private let settings = SettingsManager.shared
    private var agentProcess: Process?

    /// Path to claude CLI - checks common install locations
    private var claudePath: String? {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude"
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
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

    // MARK: - Claude CLI Communication

    private func callClaudeAPI(prompt: String) async throws -> String {
        // Try to use claude CLI first (uses existing authentication)
        if let path = claudePath {
            return try await callClaudeCLI(path: path, prompt: prompt)
        }

        // Fall back to direct API if CLI not found but API key is available
        if let apiKey = settings.getCredential(platform: .gmail, key: "claude_api_key")
                ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            return try await callClaudeDirectAPI(apiKey: apiKey, prompt: prompt)
        }

        // No claude CLI and no API key - return simulated response for development
        return await simulatedResponse(for: prompt)
    }

    /// Call claude CLI with prompt - uses existing authentication
    private func callClaudeCLI(path: String, prompt: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["-p", prompt, "--output-format", "text"]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0 && !output.isEmpty {
                        continuation.resume(returning: output)
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: ClaudeError.cliError(message: errorOutput))
                    }
                } catch {
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

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = [
                    "--print",
                    "--dangerously-skip-permissions",
                    "--allowedTools", "Read,Edit,Glob,Grep,Bash",
                    "--max-turns", "15",
                    prompt
                ]
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
                process.environment = ProcessInfo.processInfo.environment
                process.environment?["FORCE_COLOR"] = "0"

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                self?.agentProcess = process

                // Stream output
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        DispatchQueue.main.async {
                            self?.repairOutput += str
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

    private func parseChangedFiles(from output: String) -> [String] {
        // Parse Claude's output to find edited files
        var files: [String] = []
        let patterns = [
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
