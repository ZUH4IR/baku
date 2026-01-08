import SwiftUI

/// Card displaying a single message in the inbox
struct MessageCard: View {
    let message: Message
    let onTap: () -> Void
    let onGenerateDraft: () -> Void

    @State private var isHovered: Bool = false
    @State private var isGenerating: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Platform icon
            platformIcon

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Header row
                HStack {
                    // Sender
                    Text(message.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    if let handle = message.senderHandle {
                        Text(handle)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    Spacer()

                    // Timestamp
                    Text(message.timestamp.relativeFormatted)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                // Channel/Subject
                if let context = message.channelName ?? message.subject {
                    Text(context)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }

                // Content preview
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .padding(.top, 2)

                // Draft status or generate button
                draftStatus
                    .padding(.top, 6)
            }

            // Chevron indicator
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            isHovered
                ? Color.white.opacity(0.06)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Platform Icon

    private var platformIcon: some View {
        ZStack {
            Circle()
                .fill(message.platform.accentColor.opacity(0.15))
                .frame(width: 38, height: 38)

            Image(systemName: message.platform.iconName)
                .font(.system(size: 15))
                .foregroundColor(message.platform.accentColor)

            // Unread indicator
            if !message.isRead {
                Circle()
                    .fill(message.platform.accentColor)
                    .frame(width: 8, height: 8)
                    .offset(x: 14, y: -14)
            }
        }
    }

    // MARK: - Draft Status

    @ViewBuilder
    private var draftStatus: some View {
        HStack(spacing: 8) {
            if let draft = message.draft {
                // Draft ready indicator
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)

                    Text("Draft ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green.opacity(0.9))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)

            } else if message.needsResponse {
                // Generate draft button
                Button {
                    isGenerating = true
                    onGenerateDraft()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isGenerating = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isGenerating {
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                        }

                        Text(isGenerating ? "Generating..." : "Generate draft")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        LinearGradient(
                            colors: [
                                message.platform.accentColor.opacity(0.5),
                                message.platform.accentColor.opacity(0.3)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
            }

            Spacer()

            // Priority indicator
            if message.priority == .high || message.priority == .critical {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(message.priority == .critical ? "Urgent" : "High")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(message.priority == .critical ? .red : .orange)
            }
        }
    }
}

// MARK: - Date Extension

extension Date {
    var relativeFormatted: String {
        let now = Date()
        let diff = now.timeIntervalSince(self)

        if diff < 60 {
            return "now"
        } else if diff < 3600 {
            let mins = Int(diff / 60)
            return "\(mins)m ago"
        } else if diff < 86400 {
            let hours = Int(diff / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(diff / 86400)
            return "\(days)d ago"
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        MessageCard(
            message: Message.sampleMessages[0],
            onTap: {},
            onGenerateDraft: {}
        )
        Divider().background(Color.white.opacity(0.1))
        MessageCard(
            message: Message.sampleMessages[1],
            onTap: {},
            onGenerateDraft: {}
        )
    }
    .background(Color.black)
    .frame(width: 600)
}
