import SwiftUI
import AppKit

struct CompareResultsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let results: [CompareResultDTO]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare — 3 models analysed. Adjust category / accuracy, then Prefer to teach routing.")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.accent)
                .padding(.horizontal, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(results) { result in
                        CompareCard(result: result)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct CompareCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let result: CompareResultDTO

    private var categoryBinding: Binding<RouteCategory> {
        Binding(
            get: {
                state.compareCategoryDraft[result.model]
                    ?? result.suggestedCategory
                    ?? .general
            },
            set: { state.compareCategoryDraft[result.model] = $0 }
        )
    }

    private var accuracyBinding: Binding<Double> {
        Binding(
            get: { state.compareAccuracyDraft[result.model] ?? 0.8 },
            set: { state.compareAccuracyDraft[result.model] = $0 }
        )
    }

    var body: some View {
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
                    .frame(maxHeight: 180, alignment: .top)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Response category")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                    Picker("Category", selection: categoryBinding) {
                        ForEach(RouteCategory.allCases) { cat in
                            Text(cat.label).tag(cat)
                        }
                    }
                    .labelsHidden()
                    if let suggested = result.suggestedCategory {
                        Text("Suggested: \(suggested.label) (\(Int((result.categoryConfidence ?? 0) * 100))%)")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                    }

                    Text("Accuracy \(Int(accuracyBinding.wrappedValue * 100))%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                    Slider(value: accuracyBinding, in: 0...1, step: 0.05)
                }
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

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.content, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(result.error != nil || result.content.isEmpty)
        }
        .padding(12)
        .frame(width: 300, alignment: .topLeading)
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
