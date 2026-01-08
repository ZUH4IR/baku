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
    case discordUserToken = "discord_user_token"
    case discordBot = "discord_bot"

    // iMessage
    case imessageLocal = "imessage_local"

    // Twitter
    case twitterOAuth = "twitter_oauth"
    case twitterAPI = "twitter_api"

    // Tech Pulse (uses Claude CLI - no credentials needed)
    case techPulseClaude = "tech_pulse_claude"

    // Free public APIs (no auth needed)
    case marketsPublic = "markets_public"
    case newsPublic = "news_public"
    case predictionsPublic = "predictions_public"

    var id: String { rawValue }

    var platform: Platform {
        switch self {
        case .gmailOAuth, .gmailMailApp, .gmailIMAP: return .gmail
        case .slackDesktop, .slackOAuth, .slackBot: return .slack
        case .discordDesktop, .discordUserToken, .discordBot: return .discord
        case .imessageLocal: return .imessage
        case .twitterOAuth, .twitterAPI: return .twitter
        case .techPulseClaude: return .grok
        case .marketsPublic: return .markets
        case .newsPublic: return .news
        case .predictionsPublic: return .predictions
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
        case .discordUserToken: return "User Token"
        case .discordBot: return "Discord Bot"

        case .imessageLocal: return "Messages.app"

        case .twitterOAuth: return "Sign in with X"
        case .twitterAPI: return "X API"

        case .techPulseClaude: return "Claude Code"

        case .marketsPublic: return "Yahoo Finance + CoinGecko"
        case .newsPublic: return "RSS Feeds"
        case .predictionsPublic: return "Polymarket"
        }
    }

    var subtitle: String {
        switch self {
        case .gmailOAuth: return "Recommended - just sign in"
        case .gmailMailApp: return "Read from Apple Mail"
        case .gmailIMAP: return "Direct mail access"

        case .slackDesktop: return "Read from local cache - no setup"
        case .slackOAuth: return "Sign in to your workspace"
        case .slackBot: return "Requires workspace admin"

        case .discordDesktop: return "Read from local cache - no setup"
        case .discordUserToken: return "Your account - select servers & DMs"
        case .discordBot: return "Requires creating a bot"

        case .imessageLocal: return "Read full history - requires FDA"

        case .twitterOAuth: return "Just sign in"
        case .twitterAPI: return "Requires developer account"

        case .techPulseClaude: return "Uses Claude CLI - no setup needed"

        case .marketsPublic: return "Free - no setup needed"
        case .newsPublic: return "Free - no setup needed"
        case .predictionsPublic: return "Free - no setup needed"
        }
    }

    var iconName: String {
        switch self {
        case .gmailOAuth, .slackOAuth, .twitterOAuth, .discordUserToken:
            return "person.badge.key.fill"
        case .gmailMailApp, .slackDesktop, .discordDesktop, .imessageLocal:
            return "macwindow"
        case .gmailIMAP:
            return "envelope.badge.fill"
        case .slackBot, .discordBot:
            return "cpu"
        case .twitterAPI:
            return "key.fill"
        case .techPulseClaude:
            return "terminal.fill"
        case .marketsPublic, .newsPublic, .predictionsPublic:
            return "globe"
        }
    }

    var complexity: Complexity {
        switch self {
        case .gmailMailApp, .slackDesktop, .discordDesktop, .imessageLocal,
             .marketsPublic, .newsPublic, .predictionsPublic, .techPulseClaude:
            return .easy
        case .gmailOAuth, .slackOAuth, .twitterOAuth, .discordUserToken:
            return .medium
        case .gmailIMAP, .slackBot, .discordBot, .twitterAPI:
            return .advanced
        }
    }

    var isDesktopIntegration: Bool {
        switch self {
        case .gmailMailApp, .slackDesktop, .discordDesktop, .imessageLocal:
            return true
        default:
            return false
        }
    }

    var requiresCredentials: Bool {
        switch self {
        case .gmailMailApp, .slackDesktop, .discordDesktop, .imessageLocal,
             .marketsPublic, .newsPublic, .predictionsPublic, .techPulseClaude:
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
        case .discordUserToken:
            return [
                CredentialFieldInfo(key: "user_token", label: "User Token", isSecret: true, placeholder: "Get from browser DevTools")
            ]
        case .discordBot:
            return [
                CredentialFieldInfo(key: "token", label: "Bot Token", isSecret: true, placeholder: "")
            ]

        case .imessageLocal:
            return [] // No credentials - reads from local SQLite database

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

        case .techPulseClaude:
            return [] // Uses Claude CLI - no credentials needed

        case .marketsPublic, .newsPublic, .predictionsPublic:
            return [] // No credentials needed
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
        case .techPulseClaude:
            return nil // No setup needed - uses Claude CLI
        case .marketsPublic, .newsPublic, .predictionsPublic:
            return nil // No setup needed
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
            return "Reads from local cache - works automatically"
        case .slackOAuth:
            return "Create a Slack app with required OAuth scopes"
        case .slackBot:
            return "Create a Slack app with bot token scopes. Requires workspace admin."
        case .discordDesktop:
            return "Reads from local cache - works automatically"
        case .discordUserToken:
            return "Get your token from browser DevTools (Network tab > filter 'api' > Authorization header)"
        case .discordBot:
            return "Create a Discord application and bot in the Developer Portal"
        case .imessageLocal:
            return "Requires Full Disk Access in System Settings > Privacy & Security"
        case .twitterOAuth:
            return "Create an app in the Twitter Developer Portal with OAuth 2.0"
        case .twitterAPI:
            return "Get API keys from Twitter Developer Portal (may require approval)"
        case .techPulseClaude:
            return "AI-generated tech insights using Claude CLI"

        case .marketsPublic:
            return "Live market data from Yahoo Finance and CoinGecko"
        case .newsPublic:
            return "Tech news from Hacker News, Verge, Ars Technica, and more"
        case .predictionsPublic:
            return "Trending prediction markets from Polymarket"
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
            return [.discordUserToken, .discordDesktop, .discordBot]
        case .imessage:
            return [.imessageLocal]
        case .twitter:
            return [.twitterOAuth, .twitterAPI]
        case .grok:
            return [.techPulseClaude]
        case .markets:
            return [.marketsPublic]
        case .news:
            return [.newsPublic]
        case .predictions:
            return [.predictionsPublic]
        }
    }

    /// Default (simplest) connection method
    var defaultConnectionMethod: ConnectionMethod {
        connectionMethods.first!
    }
}
