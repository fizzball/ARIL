import Foundation
import AppKit
import CoreText
import UniformTypeIdentifiers

enum DocumentExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case docx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "Word"
        }
    }

    var fileExtension: String { rawValue }

    var utType: UTType {
        switch self {
        case .pdf: return .pdf
        case .docx:
            return UTType(filenameExtension: "docx")
                ?? UTType(exportedAs: "org.openxmlformats.wordprocessingml.document")
        }
    }

    static func parse(_ raw: String) -> DocumentExportFormat? {
        switch raw.lowercased() {
        case "pdf": return .pdf
        case "docx", "word", "doc": return .docx
        default: return nil
        }
    }

    /// Unique default stem so Save panels don't collide within a session (`ARIL-2026-07-30-162105`).
    static func timestampedFilename(format: DocumentExportFormat, date: Date = .now) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return "ARIL-\(df.string(from: date)).\(format.fileExtension)"
    }
}

/// Writes plain-text chat content to PDF or a minimal .docx package.
enum DocumentExportService {
    enum ExportError: LocalizedError {
        case emptyContent
        case pdfFailed
        case zipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .emptyContent: return "Nothing to export — no assistant reply yet."
            case .pdfFailed: return "Could not create the PDF."
            case .zipFailed(let code): return "Could not build the Word file (zip exit \(code))."
            }
        }
    }

    static func write(text: String, title: String, format: DocumentExportFormat, to url: URL) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ExportError.emptyContent }
        switch format {
        case .pdf:
            try writePDF(text: body, title: title, to: url)
        case .docx:
            try writeDocx(text: body, title: title, to: url)
        }
    }

    // MARK: - PDF

    private static func writePDF(text: String, title: String, to url: URL) throws {
        // Always black on white — `labelColor` is near-white in dark appearance and yields blank PDFs.
        let titleFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let ink = NSColor.black
        let full = NSMutableAttributedString()
        full.append(NSAttributedString(string: title + "\n\n", attributes: [
            .font: titleFont,
            .foregroundColor: ink,
        ]))
        full.append(NSAttributedString(string: text, attributes: [
            .font: bodyFont,
            .foregroundColor: ink,
        ]))

        let data = try renderPaginatedPDF(
            attributed: full,
            pageWidth: 612,
            pageHeight: 792,
            margin: 54
        )
        try data.write(to: url, options: .atomic)
    }

    private static func renderPaginatedPDF(
        attributed: NSAttributedString,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat
    ) throws -> Data {
        let contentWidth = pageWidth - margin * 2
        let contentHeight = pageHeight - margin * 2
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExportError.pdfFailed
        }

        // Ensure Core Text sees opaque black even if attributes were theme-colored.
        let printable = NSMutableAttributedString(attributedString: attributed)
        printable.addAttribute(
            .foregroundColor,
            value: NSColor.black,
            range: NSRange(location: 0, length: printable.length)
        )

        let framesetter = CTFramesetterCreateWithAttributedString(printable as CFAttributedString)
        var textPos = CFRange(location: 0, length: 0)
        let total = printable.length
        var pages = 0

        while textPos.location < total {
            ctx.beginPDFPage(nil)

            // PDF space: origin bottom-left. CTFramesetter fills the path from the top.
            let path = CGMutablePath()
            path.addRect(CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight))
            let frame = CTFramesetterCreateFrame(framesetter, textPos, path, nil)
            CTFrameDraw(frame, ctx)

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 {
                // Avoid an infinite blank-page loop if layout fails.
                ctx.endPDFPage()
                break
            }
            textPos.location += visible.length
            pages += 1
            ctx.endPDFPage()
            if pages > 500 { break }
        }

        // Guarantee at least one page so the file opens even for tiny payloads.
        if pages == 0 {
            ctx.beginPDFPage(nil)
            ctx.endPDFPage()
            throw ExportError.pdfFailed
        }

        ctx.closePDF()
        return data as Data
    }

    // MARK: - DOCX (minimal OOXML)

    private static func writeDocx(text: String, title: String, to url: URL) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aril-docx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let word = tmp.appendingPathComponent("word", isDirectory: true)
        let rels = tmp.appendingPathComponent("_rels", isDirectory: true)
        let wordRels = word.appendingPathComponent("_rels", isDirectory: true)
        try FileManager.default.createDirectory(at: wordRels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rels, withIntermediateDirectories: true)

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        try contentTypes.write(
            to: tmp.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        try rootRels.write(to: rels.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        </Relationships>
        """
        try docRels.write(
            to: wordRels.appendingPathComponent("document.xml.rels"),
            atomically: true,
            encoding: .utf8
        )

        var paragraphs = xmlParagraph(title, bold: true)
        paragraphs += xmlParagraph("", bold: false)
        for line in text.components(separatedBy: "\n") {
            paragraphs += xmlParagraph(line, bold: false)
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(paragraphs)
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """
        try document.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tmp
        zip.arguments = ["-qr", url.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw ExportError.zipFailed(zip.terminationStatus)
        }
    }

    private static func xmlParagraph(_ text: String, bold: Bool) -> String {
        if text.isEmpty { return "<w:p/>" }
        let escaped = xmlEscape(text)
        let rPr = bold ? "<w:rPr><w:b/></w:rPr>" : ""
        return "<w:p><w:r>\(rPr)<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
