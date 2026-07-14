import SwiftUI

struct StatusFooterView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(state.gatewayReady ? theme.palette.accent : theme.palette.danger)
                .frame(width: 6, height: 6)
            Text(state.gatewayStatus)
                .font(ARILTheme.captionFont)
                .foregroundStyle(
                    state.gatewayReady && !state.openRouterConfigured
                        ? theme.palette.danger
                        : theme.palette.textMuted
                )

            if state.lastCacheLabel == "cached" || state.lastCacheLabel == "not cached" {
                Text(state.lastCacheLabel)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(
                        state.lastCacheLabel == "cached"
                            ? theme.palette.accent
                            : theme.palette.textMuted
                    )
            }

            if state.generationPhase != .idle {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("\(state.generationPhase.label) · \(elapsedLabel)")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)
                        .monospacedDigit()
                }
            } else if let err = state.lastError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
                    .lineLimit(1)
            } else if let latency = state.lastLatencyMs {
                Text("Last \(latency)ms")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted.opacity(0.8))
            }

            Spacer()

            Text(state.routeMode.label)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Text("# v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.2")")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.palette.sidebar.opacity(0.9))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.palette.hairline)
                .frame(height: 1)
        }
    }

    private var elapsedLabel: String {
        let ms = state.generationElapsedMs
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}
