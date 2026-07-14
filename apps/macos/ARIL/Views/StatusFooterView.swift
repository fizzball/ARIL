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
                .foregroundStyle(theme.palette.textMuted)

            Text(state.chatProvider)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted.opacity(0.7))

            Text(state.lastCacheLabel)
                .font(ARILTheme.captionFont)
                .foregroundStyle(
                    state.lastCacheLabel == "cached"
                        ? theme.palette.accent
                        : theme.palette.textMuted
                )

            if let err = state.lastError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
                    .lineLimit(1)
            }

            Spacer()

            Text(state.routeMode.label)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Text("# v0.3.0-solo")
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
}
