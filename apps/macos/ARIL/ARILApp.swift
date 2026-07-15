import SwiftUI
import AppKit

@main
struct ARILApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var theme = ThemeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(theme)
                .frame(minWidth: 980, minHeight: 640)
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
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    appState.openToolPanel(.preferences)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
