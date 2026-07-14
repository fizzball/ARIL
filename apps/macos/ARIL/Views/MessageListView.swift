import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : "ARIL")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.accent)
            Text(message.content)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(theme.palette.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
