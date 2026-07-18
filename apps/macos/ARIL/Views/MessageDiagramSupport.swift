import SwiftUI
import AppKit
import WebKit

// MARK: - Segments

enum MessageSegment {
    case text(String)
    case image(url: String, alt: String)
    case mermaid(String)
    case svg(String)
    case ascii(String)
}

enum MessageContentParser {
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#,
        options: []
    )

    /// Complete fenced block: optional language on the opening fence.
    private static let fencePattern = try! NSRegularExpression(
        pattern: #"```([^\n`]*)\n([\s\S]*?)```"#,
        options: []
    )

    private static let svgTagPattern = try! NSRegularExpression(
        pattern: #"<svg\b[\s\S]*?</svg>"#,
        options: [.caseInsensitive]
    )

    private static let mermaidStarters: [String] = [
        "graph ", "graph\n", "flowchart ", "flowchart\n",
        "sequencediagram", "classdiagram", "statediagram", "erdiagram",
        "gantt", "pie ", "pie\n", "mindmap", "timeline", "gitgraph",
        "journey", "quadrantchart", "sankey", "xychart", "block-beta",
        "c4context", "requirementdiagram",
    ]

    static func segments(from content: String) -> [MessageSegment] {
        guard !content.isEmpty else { return [] }

        struct Hit {
            let range: NSRange
            let segment: MessageSegment
        }

        let ns = content as NSString
        var hits: [Hit] = []
        var claimed = IndexSet()

        func claim(_ range: NSRange) -> Bool {
            let indices = IndexSet(integersIn: range.location ..< (range.location + range.length))
            if !claimed.intersection(indices).isEmpty { return false }
            claimed.formUnion(indices)
            return true
        }

        // 1) Complete fenced code blocks (mermaid / svg / ascii / auto-detect).
        for match in fencePattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let full = match.range
            guard claim(full) else { continue }
            let lang = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let body = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            guard !body.isEmpty else { continue }

            if let kind = classifyFence(lang: lang, body: body) {
                hits.append(Hit(range: full, segment: kind))
            } else {
                // Leave ordinary code fences as plain text (including the fences).
                claimed.remove(integersIn: full.location ..< (full.location + full.length))
            }
        }

        // 2) Inline <svg>…</svg> not already inside a claimed fence.
        for match in svgTagPattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard claim(match.range) else { continue }
            let raw = ns.substring(with: match.range)
            hits.append(Hit(range: match.range, segment: .svg(sanitizeSVG(raw))))
        }

        // 3) Markdown images (including svg data/file URLs — routed at render time).
        for match in imagePattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            guard claim(match.range) else { continue }
            let alt = ns.substring(with: match.range(at: 1))
            let url = ns.substring(with: match.range(at: 2))
            if looksLikeSVGURL(url) {
                if let svg = svgPayload(from: url) {
                    hits.append(Hit(range: match.range, segment: .svg(sanitizeSVG(svg))))
                } else {
                    hits.append(Hit(range: match.range, segment: .image(url: url, alt: alt)))
                }
            } else {
                hits.append(Hit(range: match.range, segment: .image(url: url, alt: alt)))
            }
        }

        hits.sort { $0.range.location < $1.range.location }

        var out: [MessageSegment] = []
        var cursor = 0
        for hit in hits {
            if hit.range.location > cursor {
                let before = ns.substring(
                    with: NSRange(location: cursor, length: hit.range.location - cursor)
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    out.append(.text(before))
                }
            }
            out.append(hit.segment)
            cursor = hit.range.location + hit.range.length
        }
        if cursor < ns.length {
            let after = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty {
                out.append(.text(after))
            }
        }
        return out
    }

    private static func classifyFence(lang: String, body: String) -> MessageSegment? {
        let langHead = lang.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch langHead {
        case "mermaid", "mmd":
            return .mermaid(body)
        case "svg":
            return .svg(sanitizeSVG(body))
        case "ascii", "asciiart", "asc", "figlet", "ansi":
            return .ascii(body)
        case "xml" where body.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("<svg"):
            return .svg(sanitizeSVG(body))
        case "text", "plaintext", "":
            return autoDetect(body)
        default:
            // Named languages (python, json, …) stay as plain fenced text.
            return nil
        }
    }

    private static func autoDetect(_ body: String) -> MessageSegment? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<svg") {
            return .svg(sanitizeSVG(trimmed))
        }
        if mermaidStarters.contains(where: { lower.hasPrefix($0) }) {
            return .mermaid(trimmed)
        }
        let first = lower.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map(String.init) ?? ""
        let mermaidTokens: Set<String> = [
            "graph", "flowchart", "sequencediagram", "classdiagram", "statediagram-v2",
            "statediagram", "erdiagram", "gantt", "pie", "mindmap", "timeline",
            "gitgraph", "journey", "quadrantchart", "requirementdiagram", "c4context",
        ]
        if mermaidTokens.contains(first) {
            return .mermaid(trimmed)
        }
        if looksLikeASCIIArt(trimmed) {
            return .ascii(trimmed)
        }
        return nil
    }

    /// Box-drawing / dense monospace diagram heuristic.
    static func looksLikeASCIIArt(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return false }
        let boxScalars: Set<Character> = Set("┌┐└┘├┤┬┴┼─│╔╗╚╝╠╣╦╩╬═║┏┓┗┛┣┫┳┻╋━┃╭╮╰╯╱╲╳▀▄█▌▐░▒▓+-|/_\\<>^v*")
        var boxy = 0
        var total = 0
        for line in lines {
            for ch in line {
                total += 1
                if boxScalars.contains(ch) { boxy += 1 }
            }
        }
        guard total >= 24 else { return false }
        let ratio = Double(boxy) / Double(total)
        // Either enough box chars, or multiple lines dominated by pipes/dashes.
        if ratio >= 0.12 { return true }
        let structural = lines.filter { line in
            let s = String(line)
            return s.contains("|") && (s.contains("-") || s.contains("+") || s.contains("_"))
        }
        return structural.count >= 3
    }

    private static func looksLikeSVGURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.hasPrefix("data:image/svg+xml") { return true }
        if let u = URL(string: url), u.pathExtension.lowercased() == "svg" { return true }
        return false
    }

    private static func svgPayload(from urlString: String) -> String? {
        let lower = urlString.lowercased()
        if lower.hasPrefix("data:image/svg+xml") {
            guard let comma = urlString.firstIndex(of: ",") else { return nil }
            let meta = String(urlString[..<comma]).lowercased()
            let payload = String(urlString[urlString.index(after: comma)...])
            if meta.contains(";base64") {
                guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
                      let text = String(data: data, encoding: .utf8) else { return nil }
                return text
            }
            return payload.removingPercentEncoding ?? payload
        }
        guard let url = URL(string: urlString),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Strip scripts / event handlers so untrusted model SVG can’t run JS in WKWebView.
    static func sanitizeSVG(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(
            of: #"<script[\s\S]*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"\son[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"javascript:"#,
            with: "",
            options: [.caseInsensitive]
        )
        return s
    }
}

