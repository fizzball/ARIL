import Foundation
import PDFKit
import AppKit

/// Metadata for a file attached to a Project (sidebar folder).
struct ProjectFileRecord: Identifiable, Hashable, Codable {
    let id: UUID
    var filename: String
    var relativePath: String
    var mimeType: String
    var byteCount: Int
    var extractedChars: Int
    var chunkCount: Int
    var addedAt: Date
    var updatedAt: Date
    var status: String
    var errorMessage: String?

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

struct ProjectFileChunk: Hashable, Codable {
    let fileID: UUID
    let filename: String
    let index: Int
    let text: String
}

/// Local project knowledge base: originals on disk, extracted text + chunks for RAG-lite retrieval.
enum ProjectKnowledgeStore {
    static let maxFileBytes = 25_000_000
    static let maxProjectBytes = 100_000_000
    static let maxContextChars = 8_000
    static let maxChunksPerQuery = 8
    static let chunkTargetChars = 1_600
    static let chunkOverlapChars = 200

    private struct ProjectIndex: Codable {
        var files: [ProjectFileRecord]
        var chunks: [ProjectFileChunk]
    }

    // MARK: - Paths

    static func projectsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ARIL/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func projectDir(_ projectID: UUID) -> URL {
        let dir = projectsRoot().appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("files", isDirectory: true),
            withIntermediateDirectories: true
        )
        return dir
    }

    private static func indexURL(_ projectID: UUID) -> URL {
        projectDir(projectID).appendingPathComponent("index.json")
    }

    private static func loadIndex(_ projectID: UUID) -> ProjectIndex {
        let url = indexURL(projectID)
        guard let data = try? Data(contentsOf: url) else {
            return ProjectIndex(files: [], chunks: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ProjectIndex.self, from: data) else {
            return ProjectIndex(files: [], chunks: [])
        }
        return decoded
    }

    private static func saveIndex(_ projectID: UUID, _ index: ProjectIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        try data.write(to: indexURL(projectID), options: .atomic)
    }

    // MARK: - Public API

    static func listFiles(projectID: UUID) -> [ProjectFileRecord] {
        loadIndex(projectID).files.sorted { $0.addedAt > $1.addedAt }
    }

    /// Absolute URL for a stored project file (copy under Application Support).
    static func storedFileURL(projectID: UUID, file: ProjectFileRecord) -> URL {
        projectDir(projectID).appendingPathComponent(file.relativePath)
    }

    /// Folder that holds this project's attached file copies.
    static func filesDirectory(projectID: UUID) -> URL {
        projectDir(projectID).appendingPathComponent("files", isDirectory: true)
    }

    /// Reveal the project files folder (or a specific file) in Finder.
    static func revealInFinder(projectID: UUID, file: ProjectFileRecord? = nil) {
        if let file {
            let url = storedFileURL(projectID: projectID, file: file)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }
        let dir = filesDirectory(projectID: projectID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    static func deleteProjectDirectory(_ projectID: UUID) {
        let dir = projectDir(projectID)
        try? FileManager.default.removeItem(at: dir)
    }

    static func totalBytes(projectID: UUID) -> Int {
        listFiles(projectID: projectID).reduce(0) { $0 + $1.byteCount }
    }

    @discardableResult
    static func addFile(projectID: UUID, from sourceURL: URL) throws -> ProjectFileRecord {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: sourceURL)
        guard !data.isEmpty else {
            throw KnowledgeError.emptyFile
        }
        guard data.count <= maxFileBytes else {
            throw KnowledgeError.fileTooLarge(maxFileBytes)
        }
        let existing = totalBytes(projectID: projectID)
        guard existing + data.count <= maxProjectBytes else {
            throw KnowledgeError.projectTooLarge(maxProjectBytes)
        }

        let filename = sourceURL.lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        guard isSupportedExtension(ext) else {
            throw KnowledgeError.unsupportedType(ext)
        }

        let fileID = UUID()
        let storedName = "\(fileID.uuidString.lowercased()).\(ext.isEmpty ? "bin" : ext)"
        let dest = projectDir(projectID)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(storedName)
        try data.write(to: dest, options: .atomic)

        let extracted: String
        do {
            extracted = try extractText(data: data, filename: filename, ext: ext)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }

        let chunks = chunkText(extracted, fileID: fileID, filename: filename)
        var index = loadIndex(projectID)
        // Replace same filename if re-added.
        let replacedIDs = Set(index.files.filter { $0.filename == filename }.map(\.id))
        index.files.removeAll { replacedIDs.contains($0.id) }
        index.chunks.removeAll { replacedIDs.contains($0.fileID) }
        for id in replacedIDs {
            let old = projectDir(projectID)
                .appendingPathComponent("files", isDirectory: true)
            if let match = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(id.uuidString.lowercased()) }) {
                try? FileManager.default.removeItem(at: match)
            }
        }

        let record = ProjectFileRecord(
            id: fileID,
            filename: filename,
            relativePath: "files/\(storedName)",
            mimeType: mimeType(for: ext),
            byteCount: data.count,
            extractedChars: extracted.count,
            chunkCount: chunks.count,
            addedAt: .now,
            updatedAt: .now,
            status: extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "ready",
            errorMessage: extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No extractable text found"
                : nil
        )
        index.files.insert(record, at: 0)
        index.chunks.append(contentsOf: chunks)
        try saveIndex(projectID, index)
        return record
    }

