import SwiftUI
import AppKit

/// A view that renders an SVG icon from bundled resources
/// Uses NSImage's native SVG support (macOS 11+)
struct SVGIcon: View {
    let name: String
    var size: CGFloat = 16
    var color: Color? = nil

    var body: some View {
        Group {
            if let nsImage = loadSVGImage() {
                Image(nsImage: nsImage)
                    .renderingMode(color != nil ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .foregroundStyle(color ?? .primary)
            } else {
                // Fallback to SF Symbol placeholder
                Image(systemName: "questionmark.square")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .foregroundStyle(color ?? .secondary)
            }
        }
    }

    private func loadSVGImage() -> NSImage? {
        // Try to load from bundle resources
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons") else {
            return nil
        }

        // NSImage can load SVGs directly on macOS 11+
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        // Set as template for tinting support
        image.isTemplate = true
        return image
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        Text("Brand Icons").font(.headline)

        HStack(spacing: 16) {
            VStack {
                SVGIcon(name: "discord", size: 24, color: Color(hex: "#5865F2"))
                Text("Discord").font(.caption2)
            }
            VStack {
                SVGIcon(name: "gmail", size: 24, color: Color(hex: "#EA4335"))
                Text("Gmail").font(.caption2)
            }
            VStack {
                SVGIcon(name: "slack", size: 24, color: Color(hex: "#4A154B"))
                Text("Slack").font(.caption2)
            }
            VStack {
                SVGIcon(name: "x", size: 24)
                Text("X").font(.caption2)
            }
        }

        HStack(spacing: 16) {
            VStack {
                SVGIcon(name: "imessage", size: 24, color: Color(hex: "#34C759"))
                Text("iMessage").font(.caption2)
            }
            VStack {
                SVGIcon(name: "grok", size: 24, color: .orange)
                Text("Tech").font(.caption2)
            }
            VStack {
                SVGIcon(name: "markets", size: 24, color: Color(hex: "#16A34A"))
                Text("Markets").font(.caption2)
            }
            VStack {
                SVGIcon(name: "news", size: 24, color: Color(hex: "#F97316"))
                Text("News").font(.caption2)
            }
        }
    }
    .padding()
}
