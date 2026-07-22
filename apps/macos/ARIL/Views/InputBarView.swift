import SwiftUI
import AppKit

struct InputBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @FocusState private var focused: Bool
    @State private var localDraft = ""
    /// Bumped on programmatic draft changes so the multiline TextField remounts and
    /// remeasures height (SwiftUI often keeps a 1-line frame after send clears the field).
    @State private var fieldEpoch: UInt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.slashMenuVisible {
                slashCommandPalette
            }
            inputCard
        }
    }

    private var slashCommandPalette: some View {
        let commands = state.filteredSlashCommands
        let selected = min(max(state.slashMenuIndex, 0), max(commands.count - 1, 0))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { idx, cmd in
                Button {
                    state.slashMenuIndex = idx
                    state.executeSelectedSlash()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(cmd.id)
                            .font(ARILTheme.bodyFont)
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.palette.accent)
                        Text(cmd.summary)
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        idx == selected
                            ? theme.palette.accent.opacity(0.16)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if idx < commands.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        .background(theme.palette.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(theme.palette.colorScheme == .dark ? 0.35 : 0.10), radius: 12, y: 4)
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                HStack(spacing: 10) {
                    Picker("Mode", selection: Binding(
                        get: { state.routeMode },
                        set: { state.changeRouteMode(to: $0) }
                    )) {
                        ForEach(RouteMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    .help("Auto routes models. Manual keeps your pick (analysed, not swapped). Judge classifies the prompt and compares 3 models with the same capability.")

                    if let cat = state.preview?.classification.primary, state.analysisStatus == .ready {
                        Text(cat.label.uppercased())
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.accent)
                            .help("Detected prompt category")
                    }

                    Toggle(isOn: $state.webSearchEnabled) {
                        Text("Web")
                            .font(ARILTheme.captionFont)
                    }
                    .toggleStyle(.checkbox)
                    .help("Enable OpenRouter live web search for this send")

                    Spacer(minLength: 0)
                }

                Button {
                    state.requestScrollMessagesToBottom()
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.palette.accentStrong)
                            .frame(width: 28, height: 28)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.palette.background)
                    }
                }
                .buttonStyle(.plain)
                .help("Scroll to the latest message")
                .accessibilityLabel("Scroll to bottom")
            }

            if !state.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(state.pendingAttachments) { att in
                            HStack(spacing: 6) {
                                Image(systemName: att.isImage ? "photo" : "doc")
                                Text(att.filename)
                                    .lineLimit(1)
                                Text(att.displaySize)
                                    .foregroundStyle(theme.palette.textMuted)
                                Button {
                                    state.removeAttachment(att.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(theme.palette.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.palette.backgroundElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    state.attachFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Attach images or files")

                TextField("Describe what you need.", text: $localDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ARILTheme.bodyFont)
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .id(fieldEpoch)
                    .focused($focused)
                    .onAppear {
                        localDraft = state.draft
                    }
                    .onChange(of: localDraft) { _, value in
                        if value != state.draft {
                            state.updateDraftFromTyping(value)
                        }
                    }
                    .onChange(of: state.draftRevision) { _, _ in
                        if localDraft != state.draft {
                            localDraft = state.draft
                            fieldEpoch &+= 1
                            // Remount drops focus; restore so ↑/↓ history keeps working,
                            // then collapse any select-all to a caret at the end.
                            DispatchQueue.main.async {
                                focused = true
                                placeCaretAtEndOfDraft()
                                // AppKit often applies select-all after becomeFirstResponder —
                                // clear it again on the next turn.
                                DispatchQueue.main.async {
                                    placeCaretAtEndOfDraft()
                                }
                            }
                        }
                    }
                    .onKeyPress(.upArrow) {
                        if state.slashMenuVisible {
                            state.slashMenuMove(-1)
                            return .handled
                        }
                        // Shell-style history recall; leave multi-line editing alone.
                        guard !localDraft.contains("\n") else { return .ignored }
                        return state.recallPreviousPrompt() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        if state.slashMenuVisible {
                            state.slashMenuMove(1)
                            return .handled
                        }
                        guard !localDraft.contains("\n") else { return .ignored }
                        return state.recallNextPrompt() ? .handled : .ignored
                    }
                    .onKeyPress(.tab) {
                        if state.slashMenuVisible {
                            state.insertSelectedSlash()
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.escape) {
                        if state.slashMenuVisible {
                            state.dismissSlashMenu()
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        // Shift+Return inserts a line break; plain Return sends via onSubmit.
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        insertNewlineAtCursor()
                        return .handled
                    }
                    .onSubmit {
                        if state.slashMenuVisible {
                            state.executeSelectedSlash()
                        } else {
                            state.send()
                        }
                    }
                    .help("Return to send · Shift+Return for a new line")

                if state.isSending {
                    Button {
                        state.stopGeneration()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(theme.palette.danger)
                                .frame(width: 28, height: 28)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop generation")
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        state.send()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(theme.palette.accentStrong)
                                .frame(width: 28, height: 28)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.palette.background)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && state.pendingAttachments.isEmpty
                    )
                    .opacity(
                        localDraft.isEmpty && state.pendingAttachments.isEmpty ? 0.5 : 1
                    )
                    .help("Send")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.palette.inputFill)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(theme.palette.colorScheme == .dark ? 0.35 : 0.08), radius: 12, y: 4)
    }

    /// Insert `\n` at the field-editor caret when possible; otherwise append.
    private func insertNewlineAtCursor() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.isEditable,
           textView.window?.firstResponder === textView {
            let range = textView.selectedRange()
            if textView.shouldChangeText(in: range, replacementString: "\n") {
                textView.replaceCharacters(in: range, with: "\n")
                textView.didChangeText()
            }
            localDraft = textView.string
            if localDraft != state.draft {
                state.updateDraftFromTyping(localDraft)
            }
            return
        }
        localDraft.append("\n")
        if localDraft != state.draft {
            state.updateDraftFromTyping(localDraft)
        }
    }

    /// After history recall remounts the field, AppKit often selects all text —
    /// collapse to a caret at the end so the draft isn't "copy/paste selected".
    private func placeCaretAtEndOfDraft() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return }
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(NSRange(location: max(end - 1, 0), length: 0))
    }
}