    static func removeFile(projectID: UUID, fileID: UUID) throws {
        var index = loadIndex(projectID)
        guard let file = index.files.first(where: { $0.id == fileID }) else { return }
        let url = projectDir(projectID).appendingPathComponent(file.relativePath)
        try? FileManager.default.removeItem(at: url)
        index.files.removeAll { $0.id == fileID }
        index.chunks.removeAll { $0.fileID == fileID }
        try saveIndex(projectID, index)
    }

    /// Build system-prompt notes: inventory + retrieved excerpts for the user prompt.
    static func contextNotes(
        projectID: UUID,
        projectName: String,
        prompt: String
    ) -> [String] {
        let index = loadIndex(projectID)
        guard !index.files.isEmpty else { return [] }

        var lines: [String] = []
        lines.append("## Project knowledge: \(projectName)")
        lines.append(
            "The following files belong to this project. Prefer them when answering questions about the project’s documents."
        )
        lines.append(
            "When the user asks to list, show, or name project files, answer only from this inventory. Do not emit ```aril-shell``` or run `ls` for that — Project files are not the Mac home directory."
        )
        lines.append("### Files")
        for file in index.files.sorted(by: { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }) {
            let status = file.status == "ready" ? "" : " (\(file.status))"
            lines.append(
                "- \(file.filename) · \(file.displaySize) · ~\(max(1, file.extractedChars / 4)) tokens\(status)"
            )
        }

        let retrieved = retrieveChunks(index: index, prompt: prompt, limit: maxChunksPerQuery)
        if !retrieved.isEmpty {
            lines.append("### Excerpts retrieved for this turn")
            var budget = maxContextChars
            for chunk in retrieved {
                let header = "[\(chunk.filename) · part \(chunk.index + 1)]"
                let body = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                let block = "\(header)\n\(body)"
                if block.count > budget {
                    let keep = max(0, budget - header.count - 20)
                    if keep > 80 {
                        lines.append("\(header)\n\(body.prefix(keep))…")
                    }
                    break
                }
                lines.append(block)
                budget -= block.count + 2
                if budget < 200 { break }
            }
        }

        return [lines.joined(separator: "\n")]
    }

