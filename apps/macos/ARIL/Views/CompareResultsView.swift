import SwiftUI

struct CompareResultsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let results: [CompareResultDTO]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare results — pick a preferred response to teach routing")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.accent)
                .padding(.horizontal, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(short(result.model))
                                    .font(ARILTheme.captionFont)
                                    .foregroundStyle(
                                        state.preferredCompareModel == result.model
                                            ? theme.palette.preferredHighlight
                                            : theme.palette.accent
                                    )
                                Spacer()
                                Text(result.cached ? "CACHED" : "NOT CACHED")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.palette.textMuted)
                            }
                            Text(latencyLine(result))
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.textMuted)
                            if let err = result.error {
                                Text(err)
                                    .font(ARILTheme.captionFont)
                                    .foregroundStyle(theme.palette.danger)
                            } else {
                                Text(result.content)
                                    .font(ARILTheme.bodyFont)
                                    .foregroundStyle(theme.palette.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                Task { await state.preferCompareResult(result) }
                            } label: {
                                Text(state.preferredCompareModel == result.model ? "Preferred ✓" : "Prefer this")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(
                                state.preferredCompareModel == result.model
                                    ? theme.palette.preferredHighlight
                                    : theme.palette.accentStrong
                            )
                            .disabled(result.error != nil)
                        }
                        .padding(12)
                        .frame(width: 320, alignment: .topLeading)
                        .background(theme.palette.backgroundElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    state.preferredCompareModel == result.model
                                        ? theme.palette.preferredHighlight.opacity(0.8)
                                        : theme.palette.hairline,
                                    lineWidth: 1
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
        }
    }

    private func latencyLine(_ result: CompareResultDTO) -> String {
        var parts = ["\(result.latencyMs)ms full"]
        if let probe = result.probeLatencyMs {
            parts.append("\(probe)ms probe")
        }
        parts.append(String(format: "$%.4f", result.costUsd))
        return parts.joined(separator: " · ")
    }

    private func short(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
