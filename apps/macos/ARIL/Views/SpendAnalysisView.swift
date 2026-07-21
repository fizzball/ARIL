import SwiftUI

/// Trailing flyout: spend by model, rolling 7-day total, and calendar-month total.
struct SpendAnalysisView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @State private var isLoading = false

    private var snapshot: SpendAnalysisSnapshot {
        state.spendAnalysisSnapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Spend analysis", systemImage: "dollarsign.circle")
                    .font(ARILTheme.bodyFont.weight(.semibold))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Refresh spend from Learning store + local ledger")
                Button {
                    state.closeToolPanel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(theme.palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(snapshot.sourceNote)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)

                    HStack(spacing: 10) {
                        summaryCard(
                            title: "This month",
                            subtitle: snapshot.monthLabel,
                            value: formatUSD(snapshot.monthlyUsd)
                        )
                        summaryCard(
                            title: "Last 7 days",
                            subtitle: snapshot.weekLabel.replacingOccurrences(of: "Last 7 days ", with: ""),
                            value: formatUSD(snapshot.weeklyUsd)
                        )
                    }

                    HStack {
                        Text("Today")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                        Spacer()
                        Text(formatUSD(snapshot.todayUsd))
                            .font(ARILTheme.bodyFont.weight(.semibold))
                            .foregroundStyle(theme.palette.danger)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Models used")
                            .font(ARILTheme.bodyFont.weight(.semibold))
                            .foregroundStyle(theme.palette.text)
                        Text(
                            snapshot.models.isEmpty
                                ? "No model spend in the current month (or last 7 days)."
                                : "Costs for the current calendar month, sorted by spend."
                        )
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)

                        if snapshot.models.isEmpty {
                            Text("—")
                                .foregroundStyle(theme.palette.textMuted)
                                .padding(.top, 4)
                        } else {
                            ForEach(snapshot.models) { row in
                                modelRow(row)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .task {
            await refresh()
        }
    }

    private func summaryCard(title: String, subtitle: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(ARILTheme.captionFont.weight(.semibold))
                .foregroundStyle(theme.palette.textMuted)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.textMuted.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(ARILTheme.bodyFont.weight(.semibold))
                .foregroundStyle(theme.palette.danger)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.inputFill.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func modelRow(_ row: SpendAnalysisSnapshot.ModelRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.model)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(formatUSD(row.costUsd))
                    .font(ARILTheme.captionFont.weight(.semibold))
                    .foregroundStyle(theme.palette.danger)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.palette.hairline.opacity(0.5))
                    Capsule()
                        .fill(theme.palette.accentStrong)
                        .frame(width: max(4, geo.size.width * row.share))
                }
            }
            .frame(height: 4)
            Text(String(format: "%.0f%% of month", row.share * 100))
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.textMuted)
        }
        .padding(.vertical, 6)
    }

    private func formatUSD(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await state.refreshSpendAnalysis()
    }
}
