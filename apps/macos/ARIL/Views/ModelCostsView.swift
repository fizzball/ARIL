import SwiftUI

/// Popover listing selected routing-model rates and optional Web Search fee.
struct ModelCostsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    private var rows: [(category: String, model: String)] {
        var out: [(String, String)] = []
        out.append(("Active", state.selectedModel))
        for category in RouteCategory.allCases {
            let model = state.routingProfile.model(for: category)
            out.append((category.label, model))
        }
        // Deduplicate model repeats while keeping first (Active) then category rows.
        var seen = Set<String>()
        var unique: [(String, String)] = []
        for row in out {
            let key = "\(row.0)|\(row.1)"
            if seen.insert(key).inserted {
                unique.append(row)
            }
        }
        return unique.map { ($0.0, $0.1) }
    }

    private var webSearchFee: Double {
        if let fee = state.modelPricingByID[state.selectedModel]?.webSearchFee {
            return fee
        }
        return 0.005
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model costs")
                    .font(ARILTheme.bodyFont.weight(.semibold))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                if state.isLoadingModelPricing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("OpenRouter USD rates — input / output per 1K tokens.")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)

            Divider().overlay(theme.palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        costRow(category: row.category, model: row.model)
                    }

                    if state.webSearchEnabled {
                        Divider().overlay(theme.palette.hairline)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("OpenRouter Web Search")
                                    .font(ARILTheme.bodyFont)
                                    .foregroundStyle(theme.palette.text)
                                Text("Extra fee when Web is on (per search). Grounding tokens still bill at the model’s input rate.")
                                    .font(ARILTheme.captionFont)
                                    .foregroundStyle(theme.palette.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Text(String(format: "$%.4f / search", webSearchFee))
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.accent)
                                .monospacedDigit()
                                .frame(minWidth: 140, alignment: .trailing)
                        }
                    }
                }
                .padding(.trailing, 10)
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .padding(.trailing, 4)
        .frame(width: 520)
        .background(theme.palette.backgroundElevated)
        .task {
            await state.refreshModelPricing(forceRefresh: false)
        }
    }

    private func costRow(category: String, model: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                Text(short(model))
                    .font(ARILTheme.bodyFont)
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let price = state.pricingLabel(for: model) {
                Text(price)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)
                    .monospacedDigit()
                    .frame(minWidth: 140, alignment: .trailing)
            } else {
                Text("—")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                    .frame(minWidth: 140, alignment: .trailing)
            }
        }
    }

    private func short(_ id: String) -> String {
        id
    }
}
