import SwiftUI
import AppKit

struct MessageListView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(state.selectedSession?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(28)
            }
            .onChange(of: state.selectedSession?.messages.count ?? 0) { _, _ in
                if let last = state.selectedSession?.messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.selectedSession?.messages.last?.content.count ?? 0) { _, _ in
                if let last = state.selectedSession?.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let message: ChatMessage
    @State private var copied = false
    @State private var pulse = false
    @State private var hoveringUser = false

    private var isStreamingAssistant: Bool {
        message.role == .assistant
            && state.isSending
            && state.selectedSession?.messages.last?.id == message.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                Image("ARILMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(isStreamingAssistant ? (pulse ? 1 : 0.55) : 1)
                    .scaleEffect(isStreamingAssistant && pulse ? 1.06 : 1)
                    .rotationEffect(.degrees(isStreamingAssistant && pulse ? 2 : 0))
                    .animation(
                        isStreamingAssistant
                            ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                    .onAppear { updatePulse() }
                    .onChange(of: isStreamingAssistant) { _, _ in updatePulse() }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message.role == .user ? state.userLabel : "ARIL")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)
                    Spacer()
                    if message.role == .user, hoveringUser {
                        Button {
                            state.reusePrompt(message.content)
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.palette.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Reuse this prompt in the entry field")
                    }
                    if message.role == .assistant, !message.content.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Copy response to clipboard")
                    }
                }

                Group {
                    if message.role == .user {
                        Text(message.content)
                            .font(ARILTheme.bodyFont)
                            .foregroundStyle(theme.palette.text)
                            .textSelection(.enabled)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.reusePrompt(message.content)
                            }
                            .help("Click or use ↓ to reuse this prompt")
                    } else {
                        Text(message.content.isEmpty && isStreamingAssistant ? "…" : message.content)
                            .font(ARILTheme.bodyFont)
                            .foregroundStyle(theme.palette.text)
                            .textSelection(.enabled)
                    }
                }
            }
            .onHover { hovering in
                if message.role == .user {
                    hoveringUser = hovering
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updatePulse() {
        if isStreamingAssistant {
            pulse = true
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }
}
