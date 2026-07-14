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
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var theme: ThemeStore
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.role == .user ? "You" : "ARIL")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)
                Spacer()
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
            Text(message.content)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(theme.palette.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
