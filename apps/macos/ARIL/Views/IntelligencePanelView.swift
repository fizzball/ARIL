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
                    Text(remaining > 0 ? "Analysing prompt… \(remaining)s" : "Analysing prompt…")
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
                    Text(preview.classification.primary.label.uppercased())
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                    Text(String(format: "%.0f%% fit", preview.classification.confidence * 100))
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                }
            }

            if case .analysing(let remaining) = state.analysisStatus {
                Text(remaining > 0
                      ? "Pause typing for \(remaining)s to finish analysis. Editing resets the timer."
                      : "Running classification, grading, and route scoring…")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
            }

            if let preview = state.preview, state.analysisStatus == .ready {
                readyContent(preview)
            }
        }
        .padding(14)
        .background(theme.palette.backgroundElevated.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.palette.accent.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func readyContent(_ preview: PreviewResponse) -> some View {
        HStack(spacing: 16) {
            metric(
                "Prompt Grade",
                String(format: "%.0f%%", preview.grade.overall * 100),
                help: "Prompt quality score (clarity, constraints, success criteria, token efficiency) — not model accuracy."
            )
            metric("Est. tokens", "\(preview.cache.estimatedInputTokens)")
            if let top = preview.routes.first {
                metric("Est. cost", String(format: "$%.4f", top.estimatedCostUsd))
            }
            metric("Category", preview.classification.primary.label)
            metric("Model", short(preview.recommendedModel))
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
                        Button("Use in editor") {
                            state.applyAlternative(alt)
                        }
                        .buttonStyle(.borderless)
                        Button("Submit suggestion") {
                            state.submitAlternative(alt)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.palette.accentStrong)
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
            Slider(value: $state.temperature, in: 0...2, step: 0.1)
            Text(String(format: "%.1f", state.temperature))
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.text)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func metric(_ title: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
            Text(value)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(theme.palette.text)
                .lineLimit(1)
        }
        .help(help ?? "")
    }

    private func short(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
