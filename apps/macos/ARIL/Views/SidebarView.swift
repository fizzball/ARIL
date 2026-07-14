import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @State private var query = ""

    private var filtered: [ChatSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return state.sessions }
        return state.sessions.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                state.createSession()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 16)
                    Text("New session")
                    Spacer()
                    Text("⌘N")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted.opacity(0.7))
                }
                .foregroundStyle(theme.palette.text)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            // ScrollView + explicit grow — List inside NavigationSplitView was
            // often sizing to a single row even when sessions.count > 1.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        Text(state.sessions.isEmpty ? "No sessions yet" : "No matches")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filtered, id: \.id) { session in
                            SessionRow(sessionID: session.id)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(
                                            state.selectedSessionID == session.id
                                                ? theme.palette.accent.opacity(0.18)
                                                : Color.clear
                                        )
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    state.selectedSessionID = session.id
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.sidebar)
        .onAppear {
            if state.selectedSessionID == nil {
                state.selectedSessionID = state.sessions.first?.id
            }
        }
        .onChange(of: state.sessions.map(\.id)) { _, ids in
            if let selected = state.selectedSessionID, ids.contains(selected) { return }
            state.selectedSessionID = ids.first
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let sessionID: UUID
    @State private var hovering = false

    private var live: ChatSession? {
        state.sessions.first(where: { $0.id == sessionID })
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(live?.title ?? "Session")
                    .font(ARILTheme.bodyFont)
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted.opacity(0.8))
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    Task { await state.deleteSession(sessionID) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.danger)
                }
                .buttonStyle(.plain)
                .help("Delete session")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        guard let live else { return "Empty" }
        return live.messages.isEmpty ? "Empty" : "\(live.messages.count) messages"
    }
}
