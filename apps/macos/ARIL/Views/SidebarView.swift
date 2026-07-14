import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
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
                sidebarButton("Capabilities", systemImage: "sparkles") {}
                sidebarButton("Artifacts", systemImage: "doc.richtext") {}
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
                    Text(session.title)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                        .tag(session.id)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Image(systemName: "house")
                Image(systemName: "plus")
                Image(systemName: "ellipsis")
                Spacer()
            }
            .foregroundStyle(theme.palette.textMuted)
            .padding(14)
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
