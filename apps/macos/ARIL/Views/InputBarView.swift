import SwiftUI

struct InputBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .help("Auto routes models. Manual keeps your pick (analysed, not swapped). Compare runs two models.")

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

                Spacer()
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

                TextField("Describe what you need.", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ARILTheme.bodyFont)
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onChange(of: state.draft) { _, _ in
                        state.schedulePreview()
                    }
                    .onSubmit {
                        state.send()
                    }

                Menu {
                    ForEach(AppState.modelCatalog, id: \.self) { model in
                        Button {
                            state.selectModel(model)
                        } label: {
                            HStack {
                                Text(model)
                                if model == state.defaultModel {
                                    Text("DEFAULT")
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                } label: {
                    Text(shortModel(state.selectedModel))
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(modelLabelColor)
                }
                .menuStyle(.borderlessButton)
                .help(modelHelp)

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
                        state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && state.pendingAttachments.isEmpty
                    )
                    .opacity(
                        state.draft.isEmpty && state.pendingAttachments.isEmpty ? 0.5 : 1
                    )
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

    private var modelLabelColor: Color {
        // Red = locked / not auto-optimised (Manual or explicit pick outside Auto).
        if state.routeMode == .manual {
            return theme.palette.danger
        }
        if state.selectedModel == state.defaultModel {
            return theme.palette.preferredHighlight
        }
        return theme.palette.textMuted
    }

    private var modelHelp: String {
        switch state.routeMode {
        case .auto:
            return "Auto-selected for detected category"
        case .manual:
            return "Manual mode — model is locked (shown in red) and will not be swapped by ARIL"
        case .compare:
            return "Compare mode — two models will be evaluated side by side"
        }
    }

    private func shortModel(_ id: String) -> String {
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        let mark = id == state.defaultModel ? " ★" : ""
        if state.routeMode == .auto, let cat = state.preview?.classification.primary, state.analysisStatus == .ready {
            return "\(leaf)\(mark) · \(cat.label)"
        }
        return "\(leaf)\(mark) · \(state.routeMode.label)"
    }
}
