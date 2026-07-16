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
                }
                .onChange(of: appState.showInMenuBar) { _, enabled in
                    statusBar.setEnabled(enabled)
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
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(theme)
                .preferredColorScheme(theme.palette.colorScheme)
        }
    }
}
