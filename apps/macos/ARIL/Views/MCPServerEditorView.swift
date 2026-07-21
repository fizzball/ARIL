import SwiftUI

/// Add / edit sheet for a remote MCP server (customs fully editable; presets mostly locked).
struct MCPServerEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let serverID: UUID?
    var isNew: Bool { serverID == nil }

    @State private var name = ""
    @State private var url = ""
    @State private var apiKey = ""
    @State private var authStyle: MCPAuthStyle = .bearer
    @State private var authHeaderName = "Authorization"
    @State private var docsURL = ""
    @State private var enabled = false
    @State private var isPreset = false
    @State private var isDeferred = false
    @State private var isEditable = true
    @State private var didLoad = false

    private var fieldsLocked: Bool { isPreset && !isEditable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "Add MCP server" : "Edit MCP server")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Form {
                Section("Server") {
                    if fieldsLocked {
                        lockedRow("Name", value: name)
                        lockedRow("URL", value: url.isEmpty ? "—" : url)
                    } else {
                        TextField("Name", text: $name)
                        TextField("URL", text: $url)
                            .disabled(isDeferred)
                    }
                    if isDeferred {
                        Text("Stdio custom servers are not available yet. Use a managed local preset (Nmap / Semgrep), or a remote HTTP MCP server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Enabled", isOn: $enabled)
                        .disabled(isDeferred)
                }

                Section("Authentication") {
                    if fieldsLocked {
                        lockedRow("Auth", value: authStyle.label)
                        if authStyle == .header {
                            lockedRow("Header name", value: authHeaderName)
                        }
                    } else {
                        Picker("Auth", selection: $authStyle) {
                            ForEach(MCPAuthStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        if authStyle == .header {
                            TextField("Header name", text: $authHeaderName)
                        }
                    }
                    if authStyle != .none {
                        SecureField("API key / token", text: $apiKey)
                        Text("Stored in Application Support ARIL/.env on this Mac. Never committed to the repo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No API key required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Docs") {
                    if fieldsLocked {
                        lockedRow("Documentation URL", value: docsURL.isEmpty ? "—" : docsURL)
                    } else {
                        TextField("Documentation URL", text: $docsURL)
                    }
                    if let link = URL(string: docsURL), !docsURL.isEmpty {
                        Link("Open docs", destination: link)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isDeferred && !isNew)

            HStack {
                if !isNew, !isPreset {
                    Button("Delete", role: .destructive) {
                        if let serverID {
                            state.deleteMCPServer(id: serverID)
                        }
                        dismiss()
                    }
                }
                if !isNew, isPreset {
                    Button("Reset credentials") {
                        if let serverID {
                            state.resetMCPPreset(id: serverID)
                        }
                        dismiss()
                    }
                }
                Spacer()
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .onAppear(perform: load)
        .onChange(of: serverID) { _, _ in
            didLoad = false
            load()
        }
    }

    @ViewBuilder
    private func lockedRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var canSave: Bool {
        if isDeferred { return false }
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasURL = !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && hasURL
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let serverID,
              let existing = state.mcpServers.first(where: { $0.id == serverID }) else {
            name = ""
            url = "https://"
            apiKey = ""
            authStyle = .bearer
            authHeaderName = "Authorization"
            docsURL = ""
            enabled = true
            isPreset = false
            isDeferred = false
            isEditable = true
            return
        }
        name = existing.name
        url = existing.url
        apiKey = existing.apiKey
        authStyle = existing.authStyle
        authHeaderName = existing.authHeaderName ?? "Authorization"
        docsURL = existing.docsURL ?? ""
        enabled = existing.enabled
        isPreset = existing.isPreset
        isDeferred = existing.isDeferred
        isEditable = existing.isEditable
    }

    private func save() {
        if let serverID,
           var existing = state.mcpServers.first(where: { $0.id == serverID }) {
            if existing.isEditable || !existing.isPreset {
                existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                existing.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                existing.authStyle = authStyle
                existing.authHeaderName = authStyle == .header
                    ? authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
                existing.docsURL = docsURL.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            existing.enabled = enabled && !existing.isDeferred
            existing.apiKey = apiKey
            state.updateMCPServer(existing)
            return
        }
        let created = MCPServerConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey,
            enabled: enabled,
            authStyle: authStyle,
            authHeaderName: authStyle == .header
                ? authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil,
            docsURL: docsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : docsURL.trimmingCharacters(in: .whitespacesAndNewlines),
            isEditable: true
        )
        state.addCustomMCPServer(created)
    }
}