// MARK: - Assistant content

struct AssistantMarkdownContent: View {
    let content: String
    let textColor: Color
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageContentParser.segments(from: content).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(text)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(textColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let urlString, let alt):
                    MarkdownImageView(urlString: urlString, alt: alt)
                case .mermaid(let source):
                    MermaidDiagramView(source: source)
                case .svg(let source):
                    SVGDiagramView(source: source)
                case .ascii(let source):
                    ASCIIArtView(source: source)
                }
            }
        }
    }
}

// MARK: - ASCII

struct ASCIIArtView: View {
    @EnvironmentObject private var theme: ThemeStore
    let source: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            diagramChrome(title: "ASCII", source: source, copied: $copied)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(source)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.palette.assistantText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.inputFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.palette.hairline, lineWidth: 1)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ASCII diagram")
    }
}

// MARK: - Mermaid / SVG (WKWebView)

struct MermaidDiagramView: View {
    @EnvironmentObject private var theme: ThemeStore
    let source: String
    @State private var height: CGFloat = 160
    @State private var errorText: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            diagramChrome(title: "Mermaid", source: source, copied: $copied)
            ZStack(alignment: .topLeading) {
                DiagramWebView(
                    html: MermaidHTMLBuilder.html(
                        source: source,
                        dark: theme.palette.colorScheme == .dark
                    ),
                    height: $height,
                    errorText: $errorText
                )
                .frame(maxWidth: .infinity)
                .frame(height: max(120, height))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.palette.hairline, lineWidth: 1)
                )

                if let errorText {
                    Text(errorText)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.danger)
                        .padding(8)
                        .background(theme.palette.backgroundElevated.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(8)
                }
            }
            // Source fallback always available under the graphic.
            DisclosureGroup("Source") {
                Text(source)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.textMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(ARILTheme.captionFont)
            .foregroundStyle(theme.palette.textMuted)
        }
        .accessibilityLabel("Mermaid diagram")
    }
}

struct SVGDiagramView: View {
    @EnvironmentObject private var theme: ThemeStore
    let source: String
    @State private var height: CGFloat = 160
    @State private var errorText: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            diagramChrome(title: "SVG", source: source, copied: $copied)
            DiagramWebView(
                html: SVGHTMLBuilder.html(
                    source: source,
                    dark: theme.palette.colorScheme == .dark
                ),
                height: $height,
                errorText: $errorText
            )
            .frame(maxWidth: .infinity)
            .frame(height: max(80, height))
            .background(theme.palette.inputFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.palette.hairline, lineWidth: 1)
            )

            if let errorText {
                Text(errorText)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
            }
        }
        .accessibilityLabel("SVG diagram")
    }
}

