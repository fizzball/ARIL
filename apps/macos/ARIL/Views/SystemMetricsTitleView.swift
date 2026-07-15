import SwiftUI

/// Compact CPU / memory / disk percentages for the window title toolbar.
struct SystemMetricsTitleView: View {
    @ObservedObject var metrics: SystemMetricsMonitor
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        HStack(spacing: 14) {
            metric(
                symbol: "cpu",
                label: "CPU",
                value: metrics.cpuReady ? metrics.cpuPercent : nil,
                help: "System CPU use"
            )
            metric(
                symbol: "memorychip",
                label: "MEM",
                value: metrics.memoryPercent,
                help: "Physical memory in use (active + wired + compressed)"
            )
            metric(
                symbol: "internaldrive",
                label: "DISK",
                value: metrics.diskPercent,
                help: "Home volume disk space in use"
            )
        }
        .padding(.horizontal, 8)
        .help("Machine metrics while ARIL is running")
    }

    private func metric(
        symbol: String,
        label: String,
        value: Double?,
        help: String
    ) -> some View {
        let percent = value
        let high = (percent ?? 0) >= 85
        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(high ? theme.palette.danger : theme.palette.textMuted)
            Text(label)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Text(formatted(percent))
                .font(ARILTheme.captionFont.monospacedDigit())
                .foregroundStyle(high ? theme.palette.danger : theme.palette.text)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(formatted(percent))")
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }
}
