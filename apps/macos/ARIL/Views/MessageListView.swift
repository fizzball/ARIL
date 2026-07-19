import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MessageListView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore

    private let bottomAnchorID = "aril.message.bottom"

    private var messages: [ChatMessage] {
        guard let id = state.selectedSessionID,
              let session = state.sessions.first(where: { $0.id == id }) else {
            return []
        }
        return session.messages
    }

    private var messageFingerprint: String {
        let last = messages.last
        return "\(messages.count)|\(last?.id.uuidString ?? "")|\(last?.content.count ?? 0)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager VStack — LazyVStack was dropping older bubbles after reloads.
                // Do NOT bind `.id` to content length: that recreates the whole list on
                // every stream token and makes replies look like they arrive in one shot.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(28)
            }
            .onAppear { scrollToBottom(proxy: proxy, animated: false) }
            .onChange(of: state.selectedSessionID) { _, _ in
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: messageFingerprint) { _, _ in
                // While streaming, jump without animation so token paint stays responsive.
                scrollToBottom(proxy: proxy, animated: !state.isSending)
            }
            .onChange(of: state.isSending) { _, _ in
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: state.showIntelligencePanel) { _, _ in
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: state.scrollMessagesToBottomToken) { _, _ in
                scrollToBottom(proxy: proxy, animated: true)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    let message: ChatMessage
    @State private var copied = false
    @State private var hoveringUser = false

    /// Waiting for or receiving the live agent reply for this bubble.
    private var isWaitingAssistant: Bool {
        message.role == .assistant
            && state.isSending
            && state.selectedSession?.messages.last?.id == message.id
    }

    private var isStreamingAssistant: Bool {
        isWaitingAssistant && state.generationPhase == .streaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if message.role == .assistant {
                    // Same row as the ARIL caption; spins while waiting for the reply.
                    ARILLogoAvatar(
                        animated: isWaitingAssistant,
                        color: ARILLogoPalette.gold,
                        size: 18
                    )
                }

                Text(message.role == .user ? state.userLabel : "ARIL")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)

                Spacer(minLength: 0)

                if message.role == .assistant, !message.content.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Copy response to clipboard")
                }
            }

            if message.role == .user {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.content)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        state.reusePrompt(message.content)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.palette.accent)
                    }
                    .buttonStyle(.plain)
                    .opacity(hoveringUser ? 1 : 0)
                    .allowsHitTesting(hoveringUser)
                    .help("Reuse this prompt in the entry field")
                    .accessibilityLabel("Reuse prompt")

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    state.reusePrompt(message.content)
                }
                .onHover { hoveringUser = $0 }
                .help("Click or use ↓ to reuse this prompt")
            } else {
                // Show a visible placeholder for the whole wait (thinking + streaming),
                // not only after the first token — MCP tool rounds can take a while.
                let body: String = {
                    if !message.bodyWithoutCostFooter.isEmpty {
                        return message.bodyWithoutCostFooter
                    }
                    if isWaitingAssistant {
                        return state.generationPhase == .streaming ? "…" : "Thinking…"
                    }
                    return ""
                }()
                VStack(alignment: .leading, spacing: 8) {
                    if !body.isEmpty {
                        AssistantMarkdownContent(
                            content: body,
                            textColor: theme.palette.assistantText,
                            streaming: isWaitingAssistant
                        )
                    }
                    if let costLabel = message.costFooterLabel {
                        Text(costLabel)
                            .font(ARILTheme.captionFont.weight(.semibold))
                            .foregroundStyle(theme.palette.costFooter)
                            .textSelection(.enabled)
                            .monospacedDigit()
                    }
                }
                .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownImageView: View {
    @EnvironmentObject private var theme: ThemeStore
    let urlString: String
    let alt: String

    @State private var nsImage: NSImage?
    @State private var imageData: Data?
    @State private var fileExtension = "png"
    @State private var copied = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel(alt.isEmpty ? "Generated image" : alt)
                        .contextMenu {
                            Button("Copy Image") { copyImage() }
                            Button("Save Image…") { saveImage() }
                        }
                } else {
                    Text(alt.isEmpty ? "Loading image…" : alt)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
            }

            if nsImage != nil {
                HStack(spacing: 12) {
                    Button {
                        copyImage()
                    } label: {
                        Label(copied ? "Copied" : "Copy image", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Copy image to clipboard")
                    .disabled(imageData == nil && nsImage == nil)

                    Button {
                        saveImage()
                    } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Save image to a file")
                    .disabled(imageData == nil && nsImage == nil)

                    if let saveError {
                        Text(saveError)
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.danger)
                            .lineLimit(1)
                    }
                }
            }
        }
        .task(id: urlString) {
            let loaded = Self.loadImage(from: urlString)
            nsImage = loaded.image
            imageData = loaded.data
            fileExtension = loaded.fileExtension
            copied = false
            saveError = nil
        }
    }

    private func copyImage() {
        guard let nsImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Prefer PNG bytes when available so other apps get a clean raster.
        if let imageData, !imageData.isEmpty {
            pb.setData(imageData, forType: .png)
        }
        pb.writeObjects([nsImage])
        copied = true
        saveError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }

    private func saveImage() {
        guard let data = exportData() else {
            saveError = "Could not export image"
            return
        }
        saveError = nil

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = Self.contentTypes(for: fileExtension)
        let base = Self.suggestedFilename(alt: alt, fileExtension: fileExtension)
        panel.nameFieldStringValue = base
        panel.title = "Save Image"
        panel.message = "Choose where to save the generated image."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            saveError = "Save failed"
        }
    }

    private func exportData() -> Data? {
        if let imageData, !imageData.isEmpty {
            return imageData
        }
        guard let nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    private static func suggestedFilename(alt: String, fileExtension: String) -> String {
        let cleaned = alt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^\w\-. ]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        let stem = cleaned.isEmpty ? "aril-image" : String(cleaned.prefix(48))
        return "\(stem).\(fileExtension)"
    }

    private static func contentTypes(for fileExtension: String) -> [UTType] {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return [.jpeg]
        case "gif": return [.gif]
        case "webp": return [.webP]
        case "heic": return [.heic]
        default: return [.png]
        }
    }

    private static func loadImage(from urlString: String) -> (image: NSImage?, data: Data?, fileExtension: String) {
        if urlString.hasPrefix("data:"),
           let comma = urlString.firstIndex(of: ",") {
            let meta = String(urlString[..<comma]).lowercased()
            let payload = String(urlString[urlString.index(after: comma)...])
            guard meta.contains(";base64"),
                  let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                return (nil, nil, "png")
            }
            let ext = mimeExtension(from: meta)
            return (NSImage(data: data), data, ext)
        }
        guard let url = URL(string: urlString), let data = try? Data(contentsOf: url) else {
            return (nil, nil, "png")
        }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        return (NSImage(data: data), data, ext)
    }

    private static func mimeExtension(from dataURLMeta: String) -> String {
        if dataURLMeta.contains("image/jpeg") || dataURLMeta.contains("image/jpg") { return "jpg" }
        if dataURLMeta.contains("image/gif") { return "gif" }
        if dataURLMeta.contains("image/webp") { return "webp" }
        if dataURLMeta.contains("image/heic") { return "heic" }
        return "png"
    }
}

