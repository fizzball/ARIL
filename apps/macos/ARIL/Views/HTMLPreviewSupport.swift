import SwiftUI
import AppKit
import WebKit

// MARK: - Sandboxed HTML / JS preview

/// Builds a CSP-locked document for untrusted model HTML/JS.
enum HTMLPreviewBuilder {
    static let maxSourceBytes = 250_000

    /// Blocks network, frames, forms, workers; allows inline script/style + data images.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-src 'none'",
        "frame-ancestors 'none'",
        "object-src 'none'",
        "connect-src 'none'",
        "font-src data:",
        "img-src data: blob:",
        "media-src data: blob:",
        "style-src 'unsafe-inline'",
        "script-src 'unsafe-inline'",
        "worker-src 'none'",
    ].joined(separator: "; ")

    enum Kind: String {
        case html
        case javascript
    }

    static func clamp(_ source: String) -> String {
        var s = source.replacingOccurrences(of: "\r\n", with: "\n")
        if s.utf8.count <= maxSourceBytes { return s }
        // Truncate on a UTF-8 boundary.
        var end = s.index(s.startIndex, offsetBy: s.count)
        while s.distance(from: s.startIndex, to: end) > 0 {
            let candidate = String(s[..<end])
            if candidate.utf8.count <= maxSourceBytes {
                return candidate + "\n\n<!-- ARIL: preview truncated (\(maxSourceBytes) byte limit) -->"
            }
            end = s.index(before: end)
        }
        return ""
    }

    static func looksLikeFullHTMLDocument(_ source: String) -> Bool {
        let t = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("<!doctype html") || t.hasPrefix("<html")
    }

    static func document(source: String, kind: Kind, dark: Bool) -> String {
        let clamped = clamp(source)
        switch kind {
        case .javascript:
            return javascriptShell(code: clamped, dark: dark)
        case .html:
            if looksLikeFullHTMLDocument(clamped) {
                return injectSandbox(into: clamped, dark: dark)
            }
            return htmlFragmentShell(fragment: clamped, dark: dark)
        }
    }

    private static func shellColors(dark: Bool) -> (bg: String, fg: String, muted: String) {
        if dark {
            return ("#1a1a1a", "#e8e8e8", "#9a9a9a")
        }
        return ("#ffffff", "#1a1a1a", "#666666")
    }

    private static func heightReporterScript() -> String {
        """
        (function(){
          function arilReport(){
            try {
              var h = Math.ceil(Math.max(
                document.documentElement ? document.documentElement.scrollHeight : 0,
                document.body ? document.body.scrollHeight : 0,
                80
              ));
              window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.arilPreview
                && window.webkit.messageHandlers.arilPreview.postMessage({ height: h });
            } catch (e) {}
          }
          arilReport();
          if (window.ResizeObserver && document.body) {
            try { new ResizeObserver(arilReport).observe(document.body); } catch (e) {}
          }
          setTimeout(arilReport, 50);
          setTimeout(arilReport, 250);
          setTimeout(arilReport, 1000);
        })();
        """
    }

    private static func htmlFragmentShell(fragment: String, dark: Bool) -> String {
        let c = shellColors(dark: dark)
        let payload = Data(fragment.utf8).base64EncodedString()
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)" />
        <style>
          html, body { margin: 0; padding: 12px; background: \(c.bg); color: \(c.fg);
            font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; }
        </style>
        </head>
        <body>
        <script>
        (function(){
          try {
            var html = atob("\(payload)");
            document.body.insertAdjacentHTML("afterbegin", html);
          } catch (e) {
            document.body.textContent = "Preview failed: " + e;
          }
        })();
        \(heightReporterScript())
        </script>
        </body>
        </html>
        """
    }

    private static func javascriptShell(code: String, dark: Bool) -> String {
        let c = shellColors(dark: dark)
        let escaped = jsonEscape(code)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)" />
        <style>
          html, body { margin: 0; padding: 12px; background: \(c.bg); color: \(c.fg);
            font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
          #aril-console { white-space: pre-wrap; color: \(c.muted); margin: 0; min-height: 1.2em; }
          #aril-root { margin-bottom: 8px; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        </style>
        </head>
        <body>
        <div id="aril-root"></div>
        <pre id="aril-console"></pre>
        <script>
        (function(){
          var out = document.getElementById("aril-console");
          function writeLine(level, args) {
            var line = Array.prototype.slice.call(args).map(function(a){
              try {
                if (typeof a === "string") return a;
                return JSON.stringify(a);
              } catch (e) { return String(a); }
            }).join(" ");
            out.textContent += (out.textContent ? "\\n" : "") + (level ? "[" + level + "] " : "") + line;
          }
          console.log = function(){ writeLine("", arguments); };
          console.info = function(){ writeLine("info", arguments); };
          console.warn = function(){ writeLine("warn", arguments); };
          console.error = function(){ writeLine("error", arguments); };
          try {
            var code = \(escaped);
            (0, eval)(code);
          } catch (e) {
            writeLine("error", [String(e && e.stack ? e.stack : e)]);
          }
          \(heightReporterScript())
        })();
        </script>
        </body>
        </html>
        """
    }

    /// Inject CSP + height reporter into a model-supplied full HTML document.
    private static func injectSandbox(into raw: String, dark: Bool) -> String {
        var s = raw
        let lower = s.lowercased()
        if !lower.contains("content-security-policy") {
            let meta = "\n<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\" />\n"
            if let range = s.range(of: "<head", options: .caseInsensitive),
               let close = s[range.upperBound...].firstIndex(of: ">") {
                let insertAt = s.index(after: close)
                s.insert(contentsOf: meta, at: insertAt)
            } else if let range = s.range(of: "<html", options: .caseInsensitive),
                      let close = s[range.upperBound...].firstIndex(of: ">") {
                let insertAt = s.index(after: close)
                s.insert(contentsOf: "<head>\(meta)</head>", at: insertAt)
            } else {
                s = "<!DOCTYPE html><html><head>\(meta)</head><body>\(s)</body></html>"
            }
        }
        let reporter = "\n<script>\(heightReporterScript())</script>\n"
        if let range = s.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            s.insert(contentsOf: reporter, at: range.lowerBound)
        } else {
            s += reporter
        }
        _ = dark // theme is left to the document; shell colors apply to fragments/JS only.
        return s
    }

    private static func jsonEscape(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

// MARK: - Preview UI

struct HTMLPreviewView: View {
    @EnvironmentObject private var theme: ThemeStore
    let source: String
    var kind: HTMLPreviewBuilder.Kind = .html

    @State private var height: CGFloat = 180
    @State private var copied = false
    @State private var showSource = false
    @State private var reloadToken = 0
    @State private var isRunning = true

    private var title: String {
        kind == .javascript ? "JavaScript preview" : "HTML preview"
    }

    private var previewHTML: String {
        HTMLPreviewBuilder.document(
            source: source,
            kind: kind,
            dark: theme.palette.colorScheme == .dark
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chrome
            if isRunning {
                SandboxedPreviewWebView(html: previewHTML, reloadToken: reloadToken, height: $height)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(120, min(720, height)))
                    .background(theme.palette.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.palette.hairline, lineWidth: 1)
                    )
            } else {
                Text("Preview paused — press Run to execute in the sandbox.")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.palette.hairline, lineWidth: 1)
                    )
            }
            DisclosureGroup("Source", isExpanded: $showSource) {
                Text(source)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.textMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(ARILTheme.captionFont)
            .foregroundStyle(theme.palette.textMuted)
        }
        .accessibilityLabel(title)
    }

    private var chrome: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(ARILTheme.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Sandbox · no network")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.palette.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.palette.hairline.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help("Runs inline HTML/JS only. External URLs, fetch, and forms are blocked.")
            Spacer(minLength: 0)
            if isRunning {
                Button {
                    reloadToken += 1
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reload sandbox preview")
                Button {
                    isRunning = false
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    isRunning = true
                    reloadToken += 1
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Run in sandboxed WebKit (no network)")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy source", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy preview source")
        }
    }
}

// MARK: - Sandboxed WKWebView

struct SandboxedPreviewWebView: NSViewRepresentable {
    let html: String
    let reloadToken: Int
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        config.suppressesIncrementalRendering = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()
        let uc = config.userContentController
        uc.add(context.coordinator.handler, name: "arilPreview")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        #if DEBUG
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        #endif
        context.coordinator.webView = web
        // Load only from updateNSView so we don't race a second loadHTMLString
        // that cancels the first (and drops inline JS).
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html || context.coordinator.lastToken != reloadToken {
            context.coordinator.lastHTML = html
            context.coordinator.lastToken = reloadToken
            context.coordinator.load(html: html, into: webView)
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "arilPreview")
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var handler = DiagramMessageHandler()
        var lastHTML = ""
        var lastToken = -1
        var webView: WKWebView?
        private var heightBinding: Binding<CGFloat>
        /// True while a host-initiated loadHTMLString is in flight. loadHTMLString
        /// often emits about:blank then applewebdata — both must be allowed.
        private var trustedLoadInProgress = false

        init(height: Binding<CGFloat>) {
            heightBinding = height
            super.init()
            handler.onMessage = { [weak self] dict in
                DispatchQueue.main.async {
                    if let h = dict["height"] as? Double {
                        self?.heightBinding.wrappedValue = min(720, max(80, CGFloat(h)))
                    } else if let h = dict["height"] as? Int {
                        self?.heightBinding.wrappedValue = min(720, max(80, CGFloat(h)))
                    }
                }
            }
        }

        func load(html: String, into webView: WKWebView) {
            trustedLoadInProgress = true
            // nil baseURL → opaque origin; combined with CSP this keeps the preview offline.
            webView.loadHTMLString(html, baseURL: nil)
        }

        private func endTrustedLoad() {
            trustedLoadInProgress = false
        }

        private func isBlockedScheme(_ scheme: String) -> Bool {
            switch scheme {
            case "http", "https", "file", "ftp", "ws", "wss":
                return true
            default:
                return false
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let scheme = (url?.scheme ?? "").lowercased()
            let isMain = navigationAction.targetFrame?.isMainFrame != false

            if isBlockedScheme(scheme) {
                decisionHandler(.cancel)
                return
            }

            if trustedLoadInProgress, isMain {
                decisionHandler(.allow)
                return
            }

            // Block user navigations, window.open targets, and anything outside a trusted load.
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame, trustedLoadInProgress {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            endTrustedLoad()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            endTrustedLoad()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            endTrustedLoad()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Deny target=_blank / window.open.
            return nil
        }

        func webViewDidClose(_ webView: WKWebView) {}

        @available(macOS 10.15, *)
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        @available(macOS 10.15, *)
        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(false)
        }

        @available(macOS 10.15, *)
        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
