import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        TabView {
            gatewayTab
                .tabItem { Label("Gateway", systemImage: "network") }
            routingTab
                .tabItem { Label("Models", systemImage: "cpu") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 640, height: 520)
    }

    private var gatewayTab: some View {
        Form {
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
            Slider(value: $state.temperature, in: 0...2, step: 0.1) {
                Text("Default temperature")
            }
            Text(String(format: "%.1f", state.temperature))

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
    }

    private var routingTab: some View {
        Form {
            Section("Default model") {
                Picker("App default", selection: Binding(
                    get: { state.defaultModel },
                    set: { state.setDefaultModel($0) }
                )) {
                    ForEach(AppState.modelCatalog, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Text("Manual mode uses the last model you picked. Default is highlighted ★ in the model menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Category → recommended model") {
                Text("Auto mode picks the model mapped to the detected prompt category.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(RouteCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.label)
                            .font(.headline)
                        Text(category.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Model for \(category.label)", selection: binding(for: category)) {
                            ForEach(recommended(for: category), id: \.self) { model in
                                Text(model).tag(model)
                            }
                            Divider()
                            ForEach(AppState.modelCatalog, id: \.self) { model in
                                if !(recommended(for: category).contains(model)) {
                                    Text(model).tag(model)
                                }
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
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
                state.routingProfile.setModel(newValue, for: category)
                state.saveRoutingProfile()
            }
        )
    }
}
