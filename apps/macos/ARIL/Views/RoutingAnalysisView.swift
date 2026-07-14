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
                        metricRow("Clarity", grade.clarity)
                        metricRow("Constraints", grade.constraints)
                        metricRow("Success criteria", grade.successCriteria)
                        metricRow("Token efficiency", grade.tokenEfficiency)
                        metricRow("Overall grade", grade.overall, emphasize: true)
                    }

                    if let breakdown = topRoute?.breakdown {
                        sectionTitle("Model selection — confidence index")
                        Text(short(topRoute?.modelId ?? state.selectedModel))
                            .font(ARILTheme.bodyFont)
                            .foregroundStyle(theme.palette.accent)
                        metricRow("Category fit", breakdown.categoryFit)
                        metricRow("Cost efficiency", breakdown.cost)
                        metricRow("Base prior", breakdown.base)
                        metricRow("Learning boost", breakdown.learning)
                        metricRow("Confidence index", breakdown.confidenceIndex, emphasize: true)

                        if let reasons = topRoute?.reasons, !reasons.isEmpty {
                            Text(reasons.joined(separator: " "))
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.textMuted)
                        }
                    }

                    sectionTitle("Your overrides")
                    if let override = preview?.userOverride {
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
                        Text("No manual override for this prompt yet.")
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

    private func metricRow(_ title: String, _ value: Double, emphasize: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
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
