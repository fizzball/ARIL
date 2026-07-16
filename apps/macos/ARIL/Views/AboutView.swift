import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ARILGhostMark(color: theme.palette.accent, lineWidth: 2.2)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 6) {
                    Text("ARIL")
                        .font(ARILTheme.bodyFont.weight(.semibold))
                        .foregroundStyle(theme.palette.text)
                    Text("Adaptive Routing Intelligence Layer")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)
                    Text("Version \(state.appVersionString) | by Ramon Ali")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                }
                Spacer()
                Button {
                    state.closeToolPanel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(theme.palette.hairline)

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
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.backgroundElevated)
    }

    private struct ChangelogEntry {
        let version: String
        let changes: [String]
    }

    private static let changelog: [ChangelogEntry] = [
        ChangelogEntry(version: "0.3.28", changes: [
            "Recycle outdated Solo gateway when weekly rankings API is missing (fixes Model popularity 404)",
        ]),
        ChangelogEntry(version: "0.3.27", changes: [
            "Toolbar Model popularity flyout (replaces Model costs); Other… Weekly popular rankings",
        ]),
        ChangelogEntry(version: "0.3.26", changes: [
            "Budget: Enable toggle; Soft/Hard labels aligned; legacy $1/$5/$5/$20 seed migrates to Off",
        ]),
        ChangelogEntry(version: "0.3.25", changes: [
            "Budget prefs: Session/Daily × Soft/Hard grid with $0.50 steppers (default Off)",
            "Reply footer: total (in+out) token cost",
        ]),
        ChangelogEntry(version: "0.3.24", changes: [
            "Show real model id in reply cost footer; gateway tells the model its OpenRouter id (stops false Claude claims)",
        ]),
        ChangelogEntry(version: "0.3.23", changes: [
            "Budget soft/hard caps; Other… Vision modalities; Learning Prefer wins + Auto eval",
            "Fix: Auto no longer keeps the Manual model after switching modes",
        ]),
        ChangelogEntry(version: "0.3.22", changes: [
            "Auto honors Judge/Prefer wins (fingerprint then category) with “Because you preferred …” in Intelligence",
        ]),
        ChangelogEntry(version: "0.3.21", changes: [
            "MCP chat: show Thinking… / Connecting… while tools prepare (not just the ghost)",
        ]),
        ChangelogEntry(version: "0.3.20", changes: [
            "MCP in chat: enabled remote servers are used as tools in Auto/Manual (status in the reply)",
        ]),
        ChangelogEntry(version: "0.3.19", changes: [
            "MCP Check: recycle outdated Solo gateway so DeepWiki and other probes work after upgrade",
            "MCP Edit: presets show name, URL, and auth (locked fields no longer appear blank)",
        ]),
        ChangelogEntry(version: "0.3.18", changes: [
            "Preferences → MCP: configure remote presets, keys in Keychain, Check connection (tools in chat later)",
        ]),
        ChangelogEntry(version: "0.3.17", changes: [
            "Generated chat images: Copy image and Save…",
        ]),
        ChangelogEntry(version: "0.3.16", changes: [
            "Manual mode model menu: searchable Other… from the full OpenRouter catalog (pins up to 8)",
            "Other… model browser: filter by Coding, Security, Reasoning, and other Preferences categories",
        ]),
        ChangelogEntry(version: "0.3.15", changes: [
            "Developer ID signed and notarized builds — installs without Gatekeeper workarounds",
            "Automated notarized releases via GitHub Actions",
        ]),
        ChangelogEntry(version: "0.3.14", changes: [
            "Preferences: optional menu bar icon while ARIL is running (Open ARIL, Preferences, Quit)",
        ]),
        ChangelogEntry(version: "0.3.13", changes: [
            "Preferences restored as a full themed dialog (all tabs); Model costs / Learning / About stay as flyouts",
        ]),
        ChangelogEntry(version: "0.3.12", changes: [
            "Enter during analysis idle: send immediately and skip Learning judgement writes",
        ]),
        ChangelogEntry(version: "0.3.11", changes: [
            "Status bar: OpenRouter available credits when the API reports them",
            "Toolbar tools: Model costs, Learning, About as matching themed right flyouts",
        ]),
        ChangelogEntry(version: "0.3.10", changes: [
            "Preferences: Check OpenRouter connection after saving an API key",
            "Status bar: OpenRouter ready / not ready / not configured beside Gateway and Database",
        ]),
        ChangelogEntry(version: "0.3.9", changes: [
            "Title bar: live CPU, memory, and disk use percentages",
            "Chat: recover empty/failed streams; MCP Preferences locked (URL + API key backlog)",
        ]),
        ChangelogEntry(version: "0.3.8", changes: [
            "Chat: recover empty/failed streams via non-stream fallback; clearer gateway errors",
            "Preferences → MCP locked (backlog); future config is URL + API key per server",
        ]),
        ChangelogEntry(version: "0.3.7", changes: [
            "Learning: one send → one judgement + one chat transaction (deduped)",
            "Chat: recover empty/failed streams via non-stream fallback; clearer gateway errors",
        ]),
        ChangelogEntry(version: "0.3.6", changes: [
            "Solo packaging: DMG embeds the gateway; public Install docs + GitHub Release workflow",
            "Learning store: dedupe chat transactions; Activity filter hides analysis-cache noise",
            "Judge Equivalence Score, capability-matched peers, Manual skips Learning writes",
        ]),
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
            "Toolbar Learning panel for judgements / classifications; Log Analysis lives in Preferences",
            "Analysis button shows confidence-index breakdown and overrides",
            "Deleted sessions stay deleted (tombstones + bulk delete API)",
            "Preferences → MCP (backlog): when ready, each server needs a URL + API key",
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
