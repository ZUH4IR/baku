import Foundation
import Defaults
import Security

/// Manages app settings and credentials
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    // MARK: - Platform Settings

    @Published var enabledPlatforms: Set<Platform> = []

    // MARK: - Initialization

    init() {
        loadSettings()
    }

    private func loadSettings() {
        // Load enabled platforms from UserDefaults
        let savedPlatforms = Defaults[.enabledPlatforms]
        enabledPlatforms = Set(savedPlatforms.compactMap { Platform(rawValue: $0) })
    }

    // MARK: - Platform Configuration

    func isPlatformEnabled(_ platform: Platform) -> Bool {
        enabledPlatforms.contains(platform)
    }

    func setPlatformEnabled(_ platform: Platform, enabled: Bool) {
        if enabled {
            enabledPlatforms.insert(platform)
        } else {
            enabledPlatforms.remove(platform)
        }
        Defaults[.enabledPlatforms] = enabledPlatforms.map { $0.rawValue }
    }

    func isPlatformConfigured(_ platform: Platform) -> Bool {
        switch platform {
        case .gmail:
            return getCredential(platform: platform, key: "client_id") != nil
        case .slack:
            return getCredential(platform: platform, key: "bot_token") != nil
        case .discord:
            return getCredential(platform: platform, key: "token") != nil
        case .twitter:
            return getCredential(platform: platform, key: "api_key") != nil
        case .grok:
            return getCredential(platform: platform, key: "api_key") != nil
        }
    }

    // MARK: - Environment Variables for MCP Servers

    func environmentVariables(for platform: Platform) -> [String: String] {
        var env: [String: String] = [:]

        switch platform {
        case .gmail:
            if let clientId = getCredential(platform: platform, key: "client_id") {
                env["GMAIL_CLIENT_ID"] = clientId
            }
            if let clientSecret = getCredential(platform: platform, key: "client_secret") {
                env["GMAIL_CLIENT_SECRET"] = clientSecret
            }

        case .slack:
            if let botToken = getCredential(platform: platform, key: "bot_token") {
                env["SLACK_BOT_TOKEN"] = botToken
            }
            if let appToken = getCredential(platform: platform, key: "app_token") {
                env["SLACK_APP_TOKEN"] = appToken
            }

        case .discord:
            if let token = getCredential(platform: platform, key: "token") {
                env["DISCORD_TOKEN"] = token
            }

        case .twitter:
            if let apiKey = getCredential(platform: platform, key: "api_key") {
                env["TWITTER_API_KEY"] = apiKey
            }
            if let apiSecret = getCredential(platform: platform, key: "api_secret") {
                env["TWITTER_API_SECRET"] = apiSecret
            }

        case .grok:
            if let apiKey = getCredential(platform: platform, key: "api_key") {
                env["GROK_API_KEY"] = apiKey
            }
        }

        return env
    }

    // MARK: - Credential Storage (Keychain)

    private let keychainService = "com.baku.credentials"

    func setCredential(platform: Platform, key: String, value: String) {
        let account = "\(platform.rawValue)_\(key)"

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: value.data(using: .utf8)!
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func getCredential(platform: Platform, key: String) -> String? {
        let account = "\(platform.rawValue)_\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    func deleteCredential(platform: Platform, key: String) {
        let account = "\(platform.rawValue)_\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func clearAllCredentials(for platform: Platform) {
        let keys: [String]
        switch platform {
        case .gmail: keys = ["client_id", "client_secret", "access_token", "refresh_token"]
        case .slack: keys = ["bot_token", "app_token"]
        case .discord: keys = ["token"]
        case .twitter: keys = ["api_key", "api_secret", "access_token", "access_secret"]
        case .grok: keys = ["api_key"]
        }

        for key in keys {
            deleteCredential(platform: platform, key: key)
        }
    }
}

// MARK: - Defaults Keys

extension Defaults.Keys {
    static let enabledPlatforms = Key<[String]>("enabledPlatforms", default: [])
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
    static let morningNotifications = Key<Bool>("morningNotifications", default: true)
    static let morningTime = Key<Date>("morningTime", default: Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date())
    static let autoGenerateDrafts = Key<Bool>("autoGenerateDrafts", default: true)
    static let draftTone = Key<String>("draftTone", default: "professional")
}
