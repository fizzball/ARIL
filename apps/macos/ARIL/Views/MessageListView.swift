import SwiftUI
import AppKit

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
                .id(messageFingerprint)
            }
            .onAppear { scrollToBottom(proxy: proxy, animated: false) }
            .onChange(of: state.selectedSessionID) { _, _ in
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: messageFingerprint) { _, _ in
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: state.isSending) { _, _ in
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: state.showIntelligencePanel) { _, _ in
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
                    // Same row as the ARIL caption so the ghost sits next to the label.
                    ARILGhostAvatar(
                        animated: isWaitingAssistant,
                        color: theme.palette.accent,
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
                AssistantMarkdownContent(
                    content: message.content.isEmpty && isStreamingAssistant ? "…" : message.content,
                    palette: theme.palette
                )
                .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders assistant text plus embedded markdown images (`![alt](url)`), including data URLs.
private struct AssistantMarkdownContent: View {
    let content: String
    let palette: ThemePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageContentParser.segments(from: content).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(text)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let urlString, let alt):
                    MarkdownImageView(urlString: urlString, alt: alt)
                }
            }
        }
    }
}

private enum MessageSegment {
    case text(String)
    case image(url: String, alt: String)
}

private enum MessageContentParser {
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#,
        options: []
    )

    static func segments(from content: String) -> [MessageSegment] {
        let ns = content as NSString
        let matches = imagePattern.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return content.isEmpty ? [] : [.text(content)]
        }

        var out: [MessageSegment] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    out.append(.text(before))
                }
            }
            let alt = ns.substring(with: match.range(at: 1))
            let url = ns.substring(with: match.range(at: 2))
            out.append(.image(url: url, alt: alt))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let after = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty {
                out.append(.text(after))
            }
        }
        return out
    }
}

private struct MarkdownImageView: View {
    let urlString: String
    let alt: String
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(alt.isEmpty ? "Generated image" : alt)
            } else {
                Text(alt.isEmpty ? "Loading image…" : alt)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: urlString) {
            nsImage = Self.loadImage(from: urlString)
        }
    }

    private static func loadImage(from urlString: String) -> NSImage? {
        if urlString.hasPrefix("data:"),
           let comma = urlString.firstIndex(of: ",") {
            let meta = urlString[..<comma]
            let payload = String(urlString[urlString.index(after: comma)...])
            guard meta.contains(";base64"),
                  let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                return nil
            }
            return NSImage(data: data)
        }
        guard let url = URL(string: urlString), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return NSImage(data: data)
    }
}
