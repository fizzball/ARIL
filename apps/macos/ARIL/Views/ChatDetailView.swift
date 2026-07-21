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
                if !state.compareResults.isEmpty {
                    // Judge mode: fill the chat area and blank the transcript behind it.
                    CompareResultsView(results: state.compareResults)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                        .transition(.opacity)
                } else if isEmpty {
                    EmptyHeroView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    MessageListView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                        .transition(.opacity)
                }

                if let progress = state.modelTestProgress, state.compareResults.isEmpty {
                    ModelTestProgressPanelView(progress: progress)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                } else if state.showIntelligencePanel, state.compareResults.isEmpty {
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
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: state.modelTestProgress)
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

/// Slide-up shown during Learning → Run Selected Model Test (replaces Intelligence).
struct ModelTestProgressPanelView: View {
    @EnvironmentObject private var theme: ThemeStore
    let progress: ModelTestProgress

    private var shortModel: String {
        progress.model.split(separator: "/").last.map(String.init) ?? progress.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Selected model test", systemImage: "checkmark.seal")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)
                Spacer()
                Text("\(progress.index) of \(progress.total)")
                    .font(ARILTheme.captionFont.weight(.semibold))
                    .foregroundStyle(theme.palette.text)
                    .monospacedDigit()
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CATEGORY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                    Text(progress.category.label)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.text)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("MODEL")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                    Text(shortModel)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                        .help(progress.model)
                }
                Spacer(minLength: 0)
            }

            Text(progress.category.blurb)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.analysisFill)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.palette.accent.opacity(0.55), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(theme.palette.colorScheme == .dark ? 0.4 : 0.1), radius: 10, y: 3)
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
