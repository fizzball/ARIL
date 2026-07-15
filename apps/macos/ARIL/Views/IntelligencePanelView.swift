import SwiftUI

struct IntelligencePanelView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
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
                } else if let source = state.preview?.alternativesSource, source != "none" {
                    Text(source.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.palette.accent.opacity(0.8))
                }

                Spacer()

                if let preview = state.preview, state.analysisStatus == .ready {
                    if preview.userOverride?.categoryOverridden == true {
                        Text("OVERRIDE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.palette.danger)
                    }
                    Text(preview.classification.primary.label.uppercased())
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                    HelpMetricLabel(
                        title: String(format: "%.0f%% fit", preview.classification.confidence * 100),
                        help: "How well the prompt matches the detected category. Higher means routing is more confident."
                    )
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
                readyContent(preview)
            }
        }
        .padding(14)
        .background(theme.palette.analysisFill)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.palette.accent.opacity(0.55), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(theme.palette.colorScheme == .dark ? 0.4 : 0.1), radius: 10, y: 3)
    }

    @ViewBuilder
    private func readyContent(_ preview: PreviewResponse) -> some View {
        HStack(spacing: 16) {
            metric(
                "Grade",
                String(format: "%.0f%%", preview.grade.overall * 100),
                help: "Prompt quality score (clarity, constraints, success criteria, token efficiency) — not model accuracy."
            )
            metric(
                "Tokens",
                "\(preview.cache.estimatedInputTokens)",
                help: tokenHelp(for: preview)
            )
            if let top = preview.routes.first {
                let willCache = preview.cache.eligible && preview.cache.wouldHit
                let costWarning = state.hasConfiguredMCPServers || state.webSearchEnabled
                let baseHelp = "Estimated USD cost for the top recommended route (input + expected output)."
                let warnHelp = "If Web search or MCP servers are used, costs may increase."
                let cacheHelp = "This prompt looks cacheable — expected to hit the prompt cache (shown in green)."
                let systemHelp = "Includes the global system prompt when enabled."
                let costColor: Color? = {
                    if willCache { return Color(red: 0.35, green: 0.78, blue: 0.45) }
                    if costWarning { return Color(red: 0.95, green: 0.80, blue: 0.20) }
                    return nil
                }()
                let costHelp: String = {
                    var parts = [baseHelp]
                    if state.systemPromptEnabled { parts.append(systemHelp) }
                    if willCache { parts.append(cacheHelp) }
                    if costWarning { parts.append(warnHelp) }
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
                    help: "Round-trip probe latency for the recommended model, or last completed request time."
                )
            }
            if let top = preview.routes.first, let idx = top.breakdown?.confidenceIndex {
                metric(
                    "Conf. index",
                    String(format: "%.0f%%", idx * 100),
                    help: "Combined confidence index from category fit, cost, base prior, and learned preferences."
                )
            }
            metric("Category", preview.classification.primary.label)
            judgementIndicator(exists: preview.userOverride != nil)
            metric(
                "Model",
                short(state.routeMode == .manual ? state.selectedModel : preview.recommendedModel),
                valueColor: state.routeMode == .manual ? theme.palette.danger : theme.palette.text,
                help: state.routeMode == .manual
                    ? "Manual mode keeps this model (highlighted red) — ARIL will not swap it."
                    : "Recommended model for this prompt."
            )
            if preview.cache.eligible {
                metric("Cache", preview.cache.wouldHit ? "cached" : "not cached")
            }
        }

        if !preview.grade.notes.isEmpty {
            Text(preview.grade.notes.joined(separator: " "))
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
        }

        if !preview.alternatives.isEmpty {
            Text("Prompt alternatives")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.accent)
            ForEach(preview.alternatives) { alt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(alt.rationale)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.text)
                    Text(alt.text)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(3)
                    HStack {
                        Button("Edit") {
                            state.applyAlternative(alt)
                        }
                        .buttonStyle(.bordered)
                        .help("Copy this recommended prompt into the entry field")
                        Button("Submit") {
                            state.submitAlternative(alt)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.palette.accentStrong)
                        .help("Send this recommended prompt now")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme.palette.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func judgementIndicator(exists: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HelpMetricTitle(
                title: "Judgement",
                help: "Checked when this prompt (or a matching fingerprint) has a Learning judgement — created automatically on first send, or manually via Compare Prefer / Analysis save."
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

    private func short(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func tokenHelp(for preview: PreviewResponse) -> String {
        var help = "Estimated input tokens for the draft prompt (≈4 characters per token)."
        if state.systemPromptEnabled, state.systemPromptTokenEstimate > 0 {
            help += " Includes ~\(state.systemPromptTokenEstimate) tokens from the global system prompt."
        }
        if preview.cache.eligible {
            help += " Prompts above the cache threshold may be cache-eligible."
        }
        return help
    }
}

/// Compact label with hoverable info icon (cursor changes to indicate help is available).
private struct HelpMetricTitle: View {
    @EnvironmentObject private var theme: ThemeStore
    let title: String
    let help: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
            Image(systemName: hovering ? "info.circle.fill" : "info.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? theme.palette.accent : theme.palette.textMuted.opacity(0.7))
                .onHover { hovering = $0 }
        }
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct HelpMetricLabel: View {
    @EnvironmentObject private var theme: ThemeStore
    let title: String
    let help: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Image(systemName: hovering ? "info.circle.fill" : "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(hovering ? theme.palette.accent : theme.palette.textMuted.opacity(0.7))
        }
        .help(help)
        .onHover { hovering = $0 }
    }
}
