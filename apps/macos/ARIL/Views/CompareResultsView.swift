import SwiftUI
import AppKit

struct CompareResultsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let results: [CompareResultDTO]

    private var scores: [String: EquivalenceBreakdown] {
        EquivalenceScore.compute(
            results: results,
            confidenceByModel: state.compareAccuracyDraft
        )
    }

    private var bestESModels: Set<String> {
        EquivalenceScore.bestModels(in: scores)
    }

    private var judgeBanner: String {
        let capability = state.compareRouteCategory?.label ?? "matched"
        return "Judge — prompt classified as \(capability); comparing 3 \(capability) models. ES ranks them; raise Confidence to boost ES; Prefer the highlighted winner."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(judgeBanner)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.accent)
                .padding(.horizontal, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(results) { result in
                        CompareCard(
                            result: result,
                            breakdown: scores[result.model] ?? .zero,
                            isBestES: bestESModels.contains(result.model)
                        )
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
    let breakdown: EquivalenceBreakdown
    let isBestES: Bool
    @State private var showESDetail = false

    private var categoryBinding: Binding<RouteCategory> {
        Binding(
            get: {
                state.compareCategoryDraft[result.model]
                    ?? result.suggestedCategory
                    ?? .general
            },
            set: { newValue in
                var next = state.compareCategoryDraft
                next[result.model] = newValue
                state.compareCategoryDraft = next
            }
        )
    }

    private var confidenceBinding: Binding<Double> {
        Binding(
            get: { state.compareAccuracyDraft[result.model] ?? 0.8 },
            set: { newValue in
                var next = state.compareAccuracyDraft
                next[result.model] = newValue
                state.compareAccuracyDraft = next
            }
        )
    }

    private var isPreferred: Bool {
        state.preferredCompareModel == result.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(short(result.model))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(
                        isPreferred || isBestES
                            ? theme.palette.preferredHighlight
                            : theme.palette.accent
                    )
                Spacer()
                esBadge
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
                ScrollView {
                    Text(result.content)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180, alignment: .top)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.palette.hairline, lineWidth: 1)
                )

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

                    HStack(spacing: 4) {
                        Text("Confidence \(Int(confidenceBinding.wrappedValue * 100))%")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.palette.textMuted)
                        MetricHelpHint(
                            text: "Your confidence in this response. Raising it increases this card’s Equivalence Score (ES) so you can steer the preferred model.",
                            compact: true
                        )
                    }
                    Slider(value: confidenceBinding, in: 0...1, step: 0.05)
                }
            }

            Button {
                Task { await state.preferCompareResult(result) }
            } label: {
                Text(preferLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(preferTint)
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
                .stroke(cardStroke, lineWidth: isBestES || isPreferred ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var esBadge: some View {
        Button {
            showESDetail.toggle()
        } label: {
            Text(String(format: "ES %.0f", breakdown.total))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(
                    isBestES ? theme.palette.preferredHighlight : theme.palette.text
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    (isBestES ? theme.palette.preferredHighlight : theme.palette.accent)
                        .opacity(0.18)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(result.error != nil)
        .help("Equivalence Score — click for metric breakdown")
        .popover(isPresented: $showESDetail, arrowEdge: .bottom) {
            EquivalenceBreakdownPopover(breakdown: breakdown, isBest: isBestES)
                .environmentObject(theme)
        }
    }

    private var preferLabel: String {
        if isPreferred { return "Preferred ✓" }
        if isBestES { return "Prefer this · best ES" }
        return "Prefer this"
    }

    private var preferTint: Color {
        if isPreferred || isBestES {
            return theme.palette.preferredHighlight
        }
        return theme.palette.accentStrong
    }

    private var cardStroke: Color {
        if isPreferred || isBestES {
            return theme.palette.preferredHighlight.opacity(0.85)
        }
        return theme.palette.hairline
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

private struct EquivalenceBreakdownPopover: View {
    @EnvironmentObject private var theme: ThemeStore
    let breakdown: EquivalenceBreakdown
    let isBest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Equivalence Score")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)
                Spacer()
                if isBest {
                    Text("HIGHEST")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.palette.preferredHighlight)
                }
            }
            Text(String(format: "%.0f", breakdown.total))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.palette.text)

            Divider().background(theme.palette.hairline)

            ForEach(breakdown.parts, id: \.label) { part in
                HStack {
                    Text(part.label)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                    Spacer()
                    Text(String(format: "%+.0f", part.value))
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.text)
                        .monospacedDigit()
                }
            }

            Text("Cost, latency, and tokens are relative across the Judge cards (better = higher). Confidence is your slider and adds directly to ES.")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// Per-model Equivalence Score built from Judge metrics + user confidence.
struct EquivalenceBreakdown: Equatable {
    var cost: Double
    var latency: Double
    var tokens: Double
    var category: Double
    var cache: Double
    var confidence: Double

    var total: Double {
        cost + latency + tokens + category + cache + confidence
    }

    var parts: [(label: String, value: Double)] {
        [
            ("Cost (lower better)", cost),
            ("Latency (lower better)", latency),
            ("Tokens (leaner better)", tokens),
            ("Category fit", category),
            ("Cache", cache),
            ("Confidence (you)", confidence),
        ]
    }

    static let zero = EquivalenceBreakdown(
        cost: 0, latency: 0, tokens: 0, category: 0, cache: 0, confidence: 0
    )
}

enum EquivalenceScore {
    static func compute(
        results: [CompareResultDTO],
        confidenceByModel: [String: Double]
    ) -> [String: EquivalenceBreakdown] {
        let usable = results.filter { $0.error == nil }
        guard !usable.isEmpty else {
            return Dictionary(uniqueKeysWithValues: results.map { ($0.model, .zero) })
        }

        let costs = usable.map(\.costUsd)
        let latencies = usable.map { Double($0.latencyMs) }
        let tokens = usable.map { Double($0.inputTokens + $0.outputTokens) }
        let costScores = inverseRelative(costs)
        let latencyScores = inverseRelative(latencies)
        let tokenScores = inverseRelative(tokens)

        var byModel: [String: EquivalenceBreakdown] = [:]
        for (idx, result) in usable.enumerated() {
            let confidence = confidenceByModel[result.model] ?? 0.8
            byModel[result.model] = EquivalenceBreakdown(
                cost: costScores[idx],
                latency: latencyScores[idx],
                tokens: tokenScores[idx],
                category: (result.categoryConfidence ?? 0.5) * 100,
                cache: result.cached ? 25 : 0,
                confidence: confidence * 100
            )
        }
        for result in results where result.error != nil {
            byModel[result.model] = .zero
        }
        return byModel
    }

    static func bestModels(in scores: [String: EquivalenceBreakdown]) -> Set<String> {
        let eligible = scores.filter { $0.value.total > 0 }
        guard let best = eligible.values.map(\.total).max() else { return [] }
        return Set(eligible.compactMap { $0.value.total >= best - 0.001 ? $0.key : nil })
    }

    /// Lower raw values score higher (best → 100, worst → 0). Ties → 100.
    private static func inverseRelative(_ values: [Double]) -> [Double] {
        guard let lo = values.min(), let hi = values.max() else {
            return values.map { _ in 0 }
        }
        if abs(hi - lo) < 1e-12 {
            return values.map { _ in 100 }
        }
        return values.map { ((hi - $0) / (hi - lo)) * 100 }
    }
}
