import Foundation

/// Manages communication with Claude API for draft generation
@MainActor
class ClaudeManager: ObservableObject {
    static let shared = ClaudeManager()

    @Published var isGenerating: Bool = false
    @Published var lastError: Error?

    private let settings = SettingsManager.shared
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

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
        case .grok:
            return "This is a tech pulse summary. Focus on key insights and trends."
        }
    }

    // MARK: - Claude API Communication

    private func callClaudeAPI(prompt: String) async throws -> String {
        // Check for API key
        guard let apiKey = settings.getCredential(platform: .gmail, key: "claude_api_key")
                ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            // Fall back to simulated response for development
            return await simulatedResponse(for: prompt)
        }

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

        if prompt.contains("Gmail") || prompt.contains("email") {
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
}

// MARK: - Errors

enum ClaudeError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Claude API key configured. Add it in Settings."
        case .invalidResponse:
            return "Invalid response from Claude API"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        }
    }
}
