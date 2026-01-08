import Foundation

/// Client for communicating with MCP servers via stdio
actor MCPClient {
    private let serverPath: String
    private let serverArgs: [String]
    private let environment: [String: String]

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var requestId: Int = 0
    private var pendingRequests: [Int: CheckedContinuation<MCPResponse, Error>] = [:]

    init(serverPath: String, args: [String] = [], environment: [String: String] = [:]) {
        self.serverPath = serverPath
        self.serverArgs = args
        self.environment = environment
    }

    // MARK: - Lifecycle

    func start() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", serverPath] + serverArgs

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.process = process

        try process.run()

        // Start reading responses
        Task {
            await readResponses()
        }

        // Initialize the MCP connection
        _ = try await call(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Baku", "version": "1.0.0"]
        ])
    }

    func stop() {
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
    }

    // MARK: - MCP Methods

    func listTools() async throws -> [MCPTool] {
        let response = try await call(method: "tools/list", params: [:])
        guard let tools = response.result?["tools"] as? [[String: Any]] else {
            return []
        }
        return tools.compactMap { MCPTool(from: $0) }
    }

    func callTool(name: String, arguments: [String: Any] = [:]) async throws -> MCPToolResult {
        let response = try await call(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])

        if let error = response.error {
            throw MCPError.toolError(error["message"] as? String ?? "Unknown error")
        }

        guard let result = response.result else {
            throw MCPError.invalidResponse
        }

        return MCPToolResult(from: result)
    }

    // MARK: - Private

    private func call(method: String, params: [String: Any]) async throws -> MCPResponse {
        requestId += 1
        let id = requestId

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        guard var message = String(data: data, encoding: .utf8) else {
            throw MCPError.encodingError
        }
        message += "\n"

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            stdin?.write(message.data(using: .utf8)!)
        }
    }

    private func readResponses() async {
        guard let stdout = stdout else { return }

        var buffer = Data()

        while process?.isRunning == true {
            let chunk = stdout.availableData
            if chunk.isEmpty {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                continue
            }

            buffer.append(chunk)

            // Try to parse complete JSON lines
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let id = json["id"] as? Int else {
                    continue
                }

                let response = MCPResponse(
                    id: id,
                    result: json["result"] as? [String: Any],
                    error: json["error"] as? [String: Any]
                )

                if let continuation = pendingRequests.removeValue(forKey: id) {
                    continuation.resume(returning: response)
                }
            }
        }
    }
}

// MARK: - Types

struct MCPResponse {
    let id: Int
    let result: [String: Any]?
    let error: [String: Any]?
}

struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    init?(from dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let description = dict["description"] as? String else {
            return nil
        }
        self.name = name
        self.description = description
        self.inputSchema = dict["inputSchema"] as? [String: Any] ?? [:]
    }
}

struct MCPToolResult {
    let content: [MCPContent]
    let isError: Bool

    init(from dict: [String: Any]) {
        self.isError = dict["isError"] as? Bool ?? false

        if let contentArray = dict["content"] as? [[String: Any]] {
            self.content = contentArray.compactMap { MCPContent(from: $0) }
        } else {
            self.content = []
        }
    }

    var text: String? {
        content.first { $0.type == "text" }?.text
    }
}

struct MCPContent {
    let type: String
    let text: String?

    init?(from dict: [String: Any]) {
        guard let type = dict["type"] as? String else { return nil }
        self.type = type
        self.text = dict["text"] as? String
    }
}

enum MCPError: Error {
    case notConnected
    case encodingError
    case invalidResponse
    case toolError(String)
}
