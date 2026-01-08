import Foundation
import os.log

private let mcpLogger = Logger(subsystem: "com.baku.app", category: "MCPClient")

/// Client for communicating with MCP servers via stdio
actor MCPClient {
    private let serverPath: String
    private let serverArgs: [String]
    private let environment: [String: String]

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var requestId: Int = 0
    private var pendingRequests: [Int: CheckedContinuation<MCPResponse, Error>] = [:]

    init(serverPath: String, args: [String] = [], environment: [String: String] = [:]) {
        self.serverPath = serverPath
        self.serverArgs = args
        self.environment = environment
    }

    // MARK: - Node Path Resolution

    /// Find node executable - GUI apps don't inherit shell PATH with nvm/homebrew
    private static func findNodePath() -> String? {
        let possiblePaths = [
            // nvm paths (common)
            "\(NSHomeDirectory())/.nvm/versions/node/v20.5.0/bin/node",
            "\(NSHomeDirectory())/.nvm/versions/node/v22.0.0/bin/node",
            "\(NSHomeDirectory())/.nvm/versions/node/v21.0.0/bin/node",
            "\(NSHomeDirectory())/.nvm/versions/node/v18.0.0/bin/node",
            // Homebrew paths
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            // System
            "/usr/bin/node"
        ]

        // Also check for any nvm version
        let nvmVersionsDir = "\(NSHomeDirectory())/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir) {
            for version in versions.sorted().reversed() { // prefer newest
                let nodePath = "\(nvmVersionsDir)/\(version)/bin/node"
                if FileManager.default.isExecutableFile(atPath: nodePath) {
                    mcpLogger.info("Found node via nvm: \(nodePath)")
                    return nodePath
                }
            }
        }

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                mcpLogger.info("Found node at: \(path)")
                return path
            }
        }

        mcpLogger.error("Node not found in any expected location")
        return nil
    }

    // MARK: - Lifecycle

    func start() async throws {
        let process = Process()

        // Find node executable - GUI apps don't inherit shell PATH
        mcpLogger.info("Looking for node executable...")
        guard let nodePath = MCPClient.findNodePath() else {
            mcpLogger.error("Cannot start MCP server: node not found")
            throw MCPError.nodeNotFound
        }

        // Verify the server file exists
        guard FileManager.default.fileExists(atPath: self.serverPath) else {
            mcpLogger.error("MCP server file not found at: \(self.serverPath)")
            throw MCPError.serverNotFound(self.serverPath)
        }

        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [self.serverPath] + self.serverArgs

        mcpLogger.info("Starting MCP server: \(nodePath) \(self.serverPath)")
        mcpLogger.info("Server args: \(self.serverArgs)")

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
        self.stderr = stderrPipe.fileHandleForReading
        self.process = process

        do {
            try process.run()
            mcpLogger.info("Process started successfully, PID: \(process.processIdentifier)")
        } catch {
            mcpLogger.error("Failed to start process: \(error.localizedDescription)")
            throw MCPError.processStartFailed(error.localizedDescription)
        }

        // Give the process a moment to start and potentially fail
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Check if process died immediately
        if !process.isRunning {
            mcpLogger.error("Process exited immediately with status: \(process.terminationStatus)")
            throw MCPError.processExitedEarly(process.terminationStatus)
        }

        // Setup readers using readabilityHandler (non-blocking)
        setupResponseReader()
        setupStderrReader()

        // Initialize the MCP connection (shorter timeout to fail fast)
        mcpLogger.info("Sending initialize to MCP server...")
        do {
            _ = try await call(method: "initialize", params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "Baku", "version": "1.0.0"]
            ], timeout: 10)
            mcpLogger.info("MCP server initialized successfully")
        } catch {
            mcpLogger.error("Initialize failed: \(error.localizedDescription)")
            process.terminate()
            throw error
        }
    }

    func stop() {
        // Clean up readability handler first
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil

        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        stderr = nil
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

    private func call(method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> MCPResponse {
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

        mcpLogger.info("MCP call: \(method) (id: \(id))")
        mcpLogger.debug("MCP request: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Store continuation and write message before starting timeout race
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPResponse, Error>) in
            pendingRequests[id] = continuation

            guard let stdin = stdin, let messageData = message.data(using: .utf8) else {
                mcpLogger.error("MCP call failed: stdin is nil or message encoding failed")
                continuation.resume(throwing: MCPError.notConnected)
                return
            }

            do {
                try stdin.write(contentsOf: messageData)
                mcpLogger.info("MCP call: wrote \(messageData.count) bytes to stdin")
            } catch {
                mcpLogger.error("MCP call: failed to write to stdin: \(error.localizedDescription)")
                continuation.resume(throwing: error)
                return
            }

            // Start timeout task
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // If request still pending after timeout, fail it
                if let pending = await self.removePendingRequest(id: id) {
                    pending.resume(throwing: MCPError.timeout)
                }
            }
        }
    }

    private func removePendingRequest(id: Int) -> CheckedContinuation<MCPResponse, Error>? {
        return pendingRequests.removeValue(forKey: id)
    }

    private func setupResponseReader() {
        guard let stdout = stdout else {
            mcpLogger.error("setupResponseReader: stdout is nil")
            return
        }

        mcpLogger.info("setupResponseReader: configuring readability handler")
        var buffer = Data()

        // Use readabilityHandler for non-blocking reads
        // This runs on a dispatch queue, not the actor, so it won't block
        stdout.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData

            guard !chunk.isEmpty else {
                // Empty data means EOF - process closed stdout
                mcpLogger.info("readResponses: EOF received, closing reader")
                handle.readabilityHandler = nil
                return
            }

            mcpLogger.info("readResponses: received \(chunk.count) bytes")
            buffer.append(chunk)

            // Try to parse complete JSON lines
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])

                if let lineStr = String(data: lineData, encoding: .utf8) {
                    mcpLogger.info("readResponses: parsing line: \(lineStr.prefix(200))")
                }

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let id = json["id"] as? Int else {
                    mcpLogger.debug("readResponses: skipping non-response line (no id)")
                    continue
                }

                mcpLogger.info("readResponses: got response for id \(id)")

                let response = MCPResponse(
                    id: id,
                    result: json["result"] as? [String: Any],
                    error: json["error"] as? [String: Any]
                )

                // Dispatch back to actor to handle the response
                Task { [weak self] in
                    guard let self = self else { return }
                    if let pendingContinuation = await self.removePendingRequest(id: id) {
                        mcpLogger.info("readResponses: resuming continuation for id \(id)")
                        pendingContinuation.resume(returning: response)
                    } else {
                        mcpLogger.warning("readResponses: no pending request for id \(id)")
                    }
                }
            }
        }

        mcpLogger.info("setupResponseReader: handler configured")
    }

    private func setupStderrReader() {
        guard let stderr = stderr else { return }

        stderr.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                mcpLogger.warning("MCP stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
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

enum MCPError: Error, LocalizedError {
    case notConnected
    case encodingError
    case invalidResponse
    case toolError(String)
    case nodeNotFound
    case timeout
    case serverNotFound(String)
    case processStartFailed(String)
    case processExitedEarly(Int32)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "MCP client not connected"
        case .encodingError: return "Failed to encode MCP request"
        case .invalidResponse: return "Invalid response from MCP server"
        case .toolError(let msg): return "MCP tool error: \(msg)"
        case .nodeNotFound: return "Node.js not found. Install via: brew install node"
        case .timeout: return "MCP request timed out"
        case .serverNotFound(let path): return "MCP server not found at: \(path)"
        case .processStartFailed(let msg): return "Failed to start MCP process: \(msg)"
        case .processExitedEarly(let code): return "MCP process exited immediately with code: \(code)"
        }
    }
}
