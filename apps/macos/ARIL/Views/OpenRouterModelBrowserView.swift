import SwiftUI

/// Searchable OpenRouter catalog used by Manual mode and Preferences → Models “Other…”.
struct OpenRouterModelBrowserView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let title: String
    /// When opened from a Preferences category row, pre-select that filter.
    var initialCategory: RouteCategory? = nil
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var selectedID: String?
    @State private var categoryFilter: RouteCategory?
    /// Callout panel for OpenRouter top-weekly popularity rankings.
    @State private var showWeeklyRankings = false

    private var filtered: [OpenRouterCatalogModelDTO] {
        var rows = state.openRouterCatalog

        if let categoryFilter {
            rows = rows.filter { Self.matches($0, category: categoryFilter, profile: state.routingProfile) }
            rows = Self.prioritize(rows, for: categoryFilter, profile: state.routingProfile)
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.id.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q)
        }
    }

    private var emptyFilterMessage: String {
        if state.openRouterCatalog.isEmpty {
            return "No models in the catalog yet. Refresh to load from OpenRouter."
        }
        if categoryFilter == .vision {
            return "No Vision models match this filter. Try All, or refresh the catalog."
        }
        if let categoryFilter {
            return "No \(categoryFilter.label) models match this filter. Try All or adjust search."
        }
        return "No models match this search."
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

            categoryFilterBar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            HStack(spacing: 10) {
                Text("\(filtered.count) models")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                if let categoryFilter {
                    Text("· \(categoryFilter.label)")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)
                }
                Spacer()
                Button {
                    showWeeklyRankings.toggle()
                    if showWeeklyRankings, state.openRouterWeeklyRankings.isEmpty {
                        Task { await state.refreshWeeklyRankings(forceRefresh: true) }
                    }
                } label: {
                    Label(
                        showWeeklyRankings ? "Hide rankings" : "Weekly popular",
                        systemImage: "chart.bar.fill"
                    )
                    .font(ARILTheme.captionFont.weight(.semibold))
                    .foregroundStyle(showWeeklyRankings ? theme.palette.background : theme.palette.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(showWeeklyRankings ? theme.palette.accentStrong : theme.palette.inputFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Show OpenRouter’s top models by tokens processed this week")

                if state.isLoadingOpenRouterCatalog || state.isLoadingWeeklyRankings {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task {
                        await state.refreshOpenRouterCatalog(query: query, forceRefresh: true)
                        if showWeeklyRankings {
                            await state.refreshWeeklyRankings(forceRefresh: true)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh catalog from OpenRouter")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if showWeeklyRankings {
                weeklyRankingsCallout
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            if let err = state.openRouterCatalogError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if filtered.isEmpty, !state.isLoadingOpenRouterCatalog {
                VStack(spacing: 10) {
                    Spacer(minLength: 40)
                    Image(systemName: categoryFilter == .vision ? "eye.slash" : "magnifyingglass")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(theme.palette.textMuted)
                    Text(emptyFilterMessage)
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                .id(categoryFilter?.rawValue ?? "all")
            }

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
        .frame(width: 720, height: 560)
        .background(theme.palette.backgroundElevated)
        .onAppear {
            categoryFilter = initialCategory
        }
        .task {
            if state.openRouterCatalog.isEmpty {
                await state.refreshOpenRouterCatalog(forceRefresh: true)
            }
        }
    }

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", selected: categoryFilter == nil) {
                    categoryFilter = nil
                    selectedID = nil
                }
                ForEach(RouteCategory.allCases) { category in
                    filterChip(label: category.label, selected: categoryFilter == category) {
                        categoryFilter = category
                        selectedID = nil
                    }
                    .help(category.blurb)
                }
            }
        }
    }

    private var weeklyRankingsCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Weekly popular on OpenRouter", systemImage: "flame.fill")
                    .font(ARILTheme.captionFont.weight(.semibold))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                Text("Tokens this week · tap to select")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
            }

            if let err = state.weeklyRankingsError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
            } else if state.isLoadingWeeklyRankings, state.openRouterWeeklyRankings.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading rankings…")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted)
                }
                .padding(.vertical, 8)
            } else if state.openRouterWeeklyRankings.isEmpty {
                Text("No weekly rankings available. Refresh and try again.")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.openRouterWeeklyRankings) { row in
                            Button {
                                selectedID = row.id
                            } label: {
                                HStack(spacing: 10) {
                                    Text("#\(row.rank)")
                                        .font(ARILTheme.captionFont.weight(.semibold))
                                        .foregroundStyle(theme.palette.accent)
                                        .monospacedDigit()
                                        .frame(width: 36, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.id)
                                            .font(ARILTheme.captionFont.weight(.medium))
                                            .foregroundStyle(theme.palette.text)
                                            .lineLimit(1)
                                        if row.name != row.id {
                                            Text(row.name)
                                                .font(ARILTheme.captionFont)
                                                .foregroundStyle(theme.palette.textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if let pricing = row.pricingLabel {
                                        Text(pricing)
                                            .font(ARILTheme.captionFont)
                                            .foregroundStyle(theme.palette.accent)
                                            .monospacedDigit()
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    selectedID == row.id
                                        ? theme.palette.accent.opacity(0.14)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(12)
        .background(theme.palette.inputFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.palette.hairline, lineWidth: 1)
        )
    }

    private func filterChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(ARILTheme.captionFont.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.palette.background : theme.palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? theme.palette.accentStrong : theme.palette.inputFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.palette.hairline, lineWidth: selected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category matching

    private static func matches(
        _ model: OpenRouterCatalogModelDTO,
        category: RouteCategory,
        profile: RoutingProfile
    ) -> Bool {
        if isRecommended(model.id, for: category, profile: profile) {
            return true
        }

        let hay = "\(model.id) \(model.name)".lowercased()
        switch category {
        case .coding:
            return containsAny(hay, [
                "code", "coder", "coding", "codestral", "devstral", "deepseek",
                "qwen", "starcoder", "codellama", "wizardcoder", "programmer",
            ])
        case .security:
            return containsAny(hay, [
                "security", "secure", "cyber", "claude", "gpt-4", "opus", "sonnet",
            ])
        case .reasoning:
            return containsAny(hay, [
                "reason", "o1", "o3", "o4", "r1", "opus", "think", "deepseek-r",
                "qwq", "pro",
            ])
        case .vision:
            // Prefer catalog modalities when present; fall back to name heuristics.
            if let accepts = model.acceptsImageInput {
                return accepts
            }
            return containsAny(hay, [
                "vision", "image", "vl-", "-vl", "multimodal", "gemini", "gpt-4o",
                "llava", "pixtral", "qwen2.5-vl", "qwen-vl",
            ])
        case .cost:
            return model.promptPer1k <= 0.001
                || containsAny(hay, ["mini", "nano", "lite", "flash", "haiku", "small", "3b", "7b", "8b"])
        case .performance:
            return containsAny(hay, [
                "flash", "mini", "turbo", "haiku", "fast", "lite", "nano", "instant",
            ])
        case .confidence:
            return containsAny(hay, [
                "opus", "gpt-4.1", "gpt-4o", "sonnet-4", "405b", "large", "pro", "o1", "o3",
            ]) && !containsAny(hay, ["mini", "nano", "lite", "haiku", "tiny"])
        case .general:
            return containsAny(hay, [
                "instruct", "chat", "llama", "gpt", "claude", "gemini", "mistral", "qwen",
            ])
        }
    }

    private static func prioritize(
        _ rows: [OpenRouterCatalogModelDTO],
        for category: RouteCategory,
        profile: RoutingProfile
    ) -> [OpenRouterCatalogModelDTO] {
        let recommended = Set(
            (RoutingProfile.recommendations[category] ?? []) + [profile.model(for: category)]
        )
        return rows.sorted { a, b in
            let aRec = recommended.contains(where: { idsMatch(a.id, $0) })
            let bRec = recommended.contains(where: { idsMatch(b.id, $0) })
            if aRec != bRec { return aRec && !bRec }
            if category == .cost, a.promptPer1k != b.promptPer1k {
                return a.promptPer1k < b.promptPer1k
            }
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        }
    }

    private static func isRecommended(
        _ modelID: String,
        for category: RouteCategory,
        profile: RoutingProfile
    ) -> Bool {
        let ids = (RoutingProfile.recommendations[category] ?? []) + [profile.model(for: category)]
        return ids.contains(where: { idsMatch(modelID, $0) })
    }

    private static func idsMatch(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func containsAny(_ hay: String, _ needles: [String]) -> Bool {
        needles.contains { hay.contains($0) }
    }
}
