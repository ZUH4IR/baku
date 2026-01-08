import SwiftUI

/// Detailed view for a message with draft editing and send functionality
struct MessageDetailView: View {
    let message: Message
    let onSend: (String) async throws -> Void
    let onClose: () -> Void

    @State private var draftContent: String
    @State private var isEditing = false
    @State private var isSending = false
    @State private var isGenerating = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedTone: Draft.Tone = .professional

    init(message: Message, onSend: @escaping (String) async throws -> Void, onClose: @escaping () -> Void) {
        self.message = message
        self.onSend = onSend
        self.onClose = onClose
        self._draftContent = State(initialValue: message.draft?.content ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding()

            Divider()
                .background(Color.white.opacity(0.1))

            // Original message
            originalMessage
                .padding()

            Divider()
                .background(Color.white.opacity(0.1))

            // Draft section
            draftSection

            // Actions
            actionBar
                .padding()
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Image(systemName: message.platform.iconName)
                .foregroundColor(message.platform.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.senderName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                if let handle = message.senderHandle {
                    Text(handle)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Spacer()

            Text(message.timestamp.timeAgo)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Original Message

    private var originalMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let subject = message.subject {
                Text(subject)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }

            Text(message.content)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Draft Section

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your Reply")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()

                if !isEditing {
                    Picker("Tone", selection: $selectedTone) {
                        ForEach(Draft.Tone.allCases, id: \.self) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }
                    .pickerStyle(.menu)
                    .scaleEffect(0.85)

                    Button {
                        regenerateDraft()
                    } label: {
                        if isGenerating {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.7))
                    .disabled(isGenerating)
                }
            }

            if isEditing {
                TextEditor(text: $draftContent)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .frame(minHeight: 100)
            } else {
                Text(draftContent.isEmpty ? "No draft yet. Click the sparkles to generate one." : draftContent)
                    .font(.system(size: 13))
                    .foregroundColor(draftContent.isEmpty ? .white.opacity(0.4) : .white.opacity(0.9))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .onTapGesture {
                        isEditing = true
                    }
            }
        }
        .padding()
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            if isEditing {
                Button("Cancel") {
                    draftContent = message.draft?.content ?? ""
                    isEditing = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.7))

                Spacer()

                Button("Done") {
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.7))

                Spacer()

                Button {
                    sendDraft()
                } label: {
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(message.platform.accentColor)
                .disabled(draftContent.isEmpty || isSending)
            }
        }
    }

    // MARK: - Actions

    private func regenerateDraft() {
        isGenerating = true

        Task {
            do {
                let draft = try await ClaudeManager.shared.generateDraft(
                    for: message,
                    tone: selectedTone
                )
                draftContent = draft.content
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isGenerating = false
        }
    }

    private func sendDraft() {
        guard !draftContent.isEmpty else { return }
        isSending = true

        Task {
            do {
                try await onSend(draftContent)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isSending = false
        }
    }
}

// MARK: - Date Extension

extension Date {
    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

#Preview {
    MessageDetailView(
        message: Message.sampleMessages[0],
        onSend: { _ in },
        onClose: {}
    )
    .frame(width: 600, height: 500)
}
