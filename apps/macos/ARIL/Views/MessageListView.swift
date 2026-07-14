import SwiftUI

struct MessageListView: View {
    @EnvironmentObject private var state: AppState

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
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : "ARIL")
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.gold)
            Text(message.content)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(ARILTheme.cream)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
