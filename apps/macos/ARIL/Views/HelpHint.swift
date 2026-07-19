import SwiftUI
import AppKit

/// Toolbar / control hover help. Native SwiftUI `.help` is often suppressed inside toolbar
/// groups; this wires AppKit `toolTip` (the macOS help bubble) plus accessibility labels.
struct HoverHelpBubble: ViewModifier {
    let title: String
    let detail: String

    private var combined: String {
        detail.isEmpty ? title : "\(title) — \(detail)"
    }

    func body(content: Content) -> some View {
        content
            .help(combined)
            .accessibilityLabel(title)
            .accessibilityHint(detail.isEmpty ? combined : detail)
            .background(AppKitTooltipHost(text: combined))
    }
}

extension View {
    /// Mouseover help bubble (title + optional detail) for toolbar and icon controls.
    func hoverHelpBubble(_ title: String, detail: String = "") -> some View {
        modifier(HoverHelpBubble(title: title, detail: detail))
    }
}

/// Invisible AppKit host so `toolTip` still appears when SwiftUI `.help` is ignored.
private struct AppKitTooltipHost: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TrackingTooltipView {
        let view = TrackingTooltipView()
        view.applyTooltip(text)
        return view
    }

    func updateNSView(_ nsView: TrackingTooltipView, context: Context) {
        nsView.applyTooltip(text)
    }
}

/// Expands to the parent control’s bounds so hover targets the tooltip host.
private final class TrackingTooltipView: NSView {
    private var tooltipText: String = ""

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTooltipToSuperview()
    }

    override func layout() {
        super.layout()
        syncTooltipToSuperview()
    }

    func applyTooltip(_ text: String) {
        tooltipText = text
        toolTip = text
        syncTooltipToSuperview()
    }

    private func syncTooltipToSuperview() {
        // Prefer putting the tip on the enclosing control so hover covers the full button.
        var host: NSView? = superview
        while let view = host {
            if view is NSControl || view is NSButton {
                view.toolTip = tooltipText
                return
            }
            host = view.superview
        }
    }
}

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
