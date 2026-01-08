import SwiftUI

/// Main content view for the floating window
struct ContentView: View {
    @ObservedObject var viewModel: BakuViewModel
    @State private var showingSettings = false
    @State private var selectedTab: MainTab = .inbox

    enum MainTab: String, CaseIterable {
        case inbox = "Inbox"
        case pulse = "Pulse"
    }

    // MARK: - Animation

    @Namespace private var animation

    var body: some View {
        ZStack {
            // Background
            notchBackground

            // Content
            if viewModel.isOpen {
                openContent
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                closedContent
                    .transition(.opacity)
            }
        }
        .frame(
            width: viewModel.isOpen ? NotchWindow.openSize.width : NotchWindow.closedSize.width,
            height: viewModel.isOpen ? NotchWindow.openSize.height : NotchWindow.closedSize.height
        )
        .clipShape(RoundedRectangle(cornerRadius: viewModel.isOpen ? 20 : 12))
        .shadow(color: .black.opacity(viewModel.isOpen ? 0.5 : 0.3), radius: viewModel.isOpen ? 30 : 12)
        .onTapGesture {
            if !viewModel.isOpen {
                viewModel.toggle()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    // MARK: - Background

    private var notchBackground: some View {
        Color(red: 0.08, green: 0.08, blue: 0.1)
            .overlay(
                LinearGradient(
                    colors: [Color.white.opacity(0.04), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: viewModel.isOpen ? 20 : 12)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    // MARK: - Closed State

    private var closedContent: some View {
        HStack(spacing: 10) {
            Text("Baku")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            if let badge = viewModel.badgeText {
                Text(badge)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(Capsule())
            }

            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Open State

    @ViewBuilder
    private var openContent: some View {
        switch viewModel.viewState {
        case .inbox:
            inboxView
        case .detail(let message):
            MessageDetailView(
                message: message,
                onSend: { content in
                    try await viewModel.sendReply(to: message, content: content)
                },
                onClose: {
                    viewModel.goBack()
                }
            )
        }
    }

    // MARK: - Filtered Messages

    private var inboxMessages: [Message] {
        viewModel.messages.filter { !$0.platform.isInfoPulse }
    }

    private var pulseMessages: [Message] {
        viewModel.messages.filter { $0.platform.isInfoPulse }
    }

    // MARK: - Inbox View

    private var inboxView: some View {
        VStack(spacing: 0) {
            dragHandle
            header
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            switch selectedTab {
            case .inbox:
                if inboxMessages.isEmpty {
                    emptyState(
                        icon: "tray",
                        title: "No messages",
                        subtitle: "Configure platforms in Settings"
                    )
                } else {
                    messageList(messages: inboxMessages)
                }
            case .pulse:
                if pulseMessages.isEmpty {
                    emptyState(
                        icon: "waveform.path.ecg",
                        title: "No pulse data",
                        subtitle: "Enable Markets, News, or Predictions"
                    )
                } else {
                    pulseList
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
            Button("Open Settings") {
                showingSettings = true
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.3))
            Spacer()
        }
    }

    private func messageList(messages: [Message]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(messages) { message in
                    MessageCard(
                        message: message,
                        onTap: {
                            viewModel.selectMessage(message)
                        },
                        onGenerateDraft: {
                            Task {
                                await viewModel.generateDraft(for: message)
                            }
                        }
                    )

                    if message.id != messages.last?.id {
                        Divider()
                            .background(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var pulseList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(pulseMessages) { message in
                    PulseCard(message: message)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.25))
            .frame(width: 36, height: 4)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            // Tab selector
            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    TabButton(
                        title: tab.rawValue,
                        count: tab == .inbox ? inboxMessages.count : pulseMessages.count,
                        isSelected: selectedTab == tab
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    }
                }
            }

            if let time = viewModel.lastFetchTime {
                Text("Updated \(time.timeAgo)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            // Refresh
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                    .animation(
                        viewModel.isLoading
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: viewModel.isLoading
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)

            // Settings
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            // Minimize
            Button {
                viewModel.close()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pulse Card

private struct PulseCard: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: message.platform.iconName)
                    .font(.system(size: 14))
                    .foregroundColor(message.platform.accentColor)

                Text(message.platform.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(message.timestamp.timeAgo)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Content
            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(message.platform.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview {
    ContentView(viewModel: BakuViewModel())
        .frame(width: 640, height: 400)
        .background(Color.gray.opacity(0.3))
}
