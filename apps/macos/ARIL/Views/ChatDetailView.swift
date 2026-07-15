import SwiftUI

struct ChatDetailView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    private var isEmpty: Bool {
        (state.selectedSession?.messages.isEmpty ?? true)
    }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            BackgroundTexture(accent: theme.palette.accent)

            VStack(spacing: 0) {
                if isEmpty && state.compareResults.isEmpty {
                    EmptyHeroView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    MessageListView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                        .transition(.opacity)
                    if !state.compareResults.isEmpty {
                        CompareResultsView(results: state.compareResults)
                            .frame(maxHeight: 320)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if state.showIntelligencePanel {
                    IntelligencePanelView()
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
            .animation(.easeInOut(duration: 0.25), value: state.compareResults.count)
        }
        .sheet(isPresented: $state.showRoutingAnalysis) {
            RoutingAnalysisView()
                .environmentObject(state)
                .environmentObject(theme)
        }
    }
}

private struct BackgroundTexture: View {
    let accent: Color
    var body: some View {
        RadialGradient(
            colors: [accent.opacity(0.18), Color.clear],
            center: .center,
            startRadius: 40,
            endRadius: 520
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
