import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    private static let otherModelToken = "__aril.other__"
    private static let budgetRowLabelWidth: CGFloat = 64
    private static let budgetCapColumnWidth: CGFloat = 108

    @State private var showModelBrowser = false
    @State private var modelBrowserTitle = "Choose OpenRouter model"
    @State private var modelBrowserCategory: RouteCategory?
    @State private var modelBrowserForDefault = false
    @State private var mcpEditorTarget: MCPEditorTarget?

    var body: some View {
        TabView {
            gatewayTab
                .tabItem { Label("General", systemImage: "gearshape") }
            systemPromptTab
                .tabItem { Label("System Prompt", systemImage: "doc.plaintext") }
            routingTab
                .tabItem { Label("Models", systemImage: "cpu") }
            mcpTab
                .tabItem { Label("MCP", systemImage: "server.rack") }
            logAnalysisTab
                .tabItem { Label("Log Analysis", systemImage: "doc.text.magnifyingglass") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 720, height: 700)
        .background(theme.palette.backgroundElevated)
        .preferredColorScheme(theme.preferredColorScheme)
        .navigationTitle("Preferences")
        .task {
            Self.applyWindowChrome(colorScheme: theme.preferredColorScheme)
            await state.refreshDatabaseStatus()
        }
        .onAppear {
            Self.applyWindowChrome(colorScheme: theme.preferredColorScheme)
            Task { await state.refreshDatabaseStatus() }
        }
        .onChange(of: theme.option) { _, _ in
            Self.applyWindowChrome(colorScheme: theme.preferredColorScheme)
        }
    }

    /// Title + NSAppearance so the Settings window matches the app theme (not system white).
    /// `nil` colorScheme (System theme) clears the override so the window follows macOS.
    private static func applyWindowChrome(colorScheme: ColorScheme?) {
        DispatchQueue.main.async {
            let appearance: NSAppearance? = colorScheme.map {
                NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)!
            }
            for window in NSApplication.shared.windows {
                let title = window.title
                if title == "Settings"
                    || title == "ARIL Settings"
                    || title == "Preferences"
                    || title.hasSuffix("Settings") {
                    window.title = "Preferences"
                    window.appearance = appearance
                }
            }
        }
    }

    private var gatewayTab: some View {
        Form {
            Section("OpenRouter API key") {
                Text("Required for live multi-model chat. Create a key at openrouter.ai/keys")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.openRouterConfigured, !state.isEditingOpenRouterKey {
                    HStack {
                        Text(state.openRouterMaskedKey)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("Configured")
                            .foregroundStyle(theme.palette.accent)
                    }
                    HStack {
                        Button("Update key") {
                            state.beginEditingOpenRouterKey()
                        }
                        Button("Clear key", role: .destructive) {
                            Task { await state.clearOpenRouterKey() }
                        }
                    }
                    HStack {
                        Button("Check connection") {
                            Task { await state.checkOpenRouterConnection() }
                        }
                        Text(state.openRouterReady ? "Connected" : "Not connected")
                            .foregroundStyle(state.openRouterReady ? theme.palette.accent : theme.palette.danger)
                    }
                    if let checkMsg = state.openRouterCheckMessage {
                        Text(checkMsg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Spacer row to separate key actions from the next section
                    Color.clear.frame(height: 12)
                } else {
                    if !state.openRouterConfigured {
                        Text("No API key configured — enter one to enable OpenRouter.")
                            .foregroundStyle(theme.palette.danger)
                    }
                    SecureField("sk-or-v1-…", text: $state.openRouterKeyDraft)
                    HStack {
                        Button("Save key") {
                            Task { await state.saveOpenRouterKey() }
                        }
                        .disabled(state.openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if state.openRouterConfigured {
                            Button("Cancel") {
                                state.isEditingOpenRouterKey = false
                                state.openRouterKeyDraft = ""
                            }
                        }
                    }
                    Color.clear.frame(height: 12)
                }

                if let msg = state.openRouterKeyMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Gateway") {
                Toggle("Solo mode (auto-start local gateway)", isOn: $state.soloMode)
                Text("Release builds embed the gateway inside ARIL.app. Developer checkouts use services/aril-api (see docs/DEVELOPING.md).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onChange(of: state.soloMode) { _, _ in
                        state.saveSoloMode()
                    }
                Text(state.gatewayStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Gateway URL", text: $state.gatewayURL)
                    .onSubmit {
                        state.saveGatewayURL()
                        Task { await state.refreshHealth() }
                    }
                TextField("API root path (optional)", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "aril.apiRoot") ?? "" },
                    set: { UserDefaults.standard.set($0, forKey: "aril.apiRoot") }
                ))
                HStack {
                    Button("Check connection") {
                        state.saveGatewayURL()
                        Task { await state.refreshHealth() }
                    }
                    Text(state.gatewayReady ? "Gateway ready" : "Gateway not ready")
                        .foregroundStyle(state.gatewayReady ? theme.palette.accent : theme.palette.danger)
                }
            }

            Section("Startup") {
                Toggle(
                    "Open last session on startup",
                    isOn: Binding(
                        get: { state.openLastSessionOnStartup },
                        set: { state.setOpenLastSessionOnStartup($0) }
                    )
                )
                Text("When off (default), ARIL opens a fresh session each launch to reduce context exhaustion. When on, it reopens your most recent session. Empty sessions you never send a prompt into are discarded on quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle(
                    "Show ARIL in the menu bar",
                    isOn: Binding(
                        get: { state.showInMenuBar },
                        set: { state.setShowInMenuBar($0) }
                    )
                )
                Text("When enabled, ARIL appears in the macOS menu bar while it’s running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Budget") {
                Toggle(
                    "Enable budget guardrails",
                    isOn: Binding(
                        get: { state.budgetEnabled },
                        set: { state.setBudgetEnabled($0) }
                    )
                )
                Text("When off, Soft/Hard values are kept but ignored. Soft caps confirm before send; hard caps block. \(String(format: "$%.2f", BudgetCaps.stepUsd)) steps · 0 = off for that cap. Judge, web, and image-gen soft-confirm when any soft cap is set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow {
                        Text("")
                            .gridColumnAlignment(.leading)
                            .frame(width: Self.budgetRowLabelWidth, alignment: .leading)
                        Text("Soft")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.budgetCapColumnWidth, alignment: .trailing)
                        Text("Hard")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.budgetCapColumnWidth, alignment: .trailing)
                    }

                    GridRow {
                        Text("Session")
                            .gridColumnAlignment(.leading)
                            .frame(width: Self.budgetRowLabelWidth, alignment: .leading)
                        budgetStepper(
                            value: state.budgetCaps.sessionSoftUsd,
                            set: { soft in
                                state.setBudgetCaps(BudgetCaps(
                                    sessionSoftUsd: soft,
                                    sessionHardUsd: state.budgetCaps.sessionHardUsd,
                                    dailySoftUsd: state.budgetCaps.dailySoftUsd,
                                    dailyHardUsd: state.budgetCaps.dailyHardUsd
                                ))
                            }
                        )
                        budgetStepper(
                            value: state.budgetCaps.sessionHardUsd,
                            set: { hard in
                                state.setBudgetCaps(BudgetCaps(
                                    sessionSoftUsd: state.budgetCaps.sessionSoftUsd,
                                    sessionHardUsd: hard,
                                    dailySoftUsd: state.budgetCaps.dailySoftUsd,
                                    dailyHardUsd: state.budgetCaps.dailyHardUsd
                                ))
                            }
                        )
                    }

                    GridRow {
                        Text("Daily")
                            .gridColumnAlignment(.leading)
                            .frame(width: Self.budgetRowLabelWidth, alignment: .leading)
                        budgetStepper(
                            value: state.budgetCaps.dailySoftUsd,
                            set: { soft in
                                state.setBudgetCaps(BudgetCaps(
                                    sessionSoftUsd: state.budgetCaps.sessionSoftUsd,
                                    sessionHardUsd: state.budgetCaps.sessionHardUsd,
                                    dailySoftUsd: soft,
                                    dailyHardUsd: state.budgetCaps.dailyHardUsd
                                ))
                            }
                        )
                        budgetStepper(
                            value: state.budgetCaps.dailyHardUsd,
                            set: { hard in
                                state.setBudgetCaps(BudgetCaps(
                                    sessionSoftUsd: state.budgetCaps.sessionSoftUsd,
                                    sessionHardUsd: state.budgetCaps.sessionHardUsd,
                                    dailySoftUsd: state.budgetCaps.dailySoftUsd,
                                    dailyHardUsd: hard
                                ))
                            }
                        )
                    }
                }
                .disabled(!state.budgetEnabled)
                .opacity(state.budgetEnabled ? 1 : 0.45)

                LabeledContent("Today’s spend") {
                    Text(String(format: "$%.4f", state.dailySpendUsd))
                        .monospacedDigit()
                }
            }

            Section("Database") {
                Text("Local SQLite store for judgements, analysis cache, and chat transactions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Engine") {
                    Text(state.databaseEngine.uppercased())
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Database URL") {
                    Text(state.databasePath.isEmpty ? "—" : state.databasePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                if !state.databaseDetail.isEmpty {
                    Text(state.databaseDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Size") {
                    Text(state.databaseSizeLabel)
                        .monospacedDigit()
                }

                HStack {
                    Button("Check database") {
                        Task { await state.checkDatabase() }
                    }
                    Text(state.databaseReady ? "Database ready" : "Database not ready")
                        .foregroundStyle(state.databaseReady ? theme.palette.accent : theme.palette.danger)
                }
                if let msg = state.databaseCheckMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Default temperature") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                        Spacer(minLength: 0)
                        Text(String(format: "%.1f", state.defaultTemperature))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    // Native Form Slider ignores maxWidth on macOS — draw a full-width track.
                    FullWidthTemperatureSlider(value: Binding(
                        get: { state.defaultTemperature },
                        set: { state.setDefaultTemperature($0) }
                    ))

                    HStack(spacing: 0) {
                        Text("0 · Accuracy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("1 · Creativity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Applies to the analysis panel on launch and whenever you change this default. Mid-session slider changes stay until the next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Section("Prompt analysis delay") {
                HStack {
                    Text("Idle before analysis")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { state.analysisIdleSeconds },
                            set: { state.setAnalysisIdleSeconds($0) }
                        ),
                        in: 0...10,
                        step: 0.5
                    ) {
                        Text(state.analysisIdleSeconds == 0
                              ? "Immediate"
                              : String(format: "%.1f s", state.analysisIdleSeconds))
                            .monospacedDigit()
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                }
                Text("How long to wait after you stop typing before running prompt analysis. 0 runs immediately; up to 10 seconds in 0.5s steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Skip analysis when a judgement matches",
                    isOn: Binding(
                        get: { state.skipAnalysisOnJudgement },
                        set: { state.setSkipAnalysisOnJudgement($0) }
                    )
                )
                Text("When on, a matching Learning judgement greys the analysis metrics and reuses prior routing (token saver). Use Redo Analysis on the intelligence panel to recheck and update that judgement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sessions") {
                Text("Removes all chat history from this Mac and the local gateway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete all past sessions", role: .destructive) {
                    Task { await state.deleteAllSessions() }
                }
                .disabled(state.sessions.isEmpty)
            }
        }
        .padding()
        .formStyle(.grouped)
        .task {
            await state.refreshOpenRouterKeyStatus()
            if state.defaultTemperature > 1 || state.defaultTemperature < 0 {
                state.setDefaultTemperature(state.defaultTemperature)
            }
        }
    }

    private var systemPromptTab: some View {
        Form {
            Section("Global system prompt") {
                Toggle("Enable", isOn: Binding(
                    get: { state.systemPromptEnabled },
                    set: { state.setSystemPromptEnabled($0) }
                ))
                Text("When enabled, this instruction is sent as a system message with every chat request. It is not shown in the session transcript, and its tokens are included in cost analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.systemPromptEnabled {
                    HStack {
                        Text("Approximate tokens")
                        Spacer()
                        Text("~\(state.systemPromptTokenEstimate)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text("Rough estimate (~4 characters per token), aligned with gateway analysis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: Binding(
                        get: { state.systemPrompt },
                        set: { state.updateSystemPromptDraft($0) }
                    ))
                    .font(.system(.body, design: .default))
                    .frame(minHeight: 220, maxHeight: 320)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                    HStack {
                        Button("Default") {
                            state.restoreDefaultSystemPrompt()
                        }
                        .help("Restore the original built-in system prompt")
                        Spacer()
                        Button("Save") {
                            state.saveSystemPrompt()
                        }
                        .disabled(!state.systemPromptDirty)
                        .keyboardShortcut("s", modifiers: .command)
                        .help(state.systemPromptDirty ? "Save system prompt" : "No changes to save")
                    }
                } else {
                    ScrollView {
                        Text(state.systemPromptShadowText)
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 160, maxHeight: 240)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Shadow text is your saved prompt (or the built-in default). Turn the toggle on to edit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .formStyle(.grouped)
    }

    private var routingTab: some View {
        Form {
            Section("Default model") {
                Picker("App default", selection: Binding(
                    get: { state.defaultModel },
                    set: { newValue in
                        if newValue == Self.otherModelToken {
                            modelBrowserForDefault = true
                            modelBrowserCategory = nil
                            modelBrowserTitle = "Choose default OpenRouter model"
                            showModelBrowser = true
                        } else {
                            state.setDefaultModel(newValue)
                        }
                    }
                )) {
                    ForEach(defaultPickerModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Divider()
                    Text("Other…").tag(Self.otherModelToken)
                }
                if let price = state.pricingLabel(for: state.defaultModel) {
                    Text(price)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("Manual mode uses the last model you picked (or Other… from the chat model menu). Default is highlighted ★ in the model menu. Prices are OpenRouter USD per 1K input / output tokens. Choose Other… to browse the full OpenRouter catalog — new picks are pinned to the top of the shortlist (max 8).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Category → recommended model") {
                HStack {
                    Text("Auto mode picks the model mapped to the detected prompt category.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state.isLoadingModelPricing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Reset") {
                        state.resetRoutingModelsToDefaults()
                    }
                    .disabled(!state.routingModelsDifferFromDefaults)
                    .help(
                        state.routingModelsDifferFromDefaults
                            ? "Restore all category models and the app default to the original built-in set"
                            : "Already using the original built-in models"
                    )
                }

                ForEach(RouteCategory.allCases) { category in
                    let selected = state.routingProfile.model(for: category)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(category.label)
                                .font(.headline)
                            Spacer()
                            if let price = state.pricingLabel(for: selected) {
                                Text(price)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Text(category.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Model for \(category.label)", selection: binding(for: category)) {
                            ForEach(pickerModels(for: category), id: \.self) { model in
                                Text(model).tag(model)
                            }
                            Divider()
                            Text("Other…").tag(Self.otherModelToken)
                        }
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .formStyle(.grouped)
        .task {
            await state.refreshModelPricing(forceRefresh: false)
        }
        .sheet(isPresented: $showModelBrowser) {
            OpenRouterModelBrowserView(
                title: modelBrowserTitle,
                initialCategory: modelBrowserForDefault ? nil : modelBrowserCategory
            ) { modelID in
                state.promoteModelToCatalog(modelID)
                if modelBrowserForDefault {
                    state.setDefaultModel(modelID)
                } else if let category = modelBrowserCategory {
                    state.setRoutingModel(modelID, for: category)
                }
            }
            .environmentObject(state)
            .environmentObject(theme)
        }
    }

    private var defaultPickerModels: [String] {
        var models = state.modelCatalog
        if !models.contains(state.defaultModel) {
            models.insert(state.defaultModel, at: 0)
        }
        return models
    }

    private func pickerModels(for category: RouteCategory) -> [String] {
        let selected = state.routingProfile.model(for: category)
        var models = recommended(for: category)
        for model in state.modelCatalog where !models.contains(model) {
            models.append(model)
        }
        if !models.contains(selected) {
            models.insert(selected, at: 0)
        }
        return models
    }

    private var mcpTab: some View {
        Form {
            Section("MCP") {
                Toggle("Use MCP servers", isOn: Binding(
                    get: { state.mcpEnabled },
                    set: { state.setMCPEnabled($0) }
                ))
                Text("Enabled servers are available as tools in Auto/Manual chat. Judge mode does not use MCP. The Nmap Scanner (local) is managed by ARIL — enable it to run a local, token-authenticated nmap server. Playwright/stdio is deferred.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let ready = state.mcpServers.filter(\.isReady).count
                Text("\(ready) ready · \(state.mcpServers.filter(\.enabled).count) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Servers") {
                ForEach(state.mcpServers) { server in
                    mcpServerRow(server)
                }
                Button("Add server…") {
                    mcpEditorTarget = .new
                }
            }
        }
        .padding()
        .formStyle(.grouped)
        .sheet(item: $mcpEditorTarget) { target in
            MCPServerEditorView(serverID: target.serverID)
                .environmentObject(state)
        }
    }

    @ViewBuilder
    private func mcpServerRow(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.displayName)
                            .font(.headline)
                        if server.isDeferred {
                            Text("Soon")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if server.isManaged {
                            Text("Managed")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if server.isPreset {
                            Text("Preset")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(server.isDeferred ? "Local stdio (deferred)" : server.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { server.enabled },
                        set: { state.setMCPServerEnabled(id: server.id, enabled: $0) }
                    )
                )
                .labelsHidden()
                .disabled(server.isDeferred || !state.mcpEnabled)
                .help(server.isDeferred ? "Playwright requires local Node — coming later" : "Enable this server")
            }

            if server.isManaged {
                managedServerDetails(server)
            } else if !server.isDeferred, server.needsAPIKey {
                SecureField(
                    server.authStyle == .header
                        ? "API key (\(server.authHeaderName ?? "header"))"
                        : "API key / bearer token",
                    text: Binding(
                        get: { server.apiKey },
                        set: { state.setMCPServerAPIKey(id: server.id, apiKey: $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                statusPill(for: server)
                Spacer()
                if let docs = server.docsURL, let link = URL(string: docs) {
                    Link("Docs", destination: link)
                        .font(.caption)
                }
                if !server.isManaged {
                    Button("Edit") {
                        mcpEditorTarget = .edit(server.id)
                    }
                    .font(.caption)
                }
                Button("Check") {
                    Task { await state.checkMCPServerConnection(id: server.id) }
                }
                .font(.caption)
                .disabled(server.isDeferred || state.mcpCheckingServerID == server.id)
                if state.mcpCheckingServerID == server.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !server.lastCheckMessage.isEmpty {
                Text(server.lastCheckMessage)
                    .font(.caption)
                    .foregroundStyle(server.lastCheckStatus == .ok ? Color.secondary : Color.red.opacity(0.85))
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
        .opacity(state.mcpEnabled || server.isDeferred ? 1 : 0.55)
    }

    @ViewBuilder
    private func managedServerDetails(_ server: MCPServerConfig) -> some View {
        let isCode = server.presetId == MCPServerConfig.codescanPresetId
        let toolName = isCode ? "semgrep" : "nmap"
        let installHint = isCode ? "brew install semgrep" : "brew install nmap"
        let blurb = isCode
            ? "ARIL runs this server for you — it generates a bearer token, writes a localhost-only config, and launches semgrep over MCP for static code analysis (files, folders, or inline snippets). Enable it above to start; the token is stored in your Keychain."
            : "ARIL runs this server for you — it generates a bearer token, writes a localhost-only config, and launches nmap over MCP. Enable it above to start; the token is stored in your Keychain."
        let installed = isCode ? state.semgrepInstalled : state.nmapInstalled
        let busy = isCode ? state.codeScanServerBusy : state.nmapServerBusy
        let statusText = isCode ? state.codeScanServerStatus : state.nmapServerStatus

        VStack(alignment: .leading, spacing: 4) {
            Text(blurb)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(installed ? Color.green : Color.orange)
                    .font(.caption)
                if installed {
                    Text("\(toolName) is installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(toolName) not found — install with ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        + Text(installHint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                }
                if busy {
                    ProgressView().controlSize(.small)
                }
            }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusPill(for server: MCPServerConfig) -> some View {
        let (label, color): (String, Color) = {
            switch server.lastCheckStatus {
            case .ok: return ("OK", .green)
            case .failed: return ("Failed", .red)
            case .deferred: return ("Deferred", .secondary)
            case .unknown: return (server.isReady ? "Ready" : "Not ready", .secondary)
            }
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.4), lineWidth: 1)
            )
    }

    private var logAnalysisTab: some View {
        LogAnalysisView(embeddedInPreferences: true)
            .environmentObject(state)
            .environmentObject(theme)
    }

    private var appearanceTab: some View {
        Form {
            Section("Identity") {
                TextField("Your name", text: $state.userDisplayName)
                    .onSubmit { state.saveUserDisplayName() }
                    .onChange(of: state.userDisplayName) { _, _ in
                        state.saveUserDisplayName()
                    }
                Text("Replaces the “You” label on your messages in chat. Leave blank to keep “You”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Theme") {
                Picker("Theme", selection: $theme.option) {
                    ForEach(AppThemeOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("System follows macOS light, dark, and Auto. Other options lock a fixed palette. Applies across the whole client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .formStyle(.grouped)
    }

    private func recommended(for category: RouteCategory) -> [String] {
        RoutingProfile.recommendations[category] ?? AppState.factoryModelCatalog
    }

    private func binding(for category: RouteCategory) -> Binding<String> {
        Binding(
            get: { state.routingProfile.model(for: category) },
            set: { newValue in
                if newValue == Self.otherModelToken {
                    modelBrowserForDefault = false
                    modelBrowserCategory = category
                    modelBrowserTitle = "Choose OpenRouter model for \(category.label)"
                    showModelBrowser = true
                } else {
                    state.setRoutingModel(newValue, for: category)
                }
            }
        )
    }

    private func budgetStepper(value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(value <= 0 ? "Off" : String(format: "$%.2f", value))
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
            Stepper(
                "",
                value: Binding(get: { value }, set: set),
                in: 0...BudgetCaps.maxUsd,
                step: BudgetCaps.stepUsd
            )
            .labelsHidden()
            .fixedSize()
        }
        .frame(width: Self.budgetCapColumnWidth, alignment: .trailing)
        .help(value <= 0 ? "Off — cap disabled" : String(format: "$%.2f USD", value))
    }
}

private struct FullWidthTemperatureSlider: View {
    @Binding var value: Double
    private let range: ClosedRange<Double> = 0...1
    private let step: Double = 0.1

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let thumbRadius: CGFloat = 9
            let travel = max(width - thumbRadius * 2, 1)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbX = thumbRadius + fraction * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(thumbX, 4), height: 4)

                // Tick marks at 0.1 steps
                ForEach(0..<11, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3, height: 3)
                        .position(
                            x: thumbRadius + CGFloat(i) / 10 * travel,
                            y: geo.size.height / 2 + 10
                        )
                }

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .position(x: thumbX, y: geo.size.height / 2)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = (drag.location.x - thumbRadius) / travel
                        let clamped = min(1, max(0, Double(raw)))
                        let stepped = (clamped / step).rounded() * step
                        value = min(range.upperBound, max(range.lowerBound, stepped))
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .padding(.bottom, 6)
    }
}

/// Sheet identity for Add vs Edit MCP server (avoids stale `isPresented` captures).
private enum MCPEditorTarget: Identifiable, Hashable {
    case new
    case edit(UUID)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let uuid): return uuid.uuidString
        }
    }

    var serverID: UUID? {
        switch self {
        case .new: return nil
        case .edit(let uuid): return uuid
        }
    }
}
