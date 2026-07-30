import SwiftUI
import AppKit

@main
struct ARILApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var theme = ThemeStore()
    @StateObject private var statusBar = StatusBarController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(theme)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    statusBar.setEnabled(appState.showInMenuBar)
                    statusBar.setBusy(appState.isSending)
                }
                .onChange(of: appState.showInMenuBar) { _, enabled in
                    statusBar.setEnabled(enabled)
                    if enabled {
                        statusBar.setBusy(appState.isSending)
                    }
                }
                .onChange(of: appState.isSending) { _, busy in
                    statusBar.setBusy(busy)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.shutdown()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    appState.createSession()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About ARIL") {
                    appState.openToolPanel(.about)
                }
            }
            CommandGroup(replacing: .help) {
                Button("ARIL Help") {
                    if let url = URL(string: "https://aril.host/help/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(theme)
                .preferredColorScheme(theme.preferredColorScheme)
        }
    }
}
