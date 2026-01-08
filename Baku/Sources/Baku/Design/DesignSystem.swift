import SwiftUI

// MARK: - Design Tokens

/// Centralized design tokens for consistent UI
enum BakuDesign {
    // MARK: - Spacing
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Corner Radius
    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let pill: CGFloat = 100
    }

    // MARK: - Typography
    enum Typography {
        static let title = Font.system(size: 18, weight: .semibold)
        static let headline = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let caption = Font.system(size: 11, weight: .regular)
        static let captionBold = Font.system(size: 11, weight: .medium)
    }

    // MARK: - Colors
    enum Colors {
        // Background
        static let background = Color(nsColor: .windowBackgroundColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let surfaceHover = Color(nsColor: .selectedControlColor).opacity(0.3)

        // Text
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textTertiary = Color.secondary.opacity(0.7)

        // Semantic
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red
        static let info = Color.blue

        // Platform accent colors
        static func platform(_ platform: Platform) -> Color {
            platform.accentColor
        }
    }

    // MARK: - Shadows
    enum Shadow {
        static let sm = ShadowStyle(color: .black.opacity(0.1), radius: 2, y: 1)
        static let md = ShadowStyle(color: .black.opacity(0.15), radius: 4, y: 2)
        static let lg = ShadowStyle(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    // MARK: - Animation
    enum Animation {
        static let quick = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.9)
        static let standard = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let smooth = SwiftUI.Animation.spring(response: 0.45, dampingFraction: 0.8)
    }
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

// MARK: - View Modifiers

extension View {
    func bakuCard(padding: CGFloat = BakuDesign.Spacing.md) -> some View {
        self
            .padding(padding)
            .background(BakuDesign.Colors.surface)
            .cornerRadius(BakuDesign.Radius.md)
    }

    func bakuShadow(_ style: ShadowStyle = BakuDesign.Shadow.sm) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: 0, y: style.y)
    }

    func bakuHoverEffect() -> some View {
        self.modifier(HoverEffectModifier())
    }
}

private struct HoverEffectModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? BakuDesign.Colors.surfaceHover : Color.clear)
            .animation(BakuDesign.Animation.quick, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Button Styles

struct BakuPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BakuDesign.Typography.captionBold)
            .padding(.horizontal, BakuDesign.Spacing.md)
            .padding(.vertical, BakuDesign.Spacing.sm)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(BakuDesign.Radius.sm)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct BakuSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BakuDesign.Typography.captionBold)
            .padding(.horizontal, BakuDesign.Spacing.md)
            .padding(.vertical, BakuDesign.Spacing.sm)
            .background(BakuDesign.Colors.surface)
            .foregroundColor(.primary)
            .cornerRadius(BakuDesign.Radius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: BakuDesign.Radius.sm)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == BakuPrimaryButtonStyle {
    static var bakuPrimary: BakuPrimaryButtonStyle { BakuPrimaryButtonStyle() }
}

extension ButtonStyle where Self == BakuSecondaryButtonStyle {
    static var bakuSecondary: BakuSecondaryButtonStyle { BakuSecondaryButtonStyle() }
}

// MARK: - Priority Badge

struct PriorityBadge: View {
    let priority: Message.Priority

    var body: some View {
        Text(priority.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(BakuDesign.Radius.sm)
    }

    private var backgroundColor: Color {
        switch priority {
        case .critical: return BakuDesign.Colors.error
        case .high: return BakuDesign.Colors.warning
        case .medium: return BakuDesign.Colors.info
        case .low: return BakuDesign.Colors.textSecondary
        }
    }
}

// MARK: - Platform Badge

struct PlatformBadge: View {
    let platform: Platform
    var showLabel: Bool = false

    var body: some View {
        HStack(spacing: BakuDesign.Spacing.xs) {
            Image(systemName: platform.iconName)
                .font(.system(size: 12))

            if showLabel {
                Text(platform.displayName)
                    .font(BakuDesign.Typography.caption)
            }
        }
        .foregroundColor(platform.accentColor)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var action: (() -> Void)?
    var actionLabel: String?

    var body: some View {
        VStack(spacing: BakuDesign.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(BakuDesign.Colors.textTertiary)

            VStack(spacing: BakuDesign.Spacing.xs) {
                Text(title)
                    .font(BakuDesign.Typography.headline)
                    .foregroundColor(BakuDesign.Colors.textPrimary)

                Text(subtitle)
                    .font(BakuDesign.Typography.body)
                    .foregroundColor(BakuDesign.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let action = action, let label = actionLabel {
                Button(label, action: action)
                    .buttonStyle(.bakuPrimary)
            }
        }
        .padding(BakuDesign.Spacing.xxl)
    }
}

// MARK: - Loading Indicator

struct LoadingView: View {
    var message: String = "Loading..."

    var body: some View {
        VStack(spacing: BakuDesign.Spacing.md) {
            ProgressView()
                .scaleEffect(0.8)

            Text(message)
                .font(BakuDesign.Typography.caption)
                .foregroundColor(BakuDesign.Colors.textSecondary)
        }
    }
}
