import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var systemMetrics = SystemMetricsMonitor()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    VStack(spacing: 0) {
                        if state.gatewayReady && !state.openRouterConfigured {
                            HStack(spacing: 10) {
                                Image(systemName: "key.fill")
                                Text("OpenRouter subscription required — connect in Preferences → Subscription to enable live models.")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Full-width tray under sidebar + chat (+ tool flyout when open).
            StatusFooterView()
        }
        .background(theme.palette.background)
        .background(WindowTitleVisibilityHidden())
        .animation(.easeInOut(duration: 0.22), value: state.activeToolPanel)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ARILTitleWordmarkView()
            }
            ToolbarItem(placement: .principal) {
                SystemMetricsTitleView(metrics: systemMetrics)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.openToolPanel(.spendAnalysis)
                } label: {
                    Image(systemName: "dollarsign.circle")
                }
                .hoverHelpBubble("Spend analysis", detail: "Models, weekly, and monthly OpenRouter spend")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.openToolPanel(.learning)
                } label: {
                    Image(systemName: "brain")
                }
                .hoverHelpBubble("Learning", detail: "Stored judgements and classifications")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.openToolPanel(.modelPopularity)
                } label: {
                    Image(systemName: "chart.bar.fill")
                }
                .hoverHelpBubble("Model popularity", detail: "OpenRouter weekly rankings by token volume")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.openToolPanel(.logAnalysis)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .hoverHelpBubble("Log analysis", detail: "Recent OpenRouter API transactions")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .hoverHelpBubble("Preferences", detail: "Gateway, subscription, models, and appearance")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.shutdown()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .hoverHelpBubble("Quit ARIL")
            }
        }
        .preferredColorScheme(theme.preferredColorScheme)
        .alert(
            "Budget warning",
            isPresented: Binding(
                get: { state.budgetConfirmMessage != nil },
                set: { if !$0 { state.respondToBudgetConfirm(false) } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                state.respondToBudgetConfirm(false)
            }
            Button("Send anyway") {
                state.respondToBudgetConfirm(true)
            }
        } message: {
            Text(state.budgetConfirmMessage ?? "")
        }
        .alert(
            "Context window almost full",
            isPresented: Binding(
                get: { state.contextLimitMessage != nil },
                set: { if !$0 { state.respondToContextLimit(.cancel) } }
            )
        ) {
            Button("Start New Session") {
                state.respondToContextLimit(.newSession)
            }
            Button("Continue") {
                state.respondToContextLimit(.proceed)
            }
            Button("Cancel", role: .cancel) {
                state.respondToContextLimit(.cancel)
            }
        } message: {
            Text(state.contextLimitMessage ?? "")
        }
        .alert(
            "Reset ARIL?",
            isPresented: $state.showResetConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) {
                Task { await state.performReset() }
            }
        } message: {
            Text("This permanently deletes ALL chat sessions and every Learning / judged database entry. This cannot be undone.")
        }
        .alert(
            "Session cache is large",
            isPresented: Binding(
                get: { state.sessionCacheAlertMessage != nil },
                set: { if !$0 { state.dismissSessionCacheAlert() } }
            )
        ) {
            Button("Dismiss", role: .cancel) {
                state.dismissSessionCacheAlert()
            }
            Button("Clear cache", role: .destructive) {
                state.respondToSessionCacheAlert(compact: false)
            }
            Button("Compact cache") {
                state.respondToSessionCacheAlert(compact: true)
            }
        } message: {
            Text(state.sessionCacheAlertMessage ?? "")
        }
        .task {
            systemMetrics.start()
            // Health only — bootstrap owns the first session load to avoid a selection race.
            await state.refreshHealth(reloadSessionsOnReady: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arilOpenPreferences)) { _ in
            openSettings()
        }
        .onDisappear {
            systemMetrics.stop()
        }
    }
}
