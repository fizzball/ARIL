import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ARILLogoImage(size: 56)

                VStack(alignment: .leading, spacing: 6) {
                    ARILWordmarkImage(height: 22)
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
        ChangelogEntry(version: "0.4.18", changes: [
            "Image replies show the model / tokens / cost tag again (storage sanitization no longer drops the assistant message id)",
        ]),
        ChangelogEntry(version: "0.4.17", changes: [
            "SSLyze Scanner (local) MCP — TLS certificate info, protocols, vuln checks (pipx install sslyze)",
            "Model/cost tags survive app restart; duplicate session turns are collapsed",
            "Slow-response stall prompts for retry model + timeout (defaults to Preferences)",
        ]),
        ChangelogEntry(version: "0.4.16", changes: [
            "OS Access asks for inline Run / Cancel before executing a local shell command",
            "Non-responsive model bypass — skip models that stall on first token (Preferences duration or permanent); clear list anytime",
            "Empty fallback replies after a timeout no longer leave a blank assistant bubble",
        ]),
        ChangelogEntry(version: "0.4.15", changes: [
            "Cyan ARIL wordmark on the empty hero, title bar, and About panel (matches aril.host)",
            "Collapsed sidebar no longer shows a duplicate system “ARIL” title beside the wordmark",
            "Sidebar open/collapsed state is remembered across launches",
        ]),
        ChangelogEntry(version: "0.4.14", changes: [
            "Project files — attach Word/Excel/PDF/RTF/CSV/Markdown to a Project; sessions retrieve excerpts into context",
            "Project Files sheet — Show in Finder; Search… moved to the project context menu",
            "Project sessions use a distinct sidebar selection tint; OS Access no longer lists the Mac home for “list project files”",
            "Fix generated images vanishing into omitted-from-context placeholders",
        ]),
        ChangelogEntry(version: "0.4.13", changes: [
            "Incognito mode — ghost checkbox beside Auto/Manual/Judge; keeps context, wipes history on session end or quit, preserves spend totals",
            "Slow-response fallback — Preferences timeout (default 30s) retries Auto on a faster peer when no first token arrives; skips image-gen / reasoning; optional for Manual",
            "Sandboxed HTML/JS previews — ```html``` / ```js-preview``` fences run offline in-chat (no network)",
            "Scroll to top / bottom controls; Send uses a paper-plane icon and highlight color",
        ]),
        ChangelogEntry(version: "0.4.12", changes: [
            "Update checker compares build numbers when the marketing version matches",
            "/status Version line shows installed vs latest as 0.4.x (build N)",
        ]),
        ChangelogEntry(version: "0.4.11", changes: [
            "Skills preferences + /skills — Document Export (PDF/Word) and OS Access (local shell)",
            "Type @ in the prompt to pick a skill; skills also apply from context when enabled",
            "Web Search moved to Preferences → General (on by default); /status shows its state",
            "/reset keeps projects and project sessions; Preferences wipe warns it deletes projects too",
            "Adaptive mesh app icon; chat avatars tint by selected model",
            "Menu bar icon uses a high-contrast template mesh (pulses while busy)",
            "Website Help page at aril.host/help, linked from the macOS Help menu",
            "Preferences → Appearance: choose the app text size and typeface",
        ]),
        ChangelogEntry(version: "0.4.10", changes: [
            "Model picker moved to the full-width status tray — prompt field has more room",
            "Status tray spans the full window (under sidebar + chat)",
            "Shift+Return inserts a newline in the prompt; Return still sends",
            "↑/↓ prompt history ignores slash commands and expands multi-line recalls correctly",
            "/version shows the current app version; unknown /commands are not sent as prompts",
        ]),
        ChangelogEntry(version: "0.4.9", changes: [
            "Sidebar Update button replaces the upgrade dialog when a newer release is available",
            "Export session as Markdown (sidebar, context menu, or /export)",
            "Spend analysis toolbar panel — models used, calendar-month and rolling 7-day totals",
            "Intelligence panel prompt-cache status with Edit/Submit when a cache hit is available",
            "/web toggles OpenRouter web search; /cache reports session cache (compact|clear)",
            "/status includes session-cache and prompt-cache lines",
            "/new starts a new chat session",
            "Learning Selected Model Test — category prompts vs Preferences → Models with progress slide-up",
            "Sidebar Projects — group sessions into folders; project search is scoped, main search is global",
            "MCP tokens in Application Support .env (no Keychain); rotate on each managed-server enable",
            "Removed Playwright Browser MCP (unreliable local browser automation)",
        ]),
        ChangelogEntry(version: "0.4.8", changes: [
            "Session cache management: strip bulky image payloads on save, auto-compact oversized caches, warn with Compact/Clear",
            "Status footer shows Cache Size with healthy / ok / warn colours",
            "Faster launch (fresh session before bootstrap) and smoother typing (draft no longer redraws the whole app)",
            "Preferences → General: Compact cache and Clear cache",
        ]),
        ChangelogEntry(version: "0.4.7", changes: [
            "Judge mode renders images, Mermaid, and SVG in comparison cards",
            "Menu bar icon uses the ARIL logo (Preferences → General → Show in menu bar)",
            "/status reports Sensitive Info and Prompt Injection guardrail state",
            "Public site at aril.host with screenshots and direct download",
        ]),
        ChangelogEntry(version: "0.4.6", changes: [
            "New ARIL app icon and in-chat logo; waiting replies show a spinning gold arrow",
            "Log Analysis moved to the toolbar; About opens from the ARIL title label",
            "OpenRouter OAuth keys persist across relaunch (Application Support .env + UserDefaults)",
            "Local guardrails in Preferences → Subscription (sensitive-info redact, prompt-injection block)",
            "Assistant replies render Markdown/math legibly with real line breaks; streaming paints live again",
        ]),
        ChangelogEntry(version: "0.4.5", changes: [
            "Preferences → Appearance: System theme follows macOS light/dark/Auto, plus Ocean, Graphite, Sand, Dusk, and Midnight",
            "Title-bar ARIL wordmark cycles subtle colour, typeface, and flourish animations every minute",
            "Scroll-to-bottom control recentered in the prompt toolbar",
            "Preferences → Subscription: OpenRouter account connection (OAuth sign-in or paste API key)",
            "Preferences opens as an in-window overlay so it stays inside the main ARIL frame",
            "Sign in with OpenRouter (OAuth PKCE) provisions a user-controlled key without copy/paste",
        ]),
        ChangelogEntry(version: "0.4.4", changes: [
            "Session history no longer duplicates image turns on launch — client and gateway dedupe restored transcripts",
            "Toolbar scroll-to-bottom button (↓) jumps to the latest message",
        ]),
        ChangelogEntry(version: "0.4.3", changes: [
            "Mermaid diagrams render reliably in-chat (classic WebKit loader); models are told ARIL can display diagrams so they stop pointing at mermaid.live",
            "Sidebar search matches session titles and message content, with highlighted hits and a short matching snippet",
        ]),
        ChangelogEntry(version: "0.4.2", changes: [
            "Assistant replies render Mermaid, SVG, and ASCII diagrams in-chat (fenced mermaid/svg/ascii blocks, inline SVG, SVG image links)",
            "Slash command `/update` checks GitHub for a newer release and can download the DMG into /Applications (relaunch)",
        ]),
        ChangelogEntry(version: "0.4.1", changes: [
            "Sidebar shows a per-session context-usage bar; warns before a session hits the model context limit with the option to start a new session",
            "Context limits are read from the gateway (/v1/meta/limits) so the client stays in sync",
            "Starts each launch on a fresh session by default to reduce context exhaustion; opt into reopening your last session in Preferences → Startup",
            "New sessions you never send a prompt into are discarded on quit; sidebar header renamed to 'Recent Sessions'",
            "Judge panels fill the chat width/height evenly and blank the transcript while comparing, so cards stay readable",
            "Reply cost footer shows OpenRouter in/out token counts: tokens used N / M: cost = $…",
            "Status footer health-polls gateway, database, and OpenRouter every 20s (with wake-on-failure) so idle no longer leaves them stuck red",
        ]),
        ChangelogEntry(version: "0.4.0", changes: [
            "New: ARIL-managed Nmap security scanner over MCP — enable it in Preferences → MCP and use nmap in Auto/Manual chat",
            "New: ARIL-managed Semgrep code scanner over MCP — static analysis of files, folders, or inline code snippets (auto/security rulesets or your own YAML rule)",
            "ARIL generates the bearer token, writes a localhost-only config, and launches each server so token + config never drift",
            "Detects whether nmap / semgrep are installed and prompts `brew install nmap` / `brew install semgrep` when missing",
            "Live scans: nmap and semgrep progress now stream into the reply as the scan runs",
            "Slash commands with a live `/` palette: /status (gateway, OpenRouter latency + credits, Nmap, code scan, MCP, latest release), /nmap and /codescan (example scanner prompts; flagged when the server is disabled), /clear, and /help",
            "Prompt history: press ↑ / ↓ in the prompt box to recall your last 10 prompts",
        ]),
    ]
}
