import SwiftUI

struct RoutingAnalysisView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var editCategory: RouteCategory = .general
    @State private var editAccuracy: Double = 0.8
    @State private var hasAccuracy = false
    @State private var categoryOverridden = false

    private var preview: PreviewResponse? { state.preview }
    private var topRoute: ModelEstimate? { preview?.routes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Routing analysis")
                    .font(ARILTheme.wordmarkFont)
                    .foregroundStyle(theme.palette.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().background(theme.palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let grade = preview?.grade {
                        sectionTitle("Prompt grade metrics")
                        metricRow(
                            "Clarity",
                            grade.clarity,
                            help: "How clear and unambiguous the prompt is. Vague asks score lower."
                        )
                        metricRow(
                            "Constraints",
                            grade.constraints,
                            help: "Whether the prompt states limits, format, or what to avoid."
                        )
                        metricRow(
                            "Success criteria",
                            grade.successCriteria,
                            help: "Whether the prompt defines what a good answer looks like."
                        )
                        metricRow(
                            "Token efficiency",
                            grade.tokenEfficiency,
                            help: "How concise the prompt is relative to the ask — padding lowers this score."
                        )
                        metricRow(
                            "Overall grade",
                            grade.overall,
                            emphasize: true,
                            help: "Combined prompt quality (not model accuracy). Used when suggesting rewrites."
                        )
                    }

                    if let breakdown = topRoute?.breakdown {
                        sectionTitle("Model selection — confidence index")
                        Text(short(topRoute?.modelId ?? state.selectedModel))
                            .font(ARILTheme.bodyFont)
                            .foregroundStyle(theme.palette.accent)
                        if let reason = preview?.preferenceReason, !reason.isEmpty {
                            Text(reason)
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        metricRow(
                            "Category fit",
                            breakdown.categoryFit,
                            help: "How well the prompt matches the recommended model’s routing category."
                        )
                        metricRow(
                            "Cost efficiency",
                            breakdown.cost,
                            help: "Relative cost score for this route — cheaper routes score higher here."
                        )
                        metricRow(
                            "Base prior",
                            breakdown.base,
                            help: "Built-in prior for the model before Learning adjustments."
                        )
                        metricRow(
                            "Learning boost",
                            breakdown.learning,
                            help: "Lift from your saved judgements / Prefer history for like prompts."
                        )
                        metricRow(
                            "Confidence index",
                            breakdown.confidenceIndex,
                            emphasize: true,
                            help: "Combined index from category fit, cost, base prior, and Learning. Higher means ARIL is more sure of this pick."
                        )

                        if let reasons = topRoute?.reasons, !reasons.isEmpty {
                            Text(reasons.joined(separator: " "))
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.textMuted)
                        }
                    }

                    sectionTitle("Your overrides")
                    HStack(spacing: 6) {
                        Toggle(isOn: .constant(preview?.userOverride != nil)) {
                            Text("Judgement exists")
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.text)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(true)
                        MetricHelpHint(
                            text: "Checked when this query has a Learning judgement (auto on first Auto send, or Compare Prefer / Analysis save). Manual sends never write judgements."
                        )
                    }

                    if let override = preview?.userOverride {
                        if preview?.analysisSkipped == true {
                            HStack(alignment: .center, spacing: 10) {
                                Text("Analysis skipped — reused this judgement (assumed acceptable).")
                                    .font(ARILTheme.captionFont)
                                    .foregroundStyle(theme.palette.textMuted)
                                Spacer(minLength: 8)
                                Button("Redo Analysis") {
                                    state.showRoutingAnalysis = false
                                    Task { await state.redoAnalysis() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Re-run full prompt analysis and update this Learning judgement")
                            }
                        }
                        Text(override.categoryOverridden
                              ? "Category manually overridden for like prompts."
                              : "Saved classification from a previous judgment.")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                        if let acc = override.accuracy {
                            Text("Saved accuracy: \(Int(acc * 100))%")
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.textMuted)
                        }
                    } else {
                        Text("No judgment on the Learning list for this prompt yet.")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                    }

                    Picker("Category", selection: $editCategory) {
                        ForEach(RouteCategory.allCases) { cat in
                            Text(cat.label).tag(cat)
                        }
                    }
                    Toggle("Treat as manual category override", isOn: $categoryOverridden)
                    Toggle("Set accuracy", isOn: $hasAccuracy)
                    if hasAccuracy {
                        HStack {
                            Text("Accuracy \(Int(editAccuracy * 100))%")
                                .font(ARILTheme.captionFont)
                            Slider(value: $editAccuracy, in: 0...1, step: 0.05)
                        }
                    }

                    Button("Save for future like queries") {
                        Task {
                            await state.saveAnalysisOverride(
                                category: editCategory,
                                accuracy: hasAccuracy ? editAccuracy : nil,
                                overridden: categoryOverridden
                            )
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.palette.accentStrong)
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 520)
        .background(theme.palette.backgroundElevated)
        .onAppear {
            if let c = preview?.classification.primary {
                editCategory = preview?.userOverride?.category ?? c
            }
            if let acc = preview?.userOverride?.accuracy {
                hasAccuracy = true
                editAccuracy = acc
            }
            categoryOverridden = preview?.userOverride?.categoryOverridden ?? false
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.palette.accent)
    }

    private func metricRow(
        _ title: String,
        _ value: Double,
        emphasize: Bool = false,
        help: String
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                MetricHelpHint(text: help, compact: true)
            }
            Spacer()
            Text(String(format: "%.0f%%", value * 100))
                .font(emphasize ? ARILTheme.bodyFont : ARILTheme.captionFont)
                .foregroundStyle(emphasize ? theme.palette.accent : theme.palette.text)
            ProgressView(value: min(1, max(0, value)))
                .frame(width: 80)
        }
    }

    private func short(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
