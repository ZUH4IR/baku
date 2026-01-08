import SwiftUI

/// Main inbox view showing all messages
struct InboxView: View {
    @ObservedObject var viewModel: BakuViewModel
    @State private var selectedPlatform: Platform?

    var body: some View {
        VStack(spacing: 0) {
            // Platform filter tabs
            platformTabs
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()
                .background(Color.white.opacity(0.08))

            // Message list
            if filteredMessages.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
    }

    // MARK: - Filtered Messages

    private var filteredMessages: [Message] {
        if let platform = selectedPlatform {
            return viewModel.messages.filter { $0.platform == platform }
        }
        return viewModel.messages
    }

    // MARK: - Platform Tabs

    private var platformTabs: some View {
        HStack(spacing: 8) {
            // All tab
            PlatformTab(
                title: "All",
                count: viewModel.messages.count,
                isSelected: selectedPlatform == nil,
                color: .white
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedPlatform = nil
                }
            }

            // Platform-specific tabs
            ForEach(Platform.allCases) { platform in
                let count = viewModel.messages.filter { $0.platform == platform }.count
                if count > 0 {
                    PlatformTab(
                        title: platform.displayName,
                        count: count,
                        isSelected: selectedPlatform == platform,
                        color: platform.accentColor
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedPlatform = platform
                        }
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredMessages) { message in
                    MessageCard(
                        message: message,
                        onTap: {
                            // Handle message tap - could open detail view
                        },
                        onGenerateDraft: {
                            Task {
                                await viewModel.generateDraft(for: message)
                            }
                        }
                    )

                    if message.id != filteredMessages.last?.id {
                        Divider()
                            .background(Color.white.opacity(0.08))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))

            Text("No messages")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            if selectedPlatform != nil {
                Button("Show all") {
                    withAnimation {
                        selectedPlatform = nil
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Platform Tab

struct PlatformTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))

                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        isSelected
                            ? color.opacity(0.3)
                            : Color.white.opacity(0.1)
                    )
                    .cornerRadius(4)
            }
            .foregroundColor(isSelected ? color : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? color.opacity(0.15)
                    : Color.clear
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    InboxView(viewModel: BakuViewModel())
        .background(Color.black)
        .frame(width: 600, height: 300)
}