private func diagramChrome(title: String, source: String, copied: Binding<Bool>) -> some View {
    HStack(spacing: 8) {
        Text(title)
            .font(ARILTheme.captionFont.weight(.semibold))
            .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
            copied.wrappedValue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copied.wrappedValue = false
            }
        } label: {
            Label(copied.wrappedValue ? "Copied" : "Copy source", systemImage: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                .font(ARILTheme.captionFont)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Copy diagram source")
    }
}

// MARK: - HTML builders

enum MermaidHTMLBuilder {
    static func html(source: String, dark: Bool) -> String {
        let escaped = jsonEscape(source)
        let theme = dark ? "dark" : "default"
        let bg = dark ? "#1a1a1a" : "#ffffff"
        let fg = dark ? "#e8e8e8" : "#1a1a1a"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>
          html, body { margin: 0; padding: 8px; background: \(bg); color: \(fg);
            font-family: -apple-system, BlinkMacSystemFont, sans-serif; overflow: hidden; }
          #wrap { width: 100%; }
          .mermaid { display: flex; justify-content: center; }
          .err { color: #c44; font: 12px/1.4 -apple-system, sans-serif; padding: 8px; white-space: pre-wrap; }
        </style>
        <script type="module">
          import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
          const source = \(escaped);
          mermaid.initialize({
            startOnLoad: false,
            theme: "\(theme)",
            securityLevel: "strict",
            fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
          });
          const root = document.getElementById("wrap");
          try {
            const id = "mmd-" + Math.random().toString(36).slice(2);
            const { svg } = await mermaid.render(id, source);
            root.innerHTML = svg;
          } catch (e) {
            root.innerHTML = '<div class="err">Mermaid render failed: ' +
              String(e && e.message ? e.message : e) + '</div>';
            window.webkit?.messageHandlers?.arilDiagram?.postMessage({
              error: String(e && e.message ? e.message : e), height: 80
            });
          }
          requestAnimationFrame(() => {
            const h = Math.ceil(document.documentElement.scrollHeight || document.body.scrollHeight || 160);
            window.webkit?.messageHandlers?.arilDiagram?.postMessage({ height: h });
          });
        </script>
        </head>
        <body><div id="wrap" class="mermaid"></div></body>
        </html>
        """
    }

    private static func jsonEscape(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

enum SVGHTMLBuilder {
    static func html(source: String, dark: Bool) -> String {
        let bg = dark ? "#1a1a1a" : "#ffffff"
        // Keep SVG markup as HTML (already sanitized). Avoid breaking with script injection.
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>
          html, body { margin: 0; padding: 8px; background: \(bg); overflow: hidden; }
          svg { max-width: 100%; height: auto; display: block; margin: 0 auto; }
        </style>
        </head>
        <body>
        \(source)
        <script>
          function report() {
            const h = Math.ceil(document.documentElement.scrollHeight || document.body.scrollHeight || 120);
            window.webkit?.messageHandlers?.arilDiagram?.postMessage({ height: h });
          }
          report();
          requestAnimationFrame(report);
          setTimeout(report, 50);
          setTimeout(report, 250);
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView bridge

final class DiagramMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: (([String: Any]) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let dict = message.body as? [String: Any] {
            onMessage?(dict)
        }
    }
}

struct DiagramWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    @Binding var errorText: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, errorText: $errorText)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let uc = config.userContentController
        uc.add(context.coordinator.handler, name: "arilDiagram")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        #if DEBUG
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        #endif
        context.coordinator.webView = web
        web.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            errorText = nil
            webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "arilDiagram")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var handler = DiagramMessageHandler()
        var lastHTML: String = ""
        var webView: WKWebView?
        private var heightBinding: Binding<CGFloat>
        private var errorBinding: Binding<String?>

        init(height: Binding<CGFloat>, errorText: Binding<String?>) {
            heightBinding = height
            errorBinding = errorText
            super.init()
            handler.onMessage = { [weak self] dict in
                DispatchQueue.main.async {
                    if let h = dict["height"] as? Double {
                        self?.heightBinding.wrappedValue = min(900, max(80, CGFloat(h)))
                    } else if let h = dict["height"] as? Int {
                        self?.heightBinding.wrappedValue = min(900, max(80, CGFloat(h)))
                    }
                    if let err = dict["error"] as? String, !err.isEmpty {
                        self?.errorBinding.wrappedValue = err
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Allow initial document + CDN module scripts; block top-level link clicks out.
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.errorBinding.wrappedValue = "Could not load diagram renderer (network required for Mermaid)."
                self.heightBinding.wrappedValue = 100
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.errorBinding.wrappedValue = error.localizedDescription
            }
        }
    }
}
