import SwiftUI

/// Full-height trailing column for toolbar tools (Model popularity, Log analysis, Learning, About).
struct ToolFlyoutPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        Group {
            switch state.activeToolPanel {
            case .modelPopularity:
                ModelPopularityView()
            case .logAnalysis:
                LogAnalysisView()
            case .learning:
                LearningView()
            case .spendAnalysis:
                SpendAnalysisView()
            case .about:
                AboutView()
            case .none:
                EmptyView()
            }
        }
        .frame(width: ToolPanel.flyoutWidth)
        .frame(maxHeight: .infinity)
        .background(theme.palette.backgroundElevated)
        .preferredColorScheme(theme.preferredColorScheme)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.palette.hairline)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
    }
}
