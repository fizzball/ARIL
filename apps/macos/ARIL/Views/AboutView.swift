import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ARILGhostMark(color: theme.palette.accent, lineWidth: 2.2)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 6) {
                    Text("ARIL")
                        .font(ARILTheme.wordmarkFont)
                        .foregroundStyle(theme.palette.text)
                    Text("Adaptive Routing Intelligence Layer")
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.accent)
                    Text("Version \(state.appVersionString) | by Ramon Ali")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Divider().background(theme.palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("What's new")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)

                    ForEach(Self.changelog, id: \.version) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.version)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(theme.palette.text)
                            ForEach(entry.changes, id: \.self) { change in
                                Text("· \(change)")
                                    .font(ARILTheme.captionFont)
                                    .foregroundStyle(theme.palette.textMuted)
                            }
                        }
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(width: 460, height: 420)
        .background(theme.palette.backgroundElevated)
    }

    private struct ChangelogEntry {
        let version: String
        let changes: [String]
    }

    private static let changelog: [ChangelogEntry] = [
        ChangelogEntry(version: "0.3.5", changes: [
            "Preferences → System Prompt tab (Claude.md-style instructions, token estimate, cost analysis)",
            "OpenRouter live $/1K model pricing in Preferences and prompt cost estimates",
            "Toolbar model-costs panel; Web Search fee when Web is enabled",
        ]),
        ChangelogEntry(version: "0.3.4", changes: [
            "Session history restores on launch (local cache + gateway merge; selection no longer clears)",
            "Ghost mark sits beside the ARIL label in chat bubbles",
        ]),
        ChangelogEntry(version: "0.3.3", changes: [
            "Compare runs 3 models with category + accuracy feedback that teaches future routing",
            "Preferences → Learning lists editable prompt classifications",
            "Analysis button shows confidence-index breakdown and overrides",
            "Deleted sessions stay deleted (tombstones + bulk delete API)",
            "Preferences → MCP to configure servers; Cost estimate highlights yellow when MCP is in use",
        ]),
        ChangelogEntry(version: "0.3.2", changes: [
            "Web search as a checkbox toggle; configurable prompt analysis idle delay",
            "Manual mode grades prompts without swapping models (red lock)",
            "Mode switches clear the draft; Compare uses a reliable model pair",
            "Live Thinking/Streaming status with elapsed timer",
            "ARIL mark identity, About page, reusable prior prompts",
            "Display name for chat; Grade/est. Cost/% fit hover tips; Latency metric",
        ]),
        ChangelogEntry(version: "0.3.1", changes: [
            "OpenRouter attachments and web search plugin",
            "Copy assistant replies; category routing refinements",
        ]),
        ChangelogEntry(version: "0.3.0", changes: [
            "Compare mode, preference learning, Sole / Solo gateway",
            "Intelligence panel with LLM prompt alternatives",
        ]),
    ]
}
