import SwiftUI

struct IntelligencePanelView: View {
    @EnvironmentObject private var state: AppState
    let preview: PreviewResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Intelligence", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.gold)
                if let source = preview.alternativesSource, source != "none" {
                    Text(source.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ARILTheme.gold.opacity(0.8))
                }
                Spacer()
                Text(preview.classification.primary.label.uppercased())
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.creamMuted)
                Text(String(format: "%.0f%% fit", preview.classification.confidence * 100))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.creamMuted)
            }

            HStack(spacing: 16) {
                metric("Grade", String(format: "%.0f%%", preview.grade.overall * 100))
                metric("Est. tokens", "\(preview.cache.estimatedInputTokens)")
                if let top = preview.routes.first {
                    metric("Est. cost", String(format: "$%.4f", top.estimatedCostUsd))
                }
                metric("Model", short(preview.recommendedModel))
                if preview.cache.eligible {
                    metric(
                        "Cache",
                        preview.cache.wouldHit
                            ? "hit ~\(Int(preview.cache.estimatedSavingsPct ?? 0))%"
                            : "eligible"
                    )
                }
            }

            if !preview.grade.notes.isEmpty {
                Text(preview.grade.notes.joined(separator: " "))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.creamMuted)
            }

            if !preview.alternatives.isEmpty {
                Text("Prompt alternatives")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.gold)
                ForEach(preview.alternatives) { alt in
                    Button {
                        state.applyAlternative(alt)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alt.rationale)
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(ARILTheme.cream)
                            Text(alt.text)
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(ARILTheme.creamMuted)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(ARILTheme.backgroundElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("Temperature")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.creamMuted)
                Slider(value: $state.temperature, in: 0...2, step: 0.1)
                Text(String(format: "%.1f", state.temperature))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.cream)
                    .frame(width: 28, alignment: .trailing)

                Picker("Mode", selection: $state.routeMode) {
                    ForEach(RouteMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
        .padding(14)
        .background(ARILTheme.backgroundElevated.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ARILTheme.gold.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ARILTheme.creamMuted)
            Text(value)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(ARILTheme.cream)
                .lineLimit(1)
        }
    }

    private func short(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
