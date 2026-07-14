import SwiftUI

struct ChatDetailView: View {
    @EnvironmentObject private var state: AppState

    private var isEmpty: Bool {
        (state.selectedSession?.messages.isEmpty ?? true)
    }

    var body: some View {
        ZStack {
            ARILTheme.background.ignoresSafeArea()
            BackgroundTexture()

            VStack(spacing: 0) {
                if isEmpty {
                    EmptyHeroView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    MessageListView()
                        .transition(.opacity)
                }

                if state.showIntelligencePanel, let preview = state.preview {
                    IntelligencePanelView(preview: preview)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                InputBarView()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)

                StatusFooterView()
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: state.showIntelligencePanel)
            .animation(.easeInOut(duration: 0.28), value: isEmpty)
        }
    }
}

private struct BackgroundTexture: View {
    var body: some View {
        RadialGradient(
            colors: [
                Color(red: 0.18, green: 0.14, blue: 0.10).opacity(0.55),
                Color.clear,
            ],
            center: .center,
            startRadius: 40,
            endRadius: 520
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
