import SwiftUI
import UniformTypeIdentifiers

/// Manage files attached to a Project — extracted text is retrieved into the system prompt.
struct ProjectFilesView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    let projectName: String

    @State private var files: [ProjectFileRecord] = []
    @State private var errorText: String?
    @State private var isImporting = false
    @State private var showImporter = false

    private var totalBytes: Int {
        files.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            if let errorText {
                Text(errorText)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if files.isEmpty {
                emptyState
            } else {
                fileList
            }
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 520, height: 420)
        .background(theme.palette.sidebar)
        .preferredColorScheme(theme.palette.colorScheme)
        .onAppear(perform: reload)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project files")
                    .font(ARILTheme.wordmarkFont)
                    .foregroundStyle(theme.palette.text)
                Text(projectName)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.on.doc")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.palette.textMuted)
            Text("No files yet")
                .font(ARILTheme.bodyFont)
                .foregroundStyle(theme.palette.text)
            Text("Add Word, Excel, PDF, RTF, CSV, or Markdown. Sessions in this project use them as context.")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var fileList: some View {
        List {
            ForEach(files) { file in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName(for: file.filename))
                        .foregroundStyle(theme.palette.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename)
                            .font(ARILTheme.bodyFont)
                            .foregroundStyle(theme.palette.text)
                            .lineLimit(1)
                        Text(subtitle(for: file))
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                    }
                    Spacer(minLength: 8)
                    Button {
                        ProjectKnowledgeStore.revealInFinder(projectID: projectID, file: file)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    Button(role: .destructive) {
                        remove(file)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Remove from project")
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.clear)
                .contextMenu {
                    Button("Reveal in Finder") {
                        ProjectKnowledgeStore.revealInFinder(projectID: projectID, file: file)
                    }
                    Button("Show Project Folder") {
                        ProjectKnowledgeStore.revealInFinder(projectID: projectID)
                    }
                    Divider()
                    Button("Remove", role: .destructive) {
                        remove(file)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                errorText = nil
                showImporter = true
            } label: {
                Label(isImporting ? "Adding…" : "Add files…", systemImage: "plus")
            }
            .disabled(isImporting)

            Button {
                ProjectKnowledgeStore.revealInFinder(projectID: projectID)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Open this project’s files folder in Finder")

            Text("\(files.count) file\(files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)

            Spacer()

            Text(ProjectKnowledgeStore.supportedTypesDescription)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func reload() {
        files = ProjectKnowledgeStore.listFiles(projectID: projectID)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = error.localizedDescription
        case .success(let urls):
            isImporting = true
            defer { isImporting = false }
            var lastError: String?
            for url in urls {
                do {
                    _ = try ProjectKnowledgeStore.addFile(projectID: projectID, from: url)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            reload()
            state.touchProject(projectID)
            if let lastError {
                errorText = lastError
            }
        }
    }

    private func remove(_ file: ProjectFileRecord) {
        do {
            try ProjectKnowledgeStore.removeFile(projectID: projectID, fileID: file.id)
            reload()
            state.touchProject(projectID)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func subtitle(for file: ProjectFileRecord) -> String {
        var parts = [file.displaySize, "\(file.chunkCount) chunk\(file.chunkCount == 1 ? "" : "s")"]
        if file.status != "ready" {
            parts.append(file.errorMessage ?? file.status)
        } else {
            parts.append("~\(max(1, file.extractedChars / 4)) tokens")
        }
        return parts.joined(separator: " · ")
    }

    private func iconName(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "rtf": return "doc.richtext"
        case "docx": return "doc.text"
        case "xlsx", "xlsm", "csv", "tsv": return "tablecells"
        case "md", "markdown": return "text.alignleft"
        default: return "doc"
        }
    }

    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .rtf, .plainText, .utf8PlainText, .commaSeparatedText, .tabSeparatedText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let xlsm = UTType(filenameExtension: "xlsm") { types.append(xlsm) }
        return types
    }
}
