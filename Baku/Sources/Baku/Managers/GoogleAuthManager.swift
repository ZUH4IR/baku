import Foundation
import GoogleSignIn
import AppKit

/// Manages Google Sign-In for Gmail OAuth authentication
@MainActor
class GoogleAuthManager: ObservableObject {
    static let shared = GoogleAuthManager()

    @Published var isSignedIn = false
    @Published var userEmail: String?
    @Published var error: String?

    private let settings = SettingsManager.shared

    // Gmail API scopes needed for reading/sending email
    private let gmailScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify"
    ]

    init() {
        // Check for existing sign-in
        restorePreviousSignIn()
    }

    // MARK: - Sign In

    /// Sign in with Google using the native SDK
    func signIn() async throws {
        guard let window = NSApplication.shared.keyWindow else {
            throw GoogleAuthError.noWindow
        }

        // Configure with stored client ID or use default
        let clientID = settings.getCredential(platform: .gmail, key: "client_id")
            ?? Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String

        guard let clientID = clientID, !clientID.isEmpty else {
            throw GoogleAuthError.missingClientID
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: window,
                hint: nil,
                additionalScopes: gmailScopes
            )

            await handleSignInResult(result)
        } catch {
            throw GoogleAuthError.signInFailed(error.localizedDescription)
        }
    }

    /// Handle successful sign-in
    private func handleSignInResult(_ result: GIDSignInResult) async {
        let user = result.user

        // Store tokens securely
        if let accessToken = user.accessToken.tokenString as String? {
            settings.setCredential(platform: .gmail, key: "access_token", value: accessToken)
        }

        if let refreshToken = user.refreshToken.tokenString as String? {
            settings.setCredential(platform: .gmail, key: "refresh_token", value: refreshToken)
        }

        // Store user email
        if let email = user.profile?.email {
            settings.setCredential(platform: .gmail, key: "email", value: email)
            userEmail = email
        }

        isSignedIn = true
        error = nil

        // Update connection method to OAuth
        settings.setConnectionMethod(.gmailOAuth, for: .gmail)
        settings.setPlatformEnabled(.gmail, enabled: true)
    }

    // MARK: - Restore Previous Sign In

    /// Check for and restore previous sign-in
    func restorePreviousSignIn() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            Task { @MainActor in
                if let user = user {
                    self?.userEmail = user.profile?.email
                    self?.isSignedIn = true
                } else {
                    self?.isSignedIn = false
                }
            }
        }
    }

    // MARK: - Sign Out

    func signOut() {
        GIDSignIn.sharedInstance.signOut()

        // Clear stored credentials
        settings.deleteCredential(platform: .gmail, key: "access_token")
        settings.deleteCredential(platform: .gmail, key: "refresh_token")
        settings.deleteCredential(platform: .gmail, key: "email")

        isSignedIn = false
        userEmail = nil
    }

    // MARK: - Get Access Token

    /// Get a fresh access token for API calls
    func getAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            // Try to restore from stored tokens
            if let storedToken = settings.getCredential(platform: .gmail, key: "access_token") {
                return storedToken
            }
            throw GoogleAuthError.notSignedIn
        }

        // Refresh if needed
        do {
            try await user.refreshTokensIfNeeded()
            let token = user.accessToken.tokenString
            settings.setCredential(platform: .gmail, key: "access_token", value: token)
            return token
        } catch {
            throw GoogleAuthError.tokenRefreshFailed(error.localizedDescription)
        }
    }

    // MARK: - Handle URL

    /// Handle OAuth callback URL (for macOS URL scheme)
    func handleURL(_ url: URL) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

// MARK: - Errors

enum GoogleAuthError: Error, LocalizedError {
    case noWindow
    case missingClientID
    case signInFailed(String)
    case notSignedIn
    case tokenRefreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWindow:
            return "No window available for sign-in"
        case .missingClientID:
            return "Google Client ID not configured. Add it in Settings or Info.plist"
        case .signInFailed(let message):
            return "Sign-in failed: \(message)"
        case .notSignedIn:
            return "Not signed in to Google"
        case .tokenRefreshFailed(let message):
            return "Failed to refresh token: \(message)"
        }
    }
}