    static func isSupportedExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return [
            "txt", "md", "markdown", "csv", "tsv", "rtf",
            "pdf",
            "docx",
            "xlsx", "xlsm",
        ].contains(e)
    }

    static var supportedTypesDescription: String {
        "Word (.docx), Excel (.xlsx), PDF, RTF, CSV/TSV, and text/Markdown"
    }

    // MARK: - Retrieval

    private static func retrieveChunks(
        index: ProjectIndex,
        prompt: String,
        limit: Int
    ) -> [ProjectFileChunk] {
        let terms = tokenize(prompt)
        guard !terms.isEmpty, !index.chunks.isEmpty else {
            // No query terms — return leading chunks from each file (small files).
            var picked: [ProjectFileChunk] = []
            for file in index.files.prefix(4) {
                if let first = index.chunks.first(where: { $0.fileID == file.id }) {
                    picked.append(first)
                }
            }
            return Array(picked.prefix(limit))
        }

        let scored: [(ProjectFileChunk, Int)] = index.chunks.map { chunk in
            let hay = chunk.text.lowercased()
            var score = 0
            for term in terms {
                if hay.contains(term) {
                    score += term.count >= 4 ? 3 : 1
                    // Bonus for denser matches
                    let count = hay.components(separatedBy: term).count - 1
                    score += min(count, 5)
                }
            }
            return (chunk, score)
        }
        .filter { $0.1 > 0 }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.index < rhs.0.index
        }

        if scored.isEmpty {
            return Array(index.chunks.prefix(min(3, limit)))
        }
        return Array(scored.prefix(limit).map(\.0))
    }

    private static func tokenize(_ text: String) -> [String] {
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        // Drop ultra-common words.
        let stop: Set<String> = [
            "the", "and", "for", "that", "with", "this", "from", "your", "have",
            "what", "when", "where", "which", "about", "into", "than", "then",
            "please", "could", "would", "should", "there", "their", "them",
        ]
        var seen = Set<String>()
        var out: [String] = []
        for t in cleaned where !stop.contains(t) {
            if seen.insert(t).inserted {
                out.append(t)
            }
        }
        return out
    }

    // MARK: - Chunking

    private static func chunkText(_ text: String, fileID: UUID, filename: String) -> [ProjectFileChunk] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        if normalized.count <= chunkTargetChars {
            return [ProjectFileChunk(fileID: fileID, filename: filename, index: 0, text: normalized)]
        }

        var chunks: [ProjectFileChunk] = []
        var start = normalized.startIndex
        var index = 0
        while start < normalized.endIndex {
            let remaining = normalized.distance(from: start, to: normalized.endIndex)
            let take = min(chunkTargetChars, remaining)
            var end = normalized.index(start, offsetBy: take)
            if end < normalized.endIndex {
                // Prefer breaking on paragraph / sentence.
                let windowStart = normalized.index(start, offsetBy: max(0, take / 2))
                let window = normalized[windowStart..<end]
                if let para = window.range(of: "\n\n", options: .backwards)?.upperBound {
                    end = para
                } else if let sent = window.range(of: ". ", options: .backwards)?.upperBound {
                    end = sent
                }
            }
            let slice = String(normalized[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty {
                chunks.append(ProjectFileChunk(fileID: fileID, filename: filename, index: index, text: slice))
                index += 1
            }
            if end >= normalized.endIndex { break }
            let back = min(chunkOverlapChars, normalized.distance(from: start, to: end))
            let next = normalized.index(end, offsetBy: -back)
            start = next > start ? next : end
            if chunks.count >= 200 { break }
        }
        return chunks
    }

    // MARK: - Extraction

    private static func extractText(data: Data, filename: String, ext: String) throws -> String {
        switch ext.lowercased() {
        case "txt", "md", "markdown", "csv", "tsv":
            if let s = String(data: data, encoding: .utf8) { return s }
            if let s = String(data: data, encoding: .isoLatin1) { return s }
            throw KnowledgeError.unreadableText
        case "rtf":
            return try extractRTF(data)
        case "pdf":
            return try extractPDF(data)
        case "docx":
            return try extractDOCX(data)
        case "xlsx", "xlsm":
            return try extractXLSX(data)
        default:
            throw KnowledgeError.unsupportedType(ext)
        }
    }

    private static func extractRTF(_ data: Data) throws -> String {
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw KnowledgeError.unreadableText }
        return attributed.string
    }

    private static func extractPDF(_ data: Data) throws -> String {
        guard let doc = PDFDocument(data: data) else {
            throw KnowledgeError.pdfFailed
        }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let s = page.string else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        let joined = parts.joined(separator: "\n\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KnowledgeError.noTextInPDF
        }
        return joined
    }

    private static func extractDOCX(_ data: Data) throws -> String {
        let xml = try zipEntryString(data: data, pathSuffix: "word/document.xml")
        return stripXML(xml)
    }

    private static func extractXLSX(_ data: Data) throws -> String {
        let shared: [String]
        if let sharedXML = try? zipEntryString(data: data, pathSuffix: "xl/sharedStrings.xml") {
            shared = extractTaggedText(sharedXML, tag: "t")
        } else {
            shared = []
        }

        var sheetBodies: [String] = []
        // Prefer first few worksheets.
        for i in 1...5 {
            let name = "xl/worksheets/sheet\(i).xml"
            guard let sheetXML = try? zipEntryString(data: data, pathSuffix: name) else { break }
            let rows = parseXLSXSheet(sheetXML, sharedStrings: shared)
            if !rows.isEmpty {
                sheetBodies.append("## Sheet \(i)\n" + rows.joined(separator: "\n"))
            }
        }
        let joined = sheetBodies.joined(separator: "\n\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Fallback: dump any shared strings.
            if !shared.isEmpty {
                return shared.joined(separator: "\n")
            }
            throw KnowledgeError.excelFailed
        }
        return joined
    }

    private static func parseXLSXSheet(_ xml: String, sharedStrings: [String]) -> [String] {
        // Very small worksheet parser: collect <c> cells per <row>.
        var rows: [String] = []
        let rowPattern = try! NSRegularExpression(pattern: #"<row\b[^>]*>([\s\S]*?)</row>"#, options: [])
        let cellPattern = try! NSRegularExpression(
            pattern: #"<c\b([^>]*)>(?:[\s\S]*?<v>([\s\S]*?)</v>)?"#,
            options: []
        )
        let ns = xml as NSString
        for rowMatch in rowPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            guard rowMatch.numberOfRanges >= 2 else { continue }
            let rowXML = ns.substring(with: rowMatch.range(at: 1))
            let rowNS = rowXML as NSString
            var cells: [String] = []
            for cellMatch in cellPattern.matches(in: rowXML, range: NSRange(location: 0, length: rowNS.length)) {
                let attrs = cellMatch.numberOfRanges > 1 ? rowNS.substring(with: cellMatch.range(at: 1)) : ""
                let rawV = cellMatch.numberOfRanges > 2 && cellMatch.range(at: 2).location != NSNotFound
                    ? rowNS.substring(with: cellMatch.range(at: 2))
                    : ""
                let isShared = attrs.contains("t=\"s\"")
                if isShared, let idx = Int(rawV.trimmingCharacters(in: .whitespacesAndNewlines)),
                   idx >= 0, idx < sharedStrings.count {
                    cells.append(sharedStrings[idx])
                } else if !rawV.isEmpty {
                    cells.append(rawV.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            let line = cells.joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { rows.append(line) }
            if rows.count >= 2_000 { break }
        }
        return rows
    }

    private static func extractTaggedText(_ xml: String, tag: String) -> [String] {
        let pattern = try! NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>",
            options: [.caseInsensitive]
        )
        let ns = xml as NSString
        return pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            let raw = ns.substring(with: match.range(at: 1))
            let text = stripXML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private static func stripXML(_ xml: String) -> String {
        var text = xml
        // Soft breaks / paragraphs in Word.
        text = text.replacingOccurrences(of: "</w:p>", with: "\n")
        text = text.replacingOccurrences(of: "<w:tab/>", with: "\t")
        text = text.replacingOccurrences(of: "<br/>", with: "\n")
        text = text.replacingOccurrences(of: "<br />", with: "\n")
        if let tag = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) {
            text = tag.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        text = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#10;", with: "\n")
        if let ws = try? NSRegularExpression(pattern: #"[ \t]+\n"#, options: []) {
            text = ws.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "\n"
            )
        }
        if let multi = try? NSRegularExpression(pattern: #"\n{3,}"#, options: []) {
            text = multi.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "\n\n"
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read a single ZIP entry by path suffix using `/usr/bin/unzip -p`.
    private static func zipEntryString(data: Data, pathSuffix: String) throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aril-pk-\(UUID().uuidString).zip")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", tmp.path, pathSuffix]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let bytes = out.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, !bytes.isEmpty else {
            throw KnowledgeError.zipEntryMissing(pathSuffix)
        }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        if let s = String(data: bytes, encoding: .isoLatin1) { return s }
        throw KnowledgeError.unreadableText
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "txt": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "tsv": return "text/tab-separated-values"
        case "pdf": return "application/pdf"
        case "rtf": return "text/rtf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx", "xlsm": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: return "application/octet-stream"
        }
    }

    enum KnowledgeError: LocalizedError {
        case emptyFile
        case fileTooLarge(Int)
        case projectTooLarge(Int)
        case unsupportedType(String)
        case unreadableText
        case pdfFailed
        case noTextInPDF
        case excelFailed
        case zipEntryMissing(String)

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "The file is empty."
            case .fileTooLarge(let max):
                return "File exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(max), countStyle: .file)) limit."
            case .projectTooLarge(let max):
                return "Project files would exceed the \(ByteCountFormatter.string(fromByteCount: Int64(max), countStyle: .file)) limit."
            case .unsupportedType(let ext):
                return "Unsupported type .\(ext). Supported: \(ProjectKnowledgeStore.supportedTypesDescription)."
            case .unreadableText: return "Could not decode text from the file."
            case .pdfFailed: return "Could not open the PDF."
            case .noTextInPDF: return "This PDF has no extractable text (it may be image-only)."
            case .excelFailed: return "Could not extract cells from the Excel workbook."
            case .zipEntryMissing(let path): return "Missing package entry \(path)."
            }
        }
    }
}
