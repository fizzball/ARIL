import SwiftUI

/// Searchable OpenRouter catalog used by Preferences → Models “Other…”.
struct OpenRouterModelBrowserView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var selectedID: String?

    private var filtered: [OpenRouterCatalogModelDTO] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return state.openRouterCatalog }
        return state.openRouterCatalog.filter {
            $0.id.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(ARILTheme.bodyFont.weight(.semibold))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            TextField("Search OpenRouter models…", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
                .background(theme.palette.inputFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            HStack {
                Text("\(filtered.count) models")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                Spacer()
                if state.isLoadingOpenRouterCatalog {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await state.refreshOpenRouterCatalog(query: query, forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh catalog from OpenRouter")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let err = state.openRouterCatalogError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            List(filtered, selection: $selectedID) { model in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.id)
                            .font(ARILTheme.bodyFont)
                            .foregroundStyle(theme.palette.text)
                            .lineLimit(1)
                        if model.name != model.id {
                            Text(model.name)
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(theme.palette.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(model.pricingLabel)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)
                        .monospacedDigit()
                }
                .tag(model.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedID = model.id
                }
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Select") {
                    guard let selectedID else { return }
                    onSelect(selectedID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
                .buttonStyle(.borderedProminent)
                .tint(theme.palette.accentStrong)
            }
            .padding(16)
        }
        .frame(width: 640, height: 520)
        .background(theme.palette.backgroundElevated)
        .task {
            if state.openRouterCatalog.isEmpty {
                await state.refreshOpenRouterCatalog(forceRefresh: true)
            }
        }
    }
}
