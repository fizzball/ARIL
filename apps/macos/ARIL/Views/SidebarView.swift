import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""

    private var filtered: [ChatSession] {
        guard !query.isEmpty else { return state.sessions }
        return state.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                sidebarButton("New session", systemImage: "square.and.pencil", shortcut: "⌘N") {
                    state.createSession()
                }
                sidebarButton("Preferences", systemImage: "gearshape", shortcut: "⌘,") {
                    openSettings()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            TextField("Search sessions…", text: $query)
                .textFieldStyle(.plain)
                .padding(8)
                .background(theme.palette.inputFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            HStack {
                Text("SESSIONS")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                Spacer()
                Text("\(state.sessions.count)")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            List(selection: $state.selectedSessionID) {
                ForEach(filtered) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)
        }
        .background(theme.palette.sidebar)
    }

    private func sidebarButton(
        _ title: String,
        systemImage: String,
        shortcut: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted.opacity(0.7))
                }
            }
            .foregroundStyle(theme.palette.text)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let session: ChatSession
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(session.title)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(theme.palette.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Button {
                    Task { await state.deleteSession(session.id) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.danger)
                }
                .buttonStyle(.plain)
                .help("Delete session")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
