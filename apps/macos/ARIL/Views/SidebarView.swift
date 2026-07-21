import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    /// Global search — always scopes across every session (in projects or not).
    @State private var globalQuery = ""
    /// Per-project search text (scoped to that project's sessions only).
    @State private var projectQueries: [UUID: String] = [:]
    @State private var newProjectName = ""
    @State private var showNewProjectSheet = false
    @State private var showRenameProjectSheet = false
    @State private var renameProjectID: UUID?
    @State private var renameProjectName = ""

    private var globalSearchActive: Bool {
        !globalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var globalMatches: [ChatSession] {
        let q = globalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return state.sessions }
        return state.sessions.filter { $0.matchesSearch(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
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

            TextField("Search all sessions & content…", text: $globalQuery)
                .textFieldStyle(.plain)
                .padding(8)
                .background(theme.palette.inputFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .help("Searches every session, including those inside projects")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if globalSearchActive {
                        globalSearchSection
                    } else {
                        projectsSection
                        ungroupedSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let version = state.updateAvailableVersion {
                updateBanner(version: version)
            }
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
        .sheet(isPresented: $showNewProjectSheet) {
            projectNameSheet(
                title: "New Project",
                name: $newProjectName,
                confirmTitle: "Create"
            ) {
                if let project = state.createProject(named: newProjectName) {
                    expandedEnsure(project.id)
                }
                newProjectName = ""
            } onDismiss: {
                showNewProjectSheet = false
            }
        }
        .sheet(isPresented: $showRenameProjectSheet) {
            projectNameSheet(
                title: "Rename Project",
                name: $renameProjectName,
                confirmTitle: "Rename"
            ) {
                if let id = renameProjectID {
                    state.renameProject(id, to: renameProjectName)
                }
                renameProjectName = ""
                renameProjectID = nil
            } onDismiss: {
                showRenameProjectSheet = false
                renameProjectID = nil
            }
        }
    }

    // MARK: - Global search (all sessions)

    @ViewBuilder
    private var globalSearchSection: some View {
        sectionHeader(
            title: "All matches",
            count: "\(globalMatches.count)/\(state.sessions.count)"
        )
        if globalMatches.isEmpty {
            emptyHint(state.sessions.isEmpty ? "No sessions yet" : "No matches")
        } else {
            let q = globalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            ForEach(globalMatches, id: \.id) { session in
                sessionRow(session, searchQuery: q, showProjectBadge: true)
            }
        }
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectsSection: some View {
        HStack {
            Text("Projects")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Spacer()
            Text("\(state.projects.count)")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
                .monospacedDigit()
            Button {
                newProjectName = ""
                showNewProjectSheet = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.accent)
            }
            .buttonStyle(.plain)
            .help("New project")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .padding(.top, 2)

        if state.projects.isEmpty {
            emptyHint("No projects — create one to group sessions")
        } else {
            ForEach(state.projects) { project in
                projectFolder(project)
            }
        }
    }

    @ViewBuilder
    private func projectFolder(_ project: ChatProject) -> some View {
        let expanded = state.expandedProjectIDs.contains(project.id)
        let members = state.sessions(inProject: project.id)
        let projectQuery = (projectQueries[project.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible: [ChatSession] = {
            guard !projectQuery.isEmpty else { return members }
            return members.filter { $0.matchesSearch(projectQuery) }
        }()

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    state.toggleProjectExpanded(project.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.palette.textMuted)
                            .frame(width: 10)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.accent)
                        Text(project.name)
                            .font(ARILTheme.bodyFont)
                            .foregroundStyle(theme.palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(members.count)")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contextMenu {
                Button("New session in project") {
                    state.createSession(inProject: project.id)
                }
                Button("Rename…") {
                    renameProjectName = project.name
                    renameProjectID = project.id
                    showRenameProjectSheet = true
                }
                Divider()
                Button("Delete Project", role: .destructive) {
                    state.deleteProject(project.id)
                    projectQueries[project.id] = nil
                }
            }

            if expanded {
                TextField("Search in \(project.name)…", text: projectQueryBinding(project.id))
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(theme.palette.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.leading, 18)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
                    .help("Searches only sessions in this project")

                if visible.isEmpty {
                    emptyHint(
                        members.isEmpty
                            ? "No sessions in this project"
                            : "No matches in this project",
                        indent: true
                    )
                } else {
                    ForEach(visible, id: \.id) { session in
                        sessionRow(session, searchQuery: projectQuery, showProjectBadge: false)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }

    // MARK: - Ungrouped sessions

    @ViewBuilder
    private var ungroupedSection: some View {
        let ungrouped = state.ungroupedSessions
        sectionHeader(
            title: "Sessions",
            count: "\(ungrouped.count)"
        )
        .padding(.top, state.projects.isEmpty ? 0 : 10)

        if ungrouped.isEmpty {
            emptyHint(state.sessions.isEmpty ? "No sessions yet" : "All sessions are in projects")
        } else {
            ForEach(ungrouped, id: \.id) { session in
                sessionRow(session, searchQuery: "", showProjectBadge: false)
            }
        }
    }

    // MARK: - Shared row

    @ViewBuilder
    private func sessionRow(
        _ session: ChatSession,
        searchQuery: String,
        showProjectBadge: Bool
    ) -> some View {
        SessionRow(
            session: session,
            searchQuery: searchQuery,
            projectBadge: showProjectBadge ? state.project(for: session)?.name : nil
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground(for: session, query: searchQuery))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(contentMatchHighlight(for: session, query: searchQuery), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedSessionID = session.id
        }
    }

    private func sectionHeader(title: String, count: String) -> some View {
        HStack {
            Text(title)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Spacer()
            Text(count)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func emptyHint(_ text: String, indent: Bool = false) -> some View {
        Text(text)
            .font(ARILTheme.captionFont)
            .foregroundStyle(theme.palette.textMuted)
            .padding(.horizontal, indent ? 24 : 12)
            .padding(.vertical, 8)
    }

    private func projectQueryBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { projectQueries[id] ?? "" },
            set: { projectQueries[id] = $0 }
        )
    }

    private func expandedEnsure(_ id: UUID) {
        state.expandedProjectIDs.insert(id)
    }

    private func rowBackground(for session: ChatSession, query: String) -> Color {
        if state.selectedSessionID == session.id {
            return theme.palette.accent.opacity(0.18)
        }
        guard !query.isEmpty, session.matchesSearch(query) else {
            return Color.clear
        }
        return theme.palette.preferredHighlight.opacity(0.10)
    }

    private func contentMatchHighlight(for session: ChatSession, query: String) -> Color {
        guard !query.isEmpty, state.selectedSessionID != session.id else { return .clear }
        if session.title.localizedCaseInsensitiveContains(query) { return .clear }
        if session.messagesContain(query) {
            return theme.palette.preferredHighlight.opacity(0.55)
        }
        return .clear
    }

    @ViewBuilder
    private func updateBanner(version: String) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.palette.hairline)
                .frame(height: 1)
            Button {
                state.startPendingAppUpdate()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Update")
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text("v\(version)")
                        .font(ARILTheme.captionFont)
                        .opacity(0.85)
                }
                .font(ARILTheme.bodyFont)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isUpdatingApp)
            .opacity(state.isUpdatingApp ? 0.6 : 1)
            .background(theme.palette.accentStrong)
            .help("Download ARIL \(version) and install to /Applications")
        }
    }

    private func projectNameSheet(
        title: String,
        name: Binding<String>,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            TextField("Project name", text: name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onConfirm()
                    onDismiss()
                }
            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onConfirm()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let session: ChatSession
    /// Active search text for snippet highlighting (empty when not filtering).
    var searchQuery: String = ""
    /// Optional project name badge (global search results).
    var projectBadge: String? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    titleLabel
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                    if let projectBadge, !projectBadge.isEmpty {
                        Text(projectBadge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.palette.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.palette.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 0) {
                    Text(subtitlePrefix)
                        .foregroundStyle(theme.palette.textMuted.opacity(0.8))
                    Text(session.totalCostLabel)
                        .foregroundStyle(theme.palette.danger)
                        .monospacedDigit()
                }
                .font(ARILTheme.captionFont)

                if let snippet = matchSnippet {
                    Text(snippet)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.preferredHighlight)
                        .lineLimit(2)
                        .help(snippet)
                }

                if !session.messages.isEmpty {
                    let fraction = session.contextFraction
                    let color = contextColor(fraction)
                    HStack(spacing: 6) {
                        ContextUsageBar(fraction: fraction, color: color)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(color)
                            .monospacedDigit()
                    }
                    .help("Approx. model context used: \(session.contextChars.formatted()) / \(ChatSession.maxContextChars.formatted()) characters")
                }
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    _ = state.exportSessionAsMarkdown(session.id)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.accent)
                }
                .buttonStyle(.plain)
                .help("Export session as Markdown")
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Export as Markdown…") {
                _ = state.exportSessionAsMarkdown(session.id)
            }
            Menu("Move to Project") {
                ForEach(state.projects) { project in
                    Button(project.name) {
                        state.moveSession(session.id, toProject: project.id)
                    }
                    .disabled(session.projectID == project.id)
                }
                if !state.projects.isEmpty {
                    Divider()
                }
                Button("New Project…") {
                    // Create then move — parent sheet is on SidebarView; use a quick named project.
                    let name = "Project \(state.projects.count + 1)"
                    if let project = state.createProject(named: name) {
                        state.moveSession(session.id, toProject: project.id)
                    }
                }
                if session.projectID != nil {
                    Divider()
                    Button("Remove from Project") {
                        state.moveSession(session.id, toProject: nil)
                    }
                }
            }
            Divider()
            Button("Delete Session", role: .destructive) {
                Task { await state.deleteSession(session.id) }
            }
        }
    }

    @ViewBuilder
    private var titleLabel: some View {
        Text(session.title)
    }

    private var matchSnippet: String? {
        guard !searchQuery.isEmpty else { return nil }
        return session.searchSnippet(for: searchQuery)
    }

    private var subtitlePrefix: String {
        if session.messages.isEmpty { return "Empty · " }
        return "\(session.messages.count) messages · "
    }

    private func contextColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return theme.palette.danger }
        if fraction >= 0.75 { return theme.palette.preferredHighlight }
        return theme.palette.textMuted.opacity(0.9)
    }
}

/// Thin capacity bar showing how full a session's model context window is.
private struct ContextUsageBar: View {
    @EnvironmentObject private var theme: ThemeStore
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.palette.textMuted.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 3)
    }
}
