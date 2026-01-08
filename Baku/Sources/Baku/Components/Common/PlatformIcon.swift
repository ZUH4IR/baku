import SwiftUI

/// A view that renders a platform icon, preferring SVG brand icons with SF Symbol fallback
struct PlatformIcon: View {
    let platform: Platform
    var size: CGFloat = 16
    var useAccentColor: Bool = true
    var useSFSymbol: Bool = false  // Set true to force SF Symbol

    var body: some View {
        if useSFSymbol {
            sfSymbolIcon
        } else {
            SVGIcon(
                name: platform.svgIconName,
                size: size,
                color: useAccentColor ? platform.accentColor : nil
            )
        }
    }

    private var sfSymbolIcon: some View {
        Image(systemName: platform.iconName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(useAccentColor ? platform.accentColor : .primary)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        Text("SVG Brand Icons").font(.headline)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 12) {
            ForEach(Platform.allCases) { platform in
                VStack(spacing: 4) {
                    PlatformIcon(platform: platform, size: 24)
                    Text(platform.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }

        Divider()

        Text("SF Symbol Fallbacks").font(.headline)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 12) {
            ForEach(Platform.allCases) { platform in
                VStack(spacing: 4) {
                    PlatformIcon(platform: platform, size: 24, useSFSymbol: true)
                    Text(platform.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
    }
    .padding()
    .frame(width: 400)
}
