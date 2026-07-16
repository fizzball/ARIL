import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var systemMetrics = SystemMetricsMonitor()

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } detail: {
                VStack(spacing: 0) {
                    if state.gatewayReady && !state.openRouterConfigured {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                            Text("OpenRouter API key required — add it in Preferences to enable live models.")
                                .font(ARILTheme.captionFont)
                            Spacer()
                            Button("Open Preferences") {
                                openSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(theme.palette.accentStrong)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(theme.palette.danger.opacity(0.92))
                    }

                    ChatDetailView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if state.activeToolPanel != nil {
                ToolFlyoutPanel()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(theme.palette.background)
        .animation(.easeInOut(duration: 0.22), value: state.activeToolPanel)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SystemMetricsTitleView(metrics: systemMetrics)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.openToolPanel(.learning)
                } label: {
                    Image(systemName: "brain")
                }
                .help("Learning — stored judgements and classifications")

                Button {
                    state.openToolPanel(.modelCosts)
                } label: {
                    Image(systemName: "dollarsign.circle")
                }
                .help("Selected model costs (OpenRouter)")

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Preferences")

                Button {
                    state.openToolPanel(.about)
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("About ARIL")

                Button {
                    state.shutdown()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .help("Quit ARIL")
            }
        }
        .preferredColorScheme(theme.palette.colorScheme)
        .task {
            systemMetrics.start()
            // Health only — bootstrap owns the first session load to avoid a selection race.
            await state.refreshHealth(reloadSessionsOnReady: false)
        }
        .onDisappear {
            systemMetrics.stop()
        }
    }
}
