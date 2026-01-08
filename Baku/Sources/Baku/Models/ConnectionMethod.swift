import SwiftUI

/// Connection methods for each platform - from simplest to most complex
enum ConnectionMethod: String, Codable, Identifiable {
    // Gmail
    case gmailOAuth = "gmail_oauth"
    case gmailMailApp = "gmail_mailapp"
    case gmailIMAP = "gmail_imap"

    // Slack
    case slackDesktop = "slack_desktop"
    case slackOAuth = "slack_oauth"
    case slackBot = "slack_bot"

    // Discord
    case discordDesktop = "discord_desktop"
    case discordBot = "discord_bot"

    // Twitter
    case twitterOAuth = "twitter_oauth"
    case twitterAPI = "twitter_api"

    // Grok/Tech Pulse
    case grokAPI = "grok_api"

    var id: String { rawValue }

    var platform: Platform {
        switch self {
        case .gmailOAuth, .gmailMailApp, .gmailIMAP: return .gmail
        case .slackDesktop, .slackOAuth, .slackBot: return .slack
        case .discordDesktop, .discordBot: return .discord
        case .twitterOAuth, .twitterAPI: return .twitter
        case .grokAPI: return .grok
        }
    }

    var displayName: String {
        switch self {
        case .gmailOAuth: return "Sign in with Google"
        case .gmailMailApp: return "Mail.app"
        case .gmailIMAP: return "IMAP"

        case .slackDesktop: return "Slack Desktop"
        case .slackOAuth: return "Sign in with Slack"
        case .slackBot: return "Slack Bot"

        case .discordDesktop: return "Discord Desktop"
        case .discordBot: return "Discord Bot"

        case .twitterOAuth: return "Sign in with X"
        case .twitterAPI: return "X API"

        case .grokAPI: return "xAI API"
        }
    }

    var subtitle: String {
        switch self {
        case .gmailOAuth: return "Recommended - just sign in"
        case .gmailMailApp: return "Read from Apple Mail"
        case .gmailIMAP: return "Direct mail access"

        case .slackDesktop: return "Connect to running Slack app"
        case .slackOAuth: return "Sign in to your workspace"
        case .slackBot: return "Requires workspace admin"

        case .discordDesktop: return "Connect to running Discord app"
        case .discordBot: return "Requires creating a bot"

        case .twitterOAuth: return "Just sign in"
        case .twitterAPI: return "Requires developer account"

        case .grokAPI: return "xAI API key required"
        }
    }

    var iconName: String {
        switch self {
        case .gmailOAuth, .slackOAuth, .twitterOAuth:
            return "person.badge.key.fill"
        case .gmailMailApp, .slackDesktop, .discordDesktop:
            return "macwindow"
        case .gmailIMAP:
            return "envelope.badge.fill"
        case .slackBot, .discordBot:
            return "cpu"
        case .twitterAPI, .grokAPI:
            return "key.fill"
        }
    }

    var complexity: Complexity {
        switch self {
        case .gmailMailApp, .slackDesktop, .discordDesktop:
            return .easy
        case .gmailOAuth, .slackOAuth, .twitterOAuth:
            return .medium
        case .gmailIMAP, .slackBot, .discordBot, .twitterAPI, .grokAPI:
            return .advanced
        }
    }

    var isDesktopIntegration: Bool {
        switch self {
        case .gmailMailApp, .slackDesktop, .discordDesktop:
            return true
        default:
            return false
        }
    }

    var requiresCredentials: Bool {
        switch self {
        case .gmailMailApp, .slackDesktop, .discordDesktop:
            return false
        default:
            return true
        }
    }

