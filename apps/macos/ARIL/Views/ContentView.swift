import SwiftUI

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
                Button { Task { await state.refreshHealth() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh gateway status")
            }
        }
        .preferredColorScheme(theme.palette.colorScheme)
        .task {
            await state.refreshHealth()
        }
    }
}
