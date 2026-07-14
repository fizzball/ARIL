import SwiftUI

struct StatusFooterView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(state.gatewayReady ? ARILTheme.gold : ARILTheme.danger)
                .frame(width: 6, height: 6)
            Text(state.gatewayStatus)
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.creamMuted)

            Text("Sessions")
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.creamMuted.opacity(0.7))
            Text(state.chatProvider)
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.creamMuted.opacity(0.7))
            Text("Route")
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.creamMuted.opacity(0.7))

            if let err = state.lastError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.danger)
                    .lineLimit(1)
            }

            Spacer()

            Text(state.routeMode.label)
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.creamMuted)
            if state.lastCached {
                Text("cache hit")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.gold)
            }
            Text("# v0.2.0")
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.creamMuted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ARILTheme.sidebar.opacity(0.9))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ARILTheme.hairline)
                .frame(height: 1)
        }
    }
}
