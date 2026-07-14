import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            ChatDetailView()
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
