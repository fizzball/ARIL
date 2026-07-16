import SwiftUI

/// Trailing flyout: OpenRouter top models by weekly token volume.
struct ModelPopularityView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model popularity")
                    .font(ARILTheme.bodyFont.weight(.semibold))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                if state.isLoadingWeeklyRankings {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await state.refreshWeeklyRankings(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Refresh weekly rankings from OpenRouter")
                Button {
                    state.closeToolPanel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
            }

            Text("OpenRouter ranking by tokens processed in the last week (`top-weekly`). Tap a model to use it in Manual mode.")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)

            Divider().overlay(theme.palette.hairline)

            if let err = state.weeklyRankingsError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
            }

            if state.isLoadingWeeklyRankings, state.openRouterWeeklyRankings.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading rankings…")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if state.openRouterWeeklyRankings.isEmpty {
                Text("No weekly rankings available. Refresh to load from OpenRouter.")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(state.openRouterWeeklyRankings) { row in
                            Button {
                                state.selectModel(row.id)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("#\(row.rank)")
                                        .font(ARILTheme.captionFont.weight(.semibold))
                                        .foregroundStyle(theme.palette.accent)
                                        .monospacedDigit()
                                        .frame(width: 40, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.id)
                                            .font(ARILTheme.bodyFont)
                                            .foregroundStyle(theme.palette.text)
                                            .lineLimit(1)
                                        if row.name != row.id {
                                            Text(row.name)
                                                .font(ARILTheme.captionFont)
                                                .foregroundStyle(theme.palette.textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if let pricing = row.pricingLabel {
                                        Text(pricing)
                                            .font(ARILTheme.captionFont)
                                            .foregroundStyle(theme.palette.accent)
                                            .monospacedDigit()
                                            .frame(minWidth: 120, alignment: .trailing)
                                    }
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Use \(row.id) in Manual mode")

                            if row.id != state.openRouterWeeklyRankings.last?.id {
                                Divider().overlay(theme.palette.hairline)
                            }
                        }
                    }
                    .padding(.trailing, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.backgroundElevated)
        .task {
            if state.openRouterWeeklyRankings.isEmpty {
                await state.refreshWeeklyRankings(forceRefresh: false)
            }
        }
    }
}
