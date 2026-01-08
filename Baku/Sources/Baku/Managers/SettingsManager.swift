import Foundation
import Defaults
import Security
import Combine
import os.log

private let settingsLogger = Logger(subsystem: "com.baku.app", category: "SettingsManager")

/// Manages app settings and credentials
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    // MARK: - Platform Settings

    @Published var enabledPlatforms: Set<Platform> = []
    @Published var connectionMethods: [Platform: ConnectionMethod] = [:]

    // MARK: - Discord Settings

    @Published var discordSelectedGuilds: Set<String> = []
    @Published var discordSelectedDMs: Set<String> = []
    @Published var discordIncludeDMs: Bool = true

    // MARK: - Credential Cache (avoids repeated keychain prompts)

    private var credentialCache: [String: String] = [:]
    private var credentialCacheLoaded = false

    // MARK: - Auto-save observers
    private var cancellables = Set<AnyCancellable>()
    private var isLoading = true // Prevent saving during initial load

    // MARK: - Initialization

    init() {
        loadSettings()
        setupAutoSave()
        isLoading = false
    }

    private func loadSettings() {
        // Load enabled platforms
        let savedPlatforms = Defaults[.enabledPlatforms]
        enabledPlatforms = Set(savedPlatforms.compactMap { Platform(rawValue: $0) })

        // Auto-enable info pulse platforms that don't require manual setup
        // These use Claude CLI or free public APIs
        let freeInfoPulses: [Platform] = [.grok, .markets, .news, .predictions]
        for platform in freeInfoPulses {
            if !enabledPlatforms.contains(platform) {
                enabledPlatforms.insert(platform)
            }
        }
        // Save back if we added any
        Defaults[.enabledPlatforms] = enabledPlatforms.map { $0.rawValue }

        // Load connection methods
        let savedMethods = Defaults[.connectionMethods]
        for (platformRaw, methodRaw) in savedMethods {
            if let platform = Platform(rawValue: platformRaw),
               let method = ConnectionMethod(rawValue: methodRaw) {
                connectionMethods[platform] = method
            }
        }

        // Load Discord settings
        discordSelectedGuilds = Set(Defaults[.discordSelectedGuilds])
        discordSelectedDMs = Set(Defaults[.discordSelectedDMs])
        discordIncludeDMs = Defaults[.discordIncludeDMs]
    }

    /// Setup Combine observers to auto-save when @Published properties change
    private func setupAutoSave() {
        // Auto-save enabled platforms
        $enabledPlatforms
            .dropFirst() // Skip initial value
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] platforms in
                guard self?.isLoading == false else { return }
                settingsLogger.info("Auto-saving enabledPlatforms: \(platforms.map(\.rawValue))")
                Defaults[.enabledPlatforms] = platforms.map { $0.rawValue }
            }
            .store(in: &cancellables)

        // Auto-save connection methods
        $connectionMethods
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] methods in
                guard self?.isLoading == false else { return }
                var saved: [String: String] = [:]
                for (platform, method) in methods {
                    saved[platform.rawValue] = method.rawValue
                }
                settingsLogger.info("Auto-saving connectionMethods: \(saved)")
                Defaults[.connectionMethods] = saved
            }
            .store(in: &cancellables)

        // Auto-save Discord guilds
        $discordSelectedGuilds
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] guilds in
                guard self?.isLoading == false else { return }
                settingsLogger.info("Auto-saving discordSelectedGuilds: \(guilds.count) guilds")
                Defaults[.discordSelectedGuilds] = Array(guilds)
            }
            .store(in: &cancellables)

        // Auto-save Discord DMs
        $discordSelectedDMs
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] dms in
                guard self?.isLoading == false else { return }
                settingsLogger.info("Auto-saving discordSelectedDMs: \(dms.count) DMs")
                Defaults[.discordSelectedDMs] = Array(dms)
            }
            .store(in: &cancellables)

        // Auto-save Discord include DMs toggle
        $discordIncludeDMs
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] include in
                guard self?.isLoading == false else { return }
                settingsLogger.info("Auto-saving discordIncludeDMs: \(include)")
                Defaults[.discordIncludeDMs] = include
            }
            .store(in: &cancellables)
    }

    // MARK: - Connection Methods

    func getConnectionMethod(for platform: Platform) -> ConnectionMethod {
        connectionMethods[platform] ?? platform.defaultConnectionMethod
    }

    func setConnectionMethod(_ method: ConnectionMethod, for platform: Platform) {
        connectionMethods[platform] = method
        objectWillChange.send()

        var saved = Defaults[.connectionMethods]
        saved[platform.rawValue] = method.rawValue
        Defaults[.connectionMethods] = saved
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
        let method = getConnectionMethod(for: platform)

        // Platforms that don't require credentials are always configured
        if !method.requiresCredentials {
            return true
        }

        // Check if all required credential fields are filled
        for field in method.credentialFields {
            if getCredential(platform: platform, key: field.key) == nil {
                return false
            }
        }

        return !method.credentialFields.isEmpty
    }

    // MARK: - Discord Selection Management

    func getDiscordSelectedGuilds() -> Set<String> {
        discordSelectedGuilds
    }

    func setDiscordSelectedGuilds(_ guilds: Set<String>) {
        discordSelectedGuilds = guilds
        Defaults[.discordSelectedGuilds] = Array(guilds)
        objectWillChange.send()
    }

    func toggleDiscordGuild(_ guildId: String) {
        if discordSelectedGuilds.contains(guildId) {
            discordSelectedGuilds.remove(guildId)
        } else {
            discordSelectedGuilds.insert(guildId)
        }
        Defaults[.discordSelectedGuilds] = Array(discordSelectedGuilds)
        objectWillChange.send()
    }

    func getDiscordSelectedDMs() -> Set<String> {
        discordSelectedDMs
    }

    func setDiscordSelectedDMs(_ dms: Set<String>) {
        discordSelectedDMs = dms
        Defaults[.discordSelectedDMs] = Array(dms)
        objectWillChange.send()
    }

    func setDiscordIncludeDMs(_ include: Bool) {
        discordIncludeDMs = include
        Defaults[.discordIncludeDMs] = include
        objectWillChange.send()
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
            // Tech Pulse uses Claude CLI - no credentials needed
            break

        case .imessage:
            // No credentials - reads from local SQLite database
            break

        case .markets, .news, .predictions:
            // No credentials needed - free public APIs
            break
        }

        return env
    }

    // MARK: - Credential Storage (Keychain with caching)

    private let keychainService = "com.baku.credentials"

    /// Load all credentials into cache on first access (single keychain prompt)
    private func loadCredentialCacheIfNeeded() {
        guard !credentialCacheLoaded else { return }

        settingsLogger.info("Loading credentials from keychain...")

        // Query all items for our service at once
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            settingsLogger.info("No credentials in keychain (first run)")
            credentialCacheLoaded = true
            return
        }

        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            // User denied access or keychain is locked - DON'T mark as loaded so we can retry
            settingsLogger.warning("Keychain access denied or locked (status \(status)) - will retry next access")
            return
        }

        if status != errSecSuccess {
            settingsLogger.error("Keychain query failed with status: \(status)")
            // For other errors, mark as loaded to avoid infinite prompts
            credentialCacheLoaded = true
            return
        }

        // Success - mark as loaded and populate cache
        credentialCacheLoaded = true

        guard let items = result as? [[String: Any]] else {
            settingsLogger.warning("Keychain returned unexpected format")
            return
        }

        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data,
               let value = String(data: data, encoding: .utf8) {
                credentialCache[account] = value
                settingsLogger.info("Loaded credential: \(account)")
            }
        }

        settingsLogger.info("Loaded \(self.credentialCache.count) credentials from keychain")
    }

    func setCredential(platform: Platform, key: String, value: String) {
        let account = "\(platform.rawValue)_\(key)"

        settingsLogger.info("Saving credential: \(account)")

        // Update cache immediately
        credentialCache[account] = value
        credentialCacheLoaded = true // Mark loaded since we now have data

        // Also save to UserDefaults as backup (for development builds with signing issues)
        UserDefaults.standard.set(value, forKey: "credential_\(account)")
        settingsLogger.info("Saved credential to UserDefaults backup: \(account)")

        // Delete existing from keychain
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            settingsLogger.warning("Keychain delete returned: \(deleteStatus)")
        }

        // Add new with accessible attribute to reduce prompts
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: value.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecSuccess {
            settingsLogger.info("Credential saved to keychain: \(account)")
        } else {
            settingsLogger.error("Keychain save FAILED for \(account): status \(addStatus)")
            settingsLogger.info("Using UserDefaults backup for \(account)")
        }
    }

    func getCredential(platform: Platform, key: String) -> String? {
        let account = "\(platform.rawValue)_\(key)"

        // Check cache first
        if credentialCacheLoaded {
            if let value = credentialCache[account] {
                settingsLogger.debug("getCredential \(account): found in cache")
                return value
            }
        } else {
            // Load all credentials into cache (single keychain access)
            loadCredentialCacheIfNeeded()
            if let value = credentialCache[account] {
                settingsLogger.debug("getCredential \(account): found in keychain")
                return value
            }
        }

        // Fallback to UserDefaults backup (for development builds)
        if let backupValue = UserDefaults.standard.string(forKey: "credential_\(account)") {
            settingsLogger.info("getCredential \(account): found in UserDefaults backup")
            // Populate cache from backup
            credentialCache[account] = backupValue
            return backupValue
        }

        settingsLogger.debug("getCredential \(account): not found anywhere")
        return nil
    }

    func deleteCredential(platform: Platform, key: String) {
        let account = "\(platform.rawValue)_\(key)"

        settingsLogger.info("Deleting credential: \(account)")

        // Remove from cache
        credentialCache.removeValue(forKey: account)

        // Remove from UserDefaults backup
        UserDefaults.standard.removeObject(forKey: "credential_\(account)")

        // Remove from keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            settingsLogger.warning("Keychain delete returned: \(status)")
        }
    }

    func clearAllCredentials(for platform: Platform) {
        settingsLogger.info("Clearing all credentials for: \(platform.rawValue)")

        let keys: [String]
        switch platform {
        case .gmail: keys = ["client_id", "client_secret", "access_token", "refresh_token"]
        case .slack: keys = ["bot_token", "app_token"]
        case .discord: keys = ["user_token", "token"]
        case .imessage: keys = [] // No credentials - local database access
        case .twitter: keys = ["api_key", "api_secret", "access_token", "access_secret"]
        case .grok: keys = [] // Uses Claude CLI - no credentials
        case .markets, .news, .predictions: keys = [] // No credentials
        }

        for key in keys {
            deleteCredential(platform: platform, key: key)
        }
    }

    /// Force reload credentials from keychain (use after "Always Allow")
    func reloadCredentials() {
        settingsLogger.info("Force reloading credentials from keychain")
        credentialCache.removeAll()
        credentialCacheLoaded = false
        loadCredentialCacheIfNeeded()
    }

    /// Debug: print current cache state
    func debugPrintCache() {
        settingsLogger.info("Cache loaded: \(self.credentialCacheLoaded), items: \(self.credentialCache.count)")
        for (key, _) in credentialCache {
            settingsLogger.info("  - \(key): (value hidden)")
        }
    }
}

