import SwiftUI

/// Supported communication platforms
enum Platform: String, Codable, CaseIterable, Identifiable {
    case gmail
    case slack
    case discord
    case twitter
    case imessage
    // Info pulses
    case grok
    case markets
    case news
    case predictions

    var id: String { rawValue }

    // MARK: - Display Properties

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        case .discord: return "Discord"
        case .twitter: return "Twitter"
        case .imessage: return "iMessage"
        case .grok: return "Tech Pulse"
        case .markets: return "Markets"
        case .news: return "News"
        case .predictions: return "Predictions"
        }
    }

    var iconName: String {
        switch self {
        case .gmail: return "envelope.fill"
        case .slack: return "number"
        case .discord: return "gamecontroller.fill"
        case .twitter: return "bird.fill"
        case .imessage: return "message.fill"
        case .grok: return "bolt.fill"
        case .markets: return "chart.line.uptrend.xyaxis"
        case .news: return "newspaper.fill"
        case .predictions: return "dice.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .gmail: return Color(hex: "#EA4335")
        case .slack: return Color(hex: "#4A154B")
        case .discord: return Color(hex: "#5865F2")
        case .twitter: return Color(hex: "#1DA1F2")
        case .imessage: return Color(hex: "#34C759")
        case .grok: return Color(hex: "#000000")
        case .markets: return Color(hex: "#16A34A")
        case .news: return Color(hex: "#F97316")
        case .predictions: return Color(hex: "#8B5CF6")
        }
    }

    /// Whether this platform provides informational content vs actionable messages
    var isInfoPulse: Bool {
        switch self {
        case .grok, .markets, .news, .predictions: return true
        default: return false
        }
    }

    /// Whether this platform is shown by default in the settings UI
    /// Hidden platforms can still be enabled but require explicit action
    var isEnabledByDefault: Bool {
        switch self {
        case .imessage: return false // Personal messaging, not business-focused
        default: return true
        }
    }

    /// Platforms that are shown in the main settings list
    static var defaultPlatforms: [Platform] {
        allCases.filter { $0.isEnabledByDefault }
    }

    /// All available platforms including hidden ones
    static var allAvailablePlatforms: [Platform] {
        allCases.filter { !$0.isInfoPulse }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
