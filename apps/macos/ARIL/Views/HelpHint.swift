import SwiftUI

/// Info control that shows help in a popover (more reliable than native `.help` in sheets / dense strips).
struct MetricHelpHint: View {
    @EnvironmentObject private var theme: ThemeStore
    let text: String
    var compact: Bool = false
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: showing ? "info.circle.fill" : "info.circle")
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
                .foregroundStyle(showing ? theme.palette.accent : theme.palette.textMuted.opacity(0.85))
                .contentShape(Rectangle())
                .frame(minWidth: 16, minHeight: 16)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.text)
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environmentObject(theme)
        }
        .accessibilityLabel("Help")
        .accessibilityHint(text)
    }
}

/// Title + help hint used for metric captions.
struct HelpMetricTitle: View {
    @EnvironmentObject private var theme: ThemeStore
    let title: String
    let help: String
    var uppercase: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Text(uppercase ? title.uppercased() : title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
            MetricHelpHint(text: help, compact: true)
        }
    }
}

/// Inline label (e.g. "72% fit") with a help hint.
struct HelpMetricLabel: View {
    @EnvironmentObject private var theme: ThemeStore
    let title: String
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            MetricHelpHint(text: help, compact: true)
        }
    }
}