    /// Fields required for this connection method
    var credentialFields: [CredentialFieldInfo] {
        switch self {
        case .gmailOAuth:
            return [
                CredentialFieldInfo(key: "client_id", label: "Client ID", isSecret: false, placeholder: "xxx.apps.googleusercontent.com"),
                CredentialFieldInfo(key: "client_secret", label: "Client Secret", isSecret: true, placeholder: "GOCSPX-...")
            ]
        case .gmailMailApp:
            return [] // No credentials needed
        case .gmailIMAP:
            return [
                CredentialFieldInfo(key: "email", label: "Email", isSecret: false, placeholder: "you@gmail.com"),
                CredentialFieldInfo(key: "app_password", label: "App Password", isSecret: true, placeholder: "xxxx xxxx xxxx xxxx")
            ]

        case .slackDesktop:
            return [] // No credentials needed
        case .slackOAuth:
            return [
                CredentialFieldInfo(key: "client_id", label: "Client ID", isSecret: false, placeholder: ""),
                CredentialFieldInfo(key: "client_secret", label: "Client Secret", isSecret: true, placeholder: "")
            ]
        case .slackBot:
            return [
                CredentialFieldInfo(key: "bot_token", label: "Bot Token", isSecret: true, placeholder: "xoxb-..."),
                CredentialFieldInfo(key: "app_token", label: "App Token", isSecret: true, placeholder: "xapp-...")
            ]

        case .discordDesktop:
            return [] // No credentials needed
        case .discordBot:
            return [
                CredentialFieldInfo(key: "token", label: "Bot Token", isSecret: true, placeholder: "")
            ]

        case .twitterOAuth:
            return [
                CredentialFieldInfo(key: "client_id", label: "Client ID", isSecret: false, placeholder: ""),
                CredentialFieldInfo(key: "client_secret", label: "Client Secret", isSecret: true, placeholder: "")
            ]
        case .twitterAPI:
            return [
                CredentialFieldInfo(key: "api_key", label: "API Key", isSecret: false, placeholder: ""),
                CredentialFieldInfo(key: "api_secret", label: "API Secret", isSecret: true, placeholder: ""),
                CredentialFieldInfo(key: "bearer_token", label: "Bearer Token", isSecret: true, placeholder: "")
            ]

        case .grokAPI:
            return [
                CredentialFieldInfo(key: "api_key", label: "API Key", isSecret: true, placeholder: "xai-...")
            ]
        }
    }

    var setupURL: URL? {
        switch self {
        case .gmailOAuth:
            return URL(string: "https://console.cloud.google.com/apis/credentials")
        case .gmailIMAP:
            return URL(string: "https://myaccount.google.com/apppasswords")
        case .slackBot, .slackOAuth:
            return URL(string: "https://api.slack.com/apps")
        case .discordBot:
            return URL(string: "https://discord.com/developers/applications")
        case .twitterOAuth, .twitterAPI:
            return URL(string: "https://developer.twitter.com/en/portal/dashboard")
        case .grokAPI:
            return URL(string: "https://console.x.ai")
        default:
            return nil
        }
    }

    var setupInstructions: String? {
        switch self {
        case .gmailOAuth:
            return "Create OAuth 2.0 credentials in Google Cloud Console"
        case .gmailMailApp:
            return "Make sure Mail.app is set up with your Gmail account"
        case .gmailIMAP:
            return "Create an App Password in your Google Account settings"
        case .slackDesktop:
            return "Make sure Slack.app is running and you're signed in"
        case .slackOAuth:
            return "Create a Slack app with required OAuth scopes"
        case .slackBot:
            return "Create a Slack app with bot token scopes. Requires workspace admin."
        case .discordDesktop:
            return "Make sure Discord.app is running and you're signed in"
        case .discordBot:
            return "Create a Discord application and bot in the Developer Portal"
        case .twitterOAuth:
            return "Create an app in the Twitter Developer Portal with OAuth 2.0"
        case .twitterAPI:
            return "Get API keys from Twitter Developer Portal (may require approval)"
        case .grokAPI:
            return "Get your API key from the xAI console"
        }
    }

    enum Complexity: String {
        case easy = "Easy"
        case medium = "Medium"
        case advanced = "Advanced"

        var color: Color {
            switch self {
            case .easy: return .green
            case .medium: return .orange
            case .advanced: return .red
            }
        }
    }
}

struct CredentialFieldInfo: Identifiable {
    let key: String
    let label: String
    let isSecret: Bool
    let placeholder: String

    var id: String { key }
}

// MARK: - Platform Extension

extension Platform {
    /// Available connection methods for this platform, ordered by simplicity
    var connectionMethods: [ConnectionMethod] {
        switch self {
        case .gmail:
            return [.gmailMailApp, .gmailOAuth, .gmailIMAP]
        case .slack:
            return [.slackDesktop, .slackOAuth, .slackBot]
        case .discord:
            return [.discordDesktop, .discordBot]
        case .twitter:
            return [.twitterOAuth, .twitterAPI]
        case .grok:
            return [.grokAPI]
        }
    }

    /// Default (simplest) connection method
    var defaultConnectionMethod: ConnectionMethod {
        connectionMethods.first!
    }
}
