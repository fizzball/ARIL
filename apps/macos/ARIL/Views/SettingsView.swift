import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        TabView {
            Form {
                Toggle("Solo mode (auto-start local gateway)", isOn: $state.soloMode)
                    .onChange(of: state.soloMode) { _, _ in
                        state.saveSoloMode()
                    }
                Text(state.gatewayManager.lastMessage)
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
                    Text(state.gatewayStatus)
                        .foregroundStyle(state.gatewayReady ? Color.secondary : Color.red)
                }
                Slider(value: $state.temperature, in: 0...2, step: 0.1) {
                    Text("Default temperature")
                }
                Text(String(format: "%.1f", state.temperature))
            }
            .padding()
            .tabItem { Label("Gateway", systemImage: "network") }

            Form {
                Picker("Default model", selection: Binding(
                    get: { state.defaultModel },
                    set: { state.setDefaultModel($0) }
                )) {
                    ForEach(AppState.modelCatalog, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Text("Manual mode uses the last selected model. Default is highlighted in the model menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                modelPicker("Coding", selection: $state.routingProfile.coding)
                modelPicker("Security", selection: $state.routingProfile.security)
                modelPicker("Cost", selection: $state.routingProfile.cost)
                modelPicker("Performance", selection: $state.routingProfile.performance)
                modelPicker("Confidence", selection: $state.routingProfile.confidence)
                modelPicker("General", selection: $state.routingProfile.general)
                Button("Save routing profile") {
                    state.saveRoutingProfile()
                }
            }
            .padding()
            .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }

            Form {
                Picker("Theme", selection: $theme.option) {
                    ForEach(AppThemeOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                Text("Noir, Slate, Light, and Forest palettes. Affects the whole client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 580, height: 400)
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AppState.modelCatalog, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .onChange(of: selection.wrappedValue) { _, _ in
            state.saveRoutingProfile()
        }
    }
}
