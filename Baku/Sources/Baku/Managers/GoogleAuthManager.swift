import Foundation
import os.log

private let googleAuthLogger = Logger(subsystem: "com.baku.app", category: "GoogleAuthManager")

/// Manages Google OAuth authentication using browser-based flow
@MainActor
class GoogleAuthManager: ObservableObject {
    static let shared = GoogleAuthManager()

    @Published var isAuthenticating = false
    @Published var userEmail: String?
    @Published var error: String?

    private let settings = SettingsManager.shared

    /// Start the OAuth flow using saved/entered credentials
    func signIn() async throws {
        // Try to get credentials from keychain first, then fall back to temporary storage
        let clientId = settings.getCredential(platform: .gmail, key: "client_id") ?? ""
        let clientSecret = settings.getCredential(platform: .gmail, key: "client_secret") ?? ""

        guard !clientId.isEmpty, !clientSecret.isEmpty else {
            throw GoogleAuthError.noCredentials
        }
        _ = try await signIn(clientId: clientId, clientSecret: clientSecret)
    }

    /// Start the OAuth flow - opens browser for user to sign in
    func signIn(clientId: String, clientSecret: String) async throws -> GoogleAuthTokens {
        isAuthenticating = true
        error = nil
        defer { isAuthenticating = false }

        googleAuthLogger.info("Starting Google OAuth flow")

        // Find the auth helper script
        guard let scriptPath = findAuthScript() else {
            let err = "Auth helper script not found"
            error = err
            throw GoogleAuthError.scriptNotFound
        }

        googleAuthLogger.info("Using auth script at: \(scriptPath)")

        // Find node executable
        guard let nodePath = findNodePath() else {
            error = "Node.js not found. Install via: brew install node"
            throw GoogleAuthError.nodeNotFound
        }

        googleAuthLogger.info("Using node at: \(nodePath)")

        // Run the auth helper
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [
            scriptPath,
            "--client-id", clientId,
            "--client-secret", clientSecret
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            googleAuthLogger.error("Failed to run auth script: \(error.localizedDescription)")
            self.error = "Failed to start authentication"
            throw GoogleAuthError.processError(error.localizedDescription)
        }

        // Wait for completion (with timeout)
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 minutes
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
            googleAuthLogger.info("Auth script stderr: \(errorOutput)")
        }

        guard let outputString = String(data: outputData, encoding: .utf8),
              !outputString.isEmpty else {
            error = "No response from authentication"
            throw GoogleAuthError.noResponse
        }

        googleAuthLogger.info("Auth script output received")

        // Parse JSON response
        guard let jsonData = outputString.data(using: .utf8) else {
            error = "Invalid response format"
            throw GoogleAuthError.invalidResponse
        }

        // Check for error response
        if let errorResponse = try? JSONDecoder().decode(GoogleAuthErrorResponse.self, from: jsonData),
           errorResponse.error != nil {
            error = errorResponse.message ?? "Authentication failed"
            throw GoogleAuthError.authFailed(errorResponse.message ?? "Unknown error")
        }

        // Parse tokens
        let tokens = try JSONDecoder().decode(GoogleAuthTokens.self, from: jsonData)

        // Save tokens
        saveTokens(tokens, clientId: clientId, clientSecret: clientSecret)

        // Fetch user info
        await fetchUserInfo(accessToken: tokens.accessToken)

        googleAuthLogger.info("Google OAuth completed successfully")
        return tokens
    }

    /// Refresh the access token using the refresh token
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = settings.getCredential(platform: .gmail, key: "refresh_token"),
              let clientId = settings.getCredential(platform: .gmail, key: "client_id"),
              let clientSecret = settings.getCredential(platform: .gmail, key: "client_secret") else {
            throw GoogleAuthError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleAuthError.refreshFailed
        }

        struct RefreshResponse: Codable {
            let accessToken: String
            let expiresIn: Int

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }

        let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        settings.setCredential(platform: .gmail, key: "access_token", value: refreshResponse.accessToken)

        return refreshResponse.accessToken
    }

    /// Sign out - clear all tokens
    func signOut() {
        settings.clearAllCredentials(for: .gmail)
        userEmail = nil
        googleAuthLogger.info("Signed out of Google")
    }

    /// Check if user is signed in
    var isSignedIn: Bool {
        settings.getCredential(platform: .gmail, key: "access_token") != nil
    }

    // MARK: - Private

    private func findNodePath() -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/node",      // Apple Silicon Homebrew
            "/usr/local/bin/node",          // Intel Homebrew
            "/usr/bin/node",                // System
            "\(NSHomeDirectory())/.nvm/versions/node/v20.10.0/bin/node",  // Common nvm
            "\(NSHomeDirectory())/.nvm/versions/node/v18.19.0/bin/node"
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try to find via which (won't work in sandboxed app, but worth trying)
        return nil
    }

    private func findAuthScript() -> String? {
        let possiblePaths = [
            // Development path
            "/Users/zuhair/conductor/workspaces/zuhair-helper/baku/mcp-servers/auth-helper/src/google-auth.js",
            // Relative to bundle
            Bundle.main.bundlePath + "/../../../../../mcp-servers/auth-helper/src/google-auth.js"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func saveTokens(_ tokens: GoogleAuthTokens, clientId: String, clientSecret: String) {
        settings.setCredential(platform: .gmail, key: "access_token", value: tokens.accessToken)
        if let refreshToken = tokens.refreshToken {
            settings.setCredential(platform: .gmail, key: "refresh_token", value: refreshToken)
        }
        settings.setCredential(platform: .gmail, key: "client_id", value: clientId)
        settings.setCredential(platform: .gmail, key: "client_secret", value: clientSecret)
    }

    private func fetchUserInfo(accessToken: String) async {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct UserInfo: Codable {
                let email: String?
                let name: String?
            }
            let userInfo = try JSONDecoder().decode(UserInfo.self, from: data)
            userEmail = userInfo.email
            googleAuthLogger.info("Fetched user info: \(userInfo.email ?? "no email")")
        } catch {
            googleAuthLogger.warning("Failed to fetch user info: \(error.localizedDescription)")
        }
    }
}

// MARK: - Models

struct GoogleAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

struct GoogleAuthErrorResponse: Codable {
    let error: String?
    let message: String?
}

enum GoogleAuthError: Error, LocalizedError {
    case scriptNotFound
    case nodeNotFound
    case processError(String)
    case noResponse
    case invalidResponse
    case authFailed(String)
    case noRefreshToken
    case refreshFailed
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "Authentication helper not found"
        case .nodeNotFound:
            return "Node.js not found. Install via: brew install node"
        case .processError(let msg):
            return "Process error: \(msg)"
        case .noResponse:
            return "No response from authentication"
        case .invalidResponse:
            return "Invalid response format"
        case .authFailed(let msg):
            return msg
        case .noRefreshToken:
            return "No refresh token available"
        case .refreshFailed:
            return "Failed to refresh access token"
        case .noCredentials:
            return "Please enter Client ID and Client Secret first"
        }
    }
}
