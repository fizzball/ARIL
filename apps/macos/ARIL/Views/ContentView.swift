import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = Self.loadColumnVisibility()
    @StateObject private var systemMetrics = SystemMetricsMonitor()

    private static let columnVisibilityKey = "aril.sidebarColumnVisibility"

    private static func loadColumnVisibility() -> NavigationSplitViewVisibility {
        switch UserDefaults.standard.string(forKey: columnVisibilityKey) {
        case "detailOnly": return .detailOnly
        case "doubleColumn": return .doubleColumn
        case "automatic": return .automatic
        default: return .all
        }
    }

    private static func saveColumnVisibility(_ value: NavigationSplitViewVisibility) {
        let raw: String
        switch value {
        case .detailOnly: raw = "detailOnly"
        case .doubleColumn: raw = "doubleColumn"
        case .automatic: raw = "automatic"
        default: raw = "all"
        }
        UserDefaults.standard.set(raw, forKey: columnVisibilityKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        // Empty title — otherwise collapsing the sidebar surfaces the
                        // bundle name (“ARIL”) next to the custom wordmark.
                        .navigationTitle("")
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
                    .navigationTitle("")
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
        .background(WindowTitleVisibilityHidden(refreshToken: columnVisibility))
        .font(theme.bodyFont)
        .animation(.easeInOut(duration: 0.22), value: state.activeToolPanel)
        .animation(.easeInOut(duration: 0.15), value: theme.fontSize)
        .animation(.easeInOut(duration: 0.15), value: theme.fontFamily)
        .onChange(of: columnVisibility) { _, newValue in
            Self.saveColumnVisibility(newValue)
            WindowTitleHiding.hide(in: NSApp.keyWindow)
        }
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
            Button("Reset", role: .destructive) {
                Task { await state.performReset() }
            }
        } message: {
            Text("This deletes ungrouped chat sessions and every Learning / judged database entry. Projects and sessions inside projects are kept — delete a project from its sidebar right-click menu. This cannot be undone.")
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
        .sheet(item: $state.pendingSlowResponseRetry) { pending in
            SlowResponseRetrySheet(pending: pending)
                .environmentObject(state)
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

/// Shown after a first-token stall — pick a retry model and timeout before continuing.
private struct SlowResponseRetrySheet: View {
    @EnvironmentObject private var state: AppState
    let pending: PendingSlowResponseRetry

    private var selectedModel: Binding<String> {
        Binding(
            get: { state.pendingSlowResponseRetry?.selectedModel ?? pending.selectedModel },
            set: { state.updatePendingSlowResponseRetryModel($0) }
        )
    }

    private var selectedTimeout: Binding<Int> {
        Binding(
            get: { state.pendingSlowResponseRetry?.retryTimeoutSeconds ?? pending.retryTimeoutSeconds },
            set: { state.updatePendingSlowResponseRetryTimeout($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No response from model")
                .font(.headline)
            Text(
                "\(pending.stalledModel) produced no first token after \(pending.stallTimeoutSeconds)s. Choose another model and a timeout for the retry attempt."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker("Retry model", selection: selectedModel) {
                ForEach(pending.modelChoices, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            Picker("Retry timeout", selection: selectedTimeout) {
                Text("Off").tag(0)
                ForEach(Array(stride(from: 15, through: 300, by: 15)), id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }
            Text("Defaults to your Preferences → General first-token timeout. Off disables the watchdog on this retry only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    state.respondToSlowResponseRetry(.cancel)
                }
                .keyboardShortcut(.cancelAction)
                Button("Retry") {
                    let model = state.pendingSlowResponseRetry?.selectedModel ?? pending.selectedModel
                    let timeout = state.pendingSlowResponseRetry?.retryTimeoutSeconds
                        ?? pending.retryTimeoutSeconds
                    state.respondToSlowResponseRetry(.retry(model: model, timeoutSeconds: timeout))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
