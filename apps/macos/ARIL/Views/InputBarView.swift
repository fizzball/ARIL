import SwiftUI

struct InputBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $state.routeMode) {
                    ForEach(RouteMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Text(state.lastCacheLabel.uppercased())
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(
                        state.lastCacheLabel == "cached"
                            ? theme.palette.accent
                            : theme.palette.textMuted
                    )

                Spacer()
            }

            HStack(alignment: .bottom, spacing: 10) {
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
                        .foregroundStyle(
                            state.selectedModel == state.defaultModel
                                ? theme.palette.preferredHighlight
                                : theme.palette.textMuted
                        )
                }
                .menuStyle(.borderlessButton)
                .help(state.selectedModel == state.defaultModel ? "Default model" : "Selected model")

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
                    .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(state.draft.isEmpty ? 0.5 : 1)
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

    private func shortModel(_ id: String) -> String {
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        let mark = id == state.defaultModel ? " ★" : ""
        return "\(leaf)\(mark) · \(state.routeMode.label)"
    }
}