// MARK: - Defaults Keys

extension Defaults.Keys {
    // Default platforms: Gmail, Slack, and info pulses (Tech Pulse, Markets, News, Predictions)
    static let enabledPlatforms = Key<[String]>("enabledPlatforms", default: [
        Platform.gmail.rawValue,
        Platform.slack.rawValue,
        Platform.grok.rawValue,
        Platform.markets.rawValue,
        Platform.news.rawValue,
        Platform.predictions.rawValue
    ])
    static let connectionMethods = Key<[String: String]>("connectionMethods", default: [
        Platform.gmail.rawValue: ConnectionMethod.gmailMailApp.rawValue,
        Platform.slack.rawValue: ConnectionMethod.slackDesktop.rawValue
    ])
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
    static let morningNotifications = Key<Bool>("morningNotifications", default: true)
    static let morningTime = Key<Date>("morningTime", default: Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date())
    static let autoGenerateDrafts = Key<Bool>("autoGenerateDrafts", default: true)
    static let draftTone = Key<String>("draftTone", default: "professional")

    // Discord settings
    static let discordSelectedGuilds = Key<[String]>("discordSelectedGuilds", default: [])
    static let discordSelectedDMs = Key<[String]>("discordSelectedDMs", default: [])
    static let discordIncludeDMs = Key<Bool>("discordIncludeDMs", default: true)

    // Self-healing settings
    static let autoFixErrors = Key<Bool>("autoFixErrors", default: false)
}
