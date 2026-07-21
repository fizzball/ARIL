import SwiftUI

struct IntelligencePanelView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    /// Cap the panel so a long analysis (metrics + alternatives) never pushes the
    /// prompt entry bar off the bottom of the window; overflow scrolls internally.
    private let maxPanelHeight: CGFloat = 320
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            panelContent
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: IntelligencePanelHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .frame(height: min(contentHeight, maxPanelHeight))
        .onPreferenceChange(IntelligencePanelHeightKey.self) { contentHeight = $0 }
        .background(theme.palette.analysisFill)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.palette.accent.opacity(0.55), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(theme.palette.colorScheme == .dark ? 0.4 : 0.1), radius: 10, y: 3)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Intelligence", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)

                if case .analysing(let remaining) = state.analysisStatus {
                    Text(remaining > 0
                          ? String(format: "Analysing prompt… %.1fs", remaining)
                          : "Analysing prompt…")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if state.preview?.analysisSkipped == true {
                    Text("JUDGEMENT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.palette.accent.opacity(0.8))
                        .help("Prompt analysis skipped — reused Learning judgement to save tokens.")
                } else if let source = state.preview?.alternativesSource, source != "none" {
                    Text(source.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.palette.accent.opacity(0.8))
                }

                Spacer()

                if let preview = state.preview, state.analysisStatus == .ready {
                    let skipped = preview.analysisSkipped == true
                    if preview.userOverride?.categoryOverridden == true {
                        Text("OVERRIDE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.palette.danger)
                    }
                    Text(preview.classification.primary.label.uppercased())
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                        .opacity(skipped ? 0.55 : 1)
                    HelpMetricLabel(
                        title: String(format: "%.0f%% fit", preview.classification.confidence * 100),
                        help: skipped
                            ? "Category fit from the reused Learning judgement (analysis not re-run)."
                            : "How well the prompt matches the detected category. Higher means routing is more confident."
                    )
                    .opacity(skipped ? 0.55 : 1)
                    Button("Analysis") {
                        state.showRoutingAnalysis = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show how the model was selected (confidence index)")
                }
            }

            if case .analysing(let remaining) = state.analysisStatus {
                Text(remaining > 0
                      ? String(format: "Pause typing for %.1fs to finish analysis. Editing resets the timer.", remaining)
                      : "Running classification, grading, and route scoring…")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
            }

            if let preview = state.preview, state.analysisStatus == .ready {
                if preview.analysisSkipped == true {
                    HStack(alignment: .center, spacing: 10) {
                        Text("Previously analysed — Learning judgement reused (assumed acceptable).")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                        Spacer(minLength: 8)
                        Button("Redo Analysis") {
                            Task { await state.redoAnalysis() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Re-run full prompt analysis and update the existing Learning judgement")
                    }
                }
                readyContent(preview)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func readyContent(_ preview: PreviewResponse) -> some View {
        let skipped = preview.analysisSkipped == true
        let muted = theme.palette.textMuted
        let valueColor = skipped ? muted : theme.palette.text

        HStack(spacing: 16) {
            metric(
                "Grade",
                String(format: "%.0f%%", preview.grade.overall * 100),
                valueColor: valueColor,
                help: "Prompt quality score (clarity, constraints, success criteria, token efficiency) — not model accuracy."
            )
            metric(
                "Tokens",
                "\(preview.cache.estimatedInputTokens)",
                valueColor: valueColor,
                help: tokenHelp(for: preview)
            )
            if let top = preview.routes.first {
                let willCache = preview.cache.eligible && preview.cache.wouldHit
                let costWarning = state.hasConfiguredMCPServers || state.webSearchEnabled
                let baseHelp = "Estimated USD cost for the top recommended route (input + expected output)."
                let warnHelp = "If Web search is on, or MCP servers are enabled for a future tool-using turn, costs may increase."
                let cacheHelp = "This prompt looks cacheable — expected to hit the prompt cache (shown in green)."
                let systemHelp = "Includes the global system prompt when enabled."
                let costColor: Color? = {
                    if skipped { return muted }
                    if willCache { return Color(red: 0.35, green: 0.78, blue: 0.45) }
                    if costWarning { return Color(red: 0.95, green: 0.80, blue: 0.20) }
                    return nil
                }()
                let costHelp: String = {
                    var parts = [baseHelp]
                    if state.systemPromptEnabled { parts.append(systemHelp) }
                    if willCache { parts.append(cacheHelp) }
                    if costWarning { parts.append(warnHelp) }
                    if skipped { parts.append("Greyed because analysis was skipped for a Learning judgement.") }
                    return parts.joined(separator: " ")
                }()
                metric(
                    "est. Cost",
                    String(format: "$%.4f", top.estimatedCostUsd),
                    valueColor: costColor,
                    help: costHelp
                )
            }
            if let latency = state.estimatedLatencyMs ?? state.lastLatencyMs {
                metric(
                    "Latency",
                    "\(latency)ms",
                    valueColor: valueColor,
                    help: "Round-trip probe latency for the recommended model, or last completed request time."
                )
            }
            if let top = preview.routes.first, let idx = top.breakdown?.confidenceIndex {
                metric(
                    "Conf. index",
                    String(format: "%.0f%%", idx * 100),
                    valueColor: valueColor,
                    help: "Combined confidence index from category fit, cost, base prior, and learned preferences."
                )
            }
            metric("Category", preview.classification.primary.label, valueColor: valueColor)
            judgementIndicator(exists: preview.userOverride != nil)
            metric(
                "Model",
                short(state.routeMode == .manual ? state.selectedModel : preview.recommendedModel),
                valueColor: skipped
                    ? muted
                    : (state.routeMode == .manual ? theme.palette.danger : theme.palette.text),
                help: state.routeMode == .manual
                    ? "Manual mode keeps this model (highlighted red) — ARIL will not swap it."
                    : "Recommended model for this prompt."
            )
            if let reason = preview.preferenceReason, !reason.isEmpty, state.routeMode == .auto {
                Text(reason)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Auto is using a model you Preferred in Learning / Judge.")
            }
            cacheStatusMetric(preview.cache, valueColor: valueColor, skipped: skipped)
        }
        .opacity(skipped ? 0.55 : 1)

        cacheOfferSection(preview.cache, skipped: skipped)

        if !preview.grade.notes.isEmpty {
            Text(preview.grade.notes.joined(separator: " "))
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
        }

        if !preview.alternatives.isEmpty {
            Text("Prompt alternatives")
                .font(ARILTheme.captionFont)
                .foregroundStyle(skipped ? muted : theme.palette.accent)
            ForEach(preview.alternatives) { alt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(alt.rationale)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(skipped ? muted : theme.palette.text)
                    Text(alt.text)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(3)
                    HStack {
                        Button("Edit") {
                            state.applyAlternative(alt)
                        }
                        .buttonStyle(.bordered)
                        .disabled(skipped)
                        .help("Copy this recommended prompt into the entry field")
                        Button("Submit") {
                            state.submitAlternative(alt)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.palette.accentStrong)
                        .disabled(skipped)
                        .help("Send this recommended prompt now")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme.palette.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(skipped ? 0.55 : 1)
            }
        }

        HStack {
            Text("Temperature")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Slider(value: $state.temperature, in: 0...1, step: 0.1)
            Text(String(format: "%.1f", state.temperature))
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.text)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var cacheHitGreen: Color {
        Color(red: 0.35, green: 0.78, blue: 0.45)
    }

    @ViewBuilder
    private func cacheStatusMetric(_ cache: CacheInsight, valueColor: Color, skipped: Bool) -> some View {
        let label: String = {
            if cache.wouldHit { return "hit" }
            if cache.eligible { return "eligible" }
            if cache.tokensToEligible > 0, cache.tokensToEligible <= max(128, cache.threshold / 4) {
                return "~\(cache.tokensToEligible) short"
            }
            return "n/a"
        }()
        let color: Color = {
            if skipped { return theme.palette.textMuted }
            if cache.wouldHit { return cacheHitGreen }
            if cache.eligible { return theme.palette.accent }
            return valueColor
        }()
        let help: String = {
            if cache.wouldHit {
                let pct = cache.estimatedSavingsPct.map { Int($0) } ?? 55
                return "This prompt will hit the gateway prompt cache (~\(pct)% savings vs a fresh completion)."
            }
            if cache.eligible {
                return "Above the \(cache.threshold)-token cache threshold — first send seeds the cache; an identical resend hits it."
            }
            if cache.tokensToEligible > 0 {
                return "About \(cache.tokensToEligible) more input tokens needed to become cache-eligible (threshold \(cache.threshold))."
            }
            return "Prompts over \(cache.threshold) estimated input tokens are cache-eligible."
        }()
        metric("Cache", label, valueColor: color, help: help)
    }

    @ViewBuilder
    private func cacheOfferSection(_ cache: CacheInsight, skipped: Bool) -> some View {
        if cache.wouldHit {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(cacheHitGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompt cache hit")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(cacheHitGreen)
                    Text(cacheHitSubmitDetail(cache))
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                }
                Spacer(minLength: 8)
                Button("Submit") {
                    state.send()
                }
                .buttonStyle(.borderedProminent)
                .tint(cacheHitGreen)
                .controlSize(.small)
                .disabled(skipped || state.isSending)
                .help("Send now and hit the prompt cache")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cacheHitGreen.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(skipped ? 0.55 : 1)
        } else if let offered = cache.suggestedHitPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !offered.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(theme.palette.accent)
                    Text("Cached prompt available")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)
                }
                Text(cache.suggestedHitRationale ?? "Use this prior prompt to hit the prompt cache.")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                Text(offered)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(4)
                HStack {
                    Button("Edit") {
                        state.applyCacheHitPrompt(offered)
                    }
                    .buttonStyle(.bordered)
                    .disabled(skipped)
                    .help("Copy the cached prompt into the entry field")
                    Button("Submit") {
                        state.submitCacheHitPrompt(offered)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.palette.accentStrong)
                    .disabled(skipped || state.isSending)
                    .help("Send the cached prompt now for a cache hit")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(skipped ? 0.55 : 1)
        } else if cache.eligible {
            Text("Cache eligible — first send seeds the prompt cache for identical repeats.")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
                .opacity(skipped ? 0.55 : 1)
        }
    }

    private func judgementIndicator(exists: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HelpMetricTitle(
                title: "Judgement",
                help: "Checked when this prompt (or a matching fingerprint) has a Learning judgement — created automatically on first Auto send, or via Compare Prefer / Analysis save. Manual mode does not write judgements."
            )
            Toggle("", isOn: .constant(exists))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
                .accessibilityLabel(exists ? "Judgement exists" : "No judgement")
                .help(
                    exists
                        ? "A judgment for this query is on the Learning list."
                        : "No judgment saved yet for this query."
                )
        }
    }

    private func metric(
        _ title: String,
        _ value: String,
        valueColor: Color? = nil,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let help {
                HelpMetricTitle(title: title, help: help)
            } else {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.textMuted)
            }
            Text(value)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(valueColor ?? theme.palette.text)
                .lineLimit(1)
        }
    }

    private func cacheHitSubmitDetail(_ cache: CacheInsight) -> String {
        let pct = cache.estimatedSavingsPct.map { Int($0) } ?? 55
        return "Submit this draft to reuse the cached reply (~\(pct)% savings)."
    }

    private func short(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func tokenHelp(for preview: PreviewResponse) -> String {
        var help = "Estimated input tokens for the draft prompt (≈4 characters per token)."
        if state.systemPromptEnabled, state.systemPromptTokenEstimate > 0 {
            help += " Includes ~\(state.systemPromptTokenEstimate) tokens from the global system prompt."
        }
        if preview.cache.eligible {
            help += " Prompts above the \(preview.cache.threshold)-token cache threshold are cache-eligible."
        } else if preview.cache.tokensToEligible > 0 {
            help += " About \(preview.cache.tokensToEligible) more tokens to reach the \(preview.cache.threshold)-token cache threshold."
        }
        return help
    }
}

private struct IntelligencePanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
