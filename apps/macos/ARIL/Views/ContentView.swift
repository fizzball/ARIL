import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if state.gatewayReady && !state.openRouterConfigured {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                        Text("OpenRouter API key required — add it in Preferences to enable live models.")
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
        }
        .background(theme.palette.background)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    state.shutdown()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .help("Quit ARIL")

                Button {
                    state.showAbout = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("About ARIL")
            }
        }
        .preferredColorScheme(theme.palette.colorScheme)
        .task {
            await state.refreshHealth()
        }
    }
}
