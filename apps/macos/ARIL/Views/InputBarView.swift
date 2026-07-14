import SwiftUI

struct InputBarView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Describe what you need.", text: $state.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ARILTheme.bodyFont)
                .foregroundStyle(ARILTheme.cream)
                .lineLimit(1...6)
                .focused($focused)
                .onChange(of: state.draft) { _, _ in
                    state.schedulePreview()
                }
                .onSubmit {
                    Task { await state.send() }
                }

            Menu {
                ForEach(["openai/gpt-4.1", "openai/gpt-4.1-mini", "anthropic/claude-sonnet-4", "anthropic/claude-opus-4", "ollama/llama3.2"], id: \.self) { model in
                    Button(model) {
                        state.selectedModel = model
                        state.routeMode = .manual
                    }
                }
            } label: {
                Text(shortModel(state.selectedModel))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(ARILTheme.creamMuted)
            }
            .menuStyle(.borderlessButton)

            Button {
                Task { await state.runPreview() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(ARILTheme.creamMuted)
            }
            .buttonStyle(.plain)
            .help("Refresh intelligence preview")

            Button {
                Task { await state.send() }
            } label: {
                ZStack {
                    Circle()
                        .fill(ARILTheme.goldStrong)
                        .frame(width: 28, height: 28)
                    Image(systemName: state.isSending ? "hourglass" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ARILTheme.background)
                }
            }
            .buttonStyle(.plain)
            .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isSending)
            .opacity(state.draft.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ARILTheme.inputFill)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ARILTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private func shortModel(_ id: String) -> String {
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        return "\(leaf) · \(state.routeMode.label)"
    }
}
