import SwiftUI

/// Full-height trailing column for toolbar tools (Model popularity, Learning, About).
struct ToolFlyoutPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        Group {
            switch state.activeToolPanel {
            case .modelPopularity:
                ModelPopularityView()
            case .learning:
                LearningView()
            case .about:
                AboutView()
            case .none:
                EmptyView()
            }
        }
        .frame(width: ToolPanel.flyoutWidth)
        .frame(maxHeight: .infinity)
        .background(theme.palette.backgroundElevated)
        .preferredColorScheme(theme.palette.colorScheme)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.palette.hairline)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
    }
}
