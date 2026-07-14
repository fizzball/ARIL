import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    private static let otherModelToken = "__aril.other__"

    @State private var showModelBrowser = false
    @State private var modelBrowserTitle = "Choose OpenRouter model"
    @State private var modelBrowserCategory: RouteCategory?
    @State private var modelBrowserForDefault = false

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
            learningTab
                .tabItem { Label("Learning", systemImage: "brain") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 700, height: 640)
        .navigationTitle("Preferences")
        .task {
            await state.loadClassifications()
            Self.renameSettingsWindow()
        }
        .onAppear {
            Self.renameSettingsWindow()
        }
    }

    /// macOS Settings scene defaults to "Settings"; prefer "Preferences".
    private static func renameSettingsWindow() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                let title = window.title
                if title == "Settings" || title == "ARIL Settings" || title.hasSuffix("Settings") {
                    window.title = "Preferences"
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
                            .foregroundStyle(Color.green)
                    }
                    HStack {
                        Button("Update key") {
                            state.beginEditingOpenRouterKey()
                        }
                        Button("Clear key", role: .destructive) {
                            Task { await state.clearOpenRouterKey() }
                        }
                    }
                    // Spacer row to separate key actions from the next section
                    Color.clear.frame(height: 12)
                } else {
                    if !state.openRouterConfigured {
                        Text("No API key configured — enter one to enable OpenRouter.")
                            .foregroundStyle(Color.red)
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
                        .foregroundStyle(state.gatewayReady ? Color.green : Color.red)
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
                Text("Manual mode uses the last model you picked. Default is highlighted ★ in the model menu. Prices are OpenRouter USD per 1K input / output tokens. Choose Other… to browse the full OpenRouter catalog.")
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
            OpenRouterModelBrowserView(title: modelBrowserTitle) { modelID in
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
        var models = AppState.modelCatalog
        if !models.contains(state.defaultModel) {
            models.insert(state.defaultModel, at: 0)
        }
        return models
    }

    private func pickerModels(for category: RouteCategory) -> [String] {
        let selected = state.routingProfile.model(for: category)
        var models = recommended(for: category)
        for model in AppState.modelCatalog where !models.contains(model) {
            models.append(model)
        }
        if !models.contains(selected) {
            models.insert(selected, at: 0)
        }
        return models
    }

    private var mcpTab: some View {
        Form {
            Section("MCP servers") {
                Toggle("Use MCP servers", isOn: Binding(
                    get: { state.mcpEnabled },
                    set: { state.setMCPEnabled($0) }
                ))
                Text("When enabled with at least one ready server, cost estimates are highlighted to warn that tool use may raise spend. Add servers below even before enabling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.mcpServers.isEmpty {
                    Text("No MCP servers yet. Add one to point at a local stdio process or an SSE/HTTP endpoint.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($state.mcpServers) { $server in
                        MCPServerRow(server: $server) {
                            state.removeMCPServer(server.id)
                        }
                        .onChange(of: server) { _, _ in
                            state.persistMCPServers()
                        }
                    }
                }

                Button("Add MCP server") {
                    state.addMCPServer()
                }
            }
        }
        .padding()
        .formStyle(.grouped)
    }

    private var learningTab: some View {
        Form {
            Section("Prompt classifications") {
                Text("Judgments from Compare Prefer and Analysis overrides. Adjust category or accuracy, or remove an entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.classifications.isEmpty {
                    Text("No classifications yet. Prefer a Compare result or save an Analysis override.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.classifications) { item in
                        ClassificationRow(item: item)
                    }
                }

                Button("Refresh list") {
                    Task { await state.loadClassifications() }
                }
            }
        }
        .padding()
        .formStyle(.grouped)
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
                Text("Noir, Slate, Light, and Forest. Applies across the whole client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .formStyle(.grouped)
    }

    private func recommended(for category: RouteCategory) -> [String] {
        RoutingProfile.recommendations[category] ?? AppState.modelCatalog
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

private struct ClassificationRow: View {
    @EnvironmentObject private var state: AppState
    let item: ClassificationRecordDTO
    @State private var category: RouteCategory = .general
    @State private var accuracy: Double = 0.8
    @State private var hasAccuracy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.promptSnippet.isEmpty ? item.prompt : item.promptSnippet)
                .lineLimit(2)
            Text("\(item.model) · \(item.category)\(item.categoryOverridden ? " · override" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Category", selection: $category) {
                ForEach(RouteCategory.allCases) { cat in
                    Text(cat.label).tag(cat)
                }
            }

            Toggle("Accuracy set", isOn: $hasAccuracy)
            if hasAccuracy {
                HStack {
                    Text("\(Int(accuracy * 100))%")
                        .frame(width: 40)
                    Slider(value: $accuracy, in: 0...1, step: 0.05)
                }
            }

            HStack {
                Button("Save") {
                    Task {
                        await state.updateClassification(
                            item.id,
                            category: category,
                            accuracy: hasAccuracy ? accuracy : nil,
                            removeAccuracy: !hasAccuracy && item.accuracy != nil
                        )
                    }
                }
                Button("Remove", role: .destructive) {
                    Task { await state.deleteClassification(item.id) }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            category = RouteCategory(rawValue: item.category) ?? .general
            if let acc = item.accuracy {
                hasAccuracy = true
                accuracy = acc
            }
        }
    }
}

private struct MCPServerRow: View {
    @Binding var server: MCPServerConfig
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $server.enabled) {
                    TextField("Name", text: $server.name)
                }
                Spacer(minLength: 8)
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
            }

            Picker("Transport", selection: $server.transport) {
                ForEach(MCPTransport.allCases) { transport in
                    Text(transport.label).tag(transport)
                }
            }

            if server.transport == .stdio {
                TextField("Command (e.g. npx or /usr/local/bin/server)", text: $server.endpoint)
                TextField("Arguments (optional, space-separated)", text: $server.args)
            } else {
                TextField("URL (e.g. https://host/mcp)", text: $server.endpoint)
            }
        }
        .padding(.vertical, 6)
    }
}
