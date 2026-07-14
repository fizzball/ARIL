import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    private let models = [
        "openai/gpt-4.1",
        "openai/gpt-4.1-mini",
        "anthropic/claude-sonnet-4",
        "anthropic/claude-opus-4",
        "google/gemini-2.5-flash",
        "meta-llama/llama-3.3-70b-instruct",
    ]

    var body: some View {
        TabView {
            Form {
                TextField("Gateway URL", text: $state.gatewayURL)
                    .onSubmit {
                        state.saveGatewayURL()
                        Task { await state.refreshHealth() }
                    }
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
                modelPicker("Coding", selection: $state.routingProfile.coding)
                modelPicker("Security", selection: $state.routingProfile.security)
                modelPicker("Cost", selection: $state.routingProfile.cost)
                modelPicker("Performance", selection: $state.routingProfile.performance)
                modelPicker("Confidence", selection: $state.routingProfile.confidence)
                modelPicker("General", selection: $state.routingProfile.general)
                Text("These mappings drive Auto route recommendations via OpenRouter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save routing profile") {
                    state.saveRoutingProfile()
                }
            }
            .padding()
            .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
        }
        .frame(width: 560, height: 360)
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(models, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .onChange(of: selection.wrappedValue) { _, _ in
            state.saveRoutingProfile()
        }
    }
}
