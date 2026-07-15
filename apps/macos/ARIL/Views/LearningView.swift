import SwiftUI

/// Learning panel filters for the unified SQLite browser.
private enum StoreBrowserFilter: String, CaseIterable, Identifiable {
    case activity
    case judgements
    case chat
    case analysis
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activity: return "Activity"
        case .judgements: return "Judgements"
        case .chat: return "Chat"
        case .analysis: return "Analysis"
        case .all: return "All"
        }
    }

    func includes(_ kind: String) -> Bool {
        switch self {
        case .activity:
            // Judgement + chat for a send — hide intermediate analysis-cache drafts.
            return kind == "judgement" || kind == "chat_transaction"
        case .judgements:
            return kind == "judgement"
        case .chat:
            return kind == "chat_transaction"
        case .analysis:
            return kind == "analysis_cache"
        case .all:
            return true
        }
    }
}

/// SQLite store browser + prompt classifications (toolbar Learning panel).
struct LearningView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var storeFilter: StoreBrowserFilter = .activity

    private var filteredRecords: [StoreRecordDTO] {
        state.storeRecords.filter { storeFilter.includes($0.kind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Learning", systemImage: "brain")
                    .font(ARILTheme.wordmarkFont)
                    .foregroundStyle(theme.palette.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(20)

            Divider().background(theme.palette.hairline)

            Form {
                Section("Local SQLite store") {
                    Text("A single send can create a judgement and a chat transaction. Analysis-cache rows appear while you type (preview) and are hidden under Activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let stats = state.storeStats {
                        LabeledContent("Retention limit") {
                            Stepper(value: Binding(
                                get: { stats.retention },
                                set: { newValue in
                                    Task { await state.updateStoreRetention(newValue) }
                                }
                            ), in: 1...1000) {
                                Text("\(stats.retention)")
                                    .monospacedDigit()
                            }
                        }
                        LabeledContent("Judgements") {
                            Text("\(stats.counts["classifications", default: 0])")
                        }
                        LabeledContent("Analysis cache") {
                            Text("\(stats.counts["analysis_cache", default: 0])")
                        }
                        LabeledContent("Chat transactions") {
                            Text("\(stats.counts["chat_transactions", default: 0])")
                        }
                        LabeledContent("Total records") {
                            Text("\(stats.total)")
                        }
                    } else {
                        Text("Store stats unavailable (gateway offline?).")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Refresh") {
                            Task { await state.loadStoreBrowser() }
                        }
                        Spacer()
                        Button("Delete all records", role: .destructive) {
                            Task { await state.deleteAllStoreRecords() }
                        }
                        .disabled(state.storeRecords.isEmpty)
                    }
                }

                Section("Stored records") {
                    Picker("Show", selection: $storeFilter) {
                        ForEach(StoreBrowserFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    if filteredRecords.isEmpty {
                        Text(state.storeRecords.isEmpty
                              ? "No SQLite records yet. Prefer a Compare result, save an Analysis override, or send a chat turn."
                              : "No records in this filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredRecords) { record in
                            StoreRecordRow(record: record)
                        }
                    }
                }

                Section("Prompt classifications") {
                    Text("Judgments from Compare Prefer, Analysis overrides, and first Auto send. Adjust category or accuracy, or remove an entry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if state.classifications.isEmpty {
                        Text("No classifications yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.classifications) { item in
                            ClassificationRow(item: item)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 720, height: 640)
        .background(theme.palette.backgroundElevated)
        .task {
            await state.loadStoreBrowser()
            await state.loadClassifications()
        }
    }
}

private struct StoreRecordRow: View {
    @EnvironmentObject private var state: AppState
    let record: StoreRecordDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.kindLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(record.promptSnippet.isEmpty ? "(no snippet)" : record.promptSnippet)
                    .lineLimit(2)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Remove", role: .destructive) {
                Task { await state.deleteStoreRecord(record.id) }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let model = record.model, !model.isEmpty { parts.append(model) }
        if let category = record.category, !category.isEmpty { parts.append(category) }
        if record.categoryOverridden == true { parts.append("override") }
        if record.cached == true { parts.append("cached") }
        if let cost = record.costUsd {
            parts.append(String(format: "$%.4f", cost))
        }
        if let created = record.createdAt, !created.isEmpty {
            parts.append(created)
        }
        return parts.joined(separator: " · ")
    }
}

private struct ClassificationRow: View {
    @EnvironmentObject private var state: AppState
    let item: ClassificationRecordDTO
    @State private var category: RouteCategory = .general
    @State private var accuracy: Double = 0.8
    @State private var hasAccuracy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.promptSnippet.isEmpty ? item.prompt : item.promptSnippet)
                .lineLimit(2)
            Text("\(item.model) · \(item.category)\(item.categoryOverridden ? " · override" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Category", selection: $category) {
                ForEach(RouteCategory.allCases) { cat in
                    Text(cat.label).tag(cat)
                }
            }

            Toggle("Accuracy set", isOn: $hasAccuracy)
            if hasAccuracy {
                HStack {
                    Text("\(Int(accuracy * 100))%")
                        .frame(width: 40)
                    Slider(value: $accuracy, in: 0...1, step: 0.05)
                }
            }

            HStack {
                Button("Save") {
                    Task {
                        await state.updateClassification(
                            item.id,
                            category: category,
                            accuracy: hasAccuracy ? accuracy : nil,
                            removeAccuracy: !hasAccuracy && item.accuracy != nil
                        )
                    }
                }
                Button("Remove", role: .destructive) {
                    Task { await state.deleteClassification(item.id) }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            category = RouteCategory(rawValue: item.category) ?? .general
            if let acc = item.accuracy {
                hasAccuracy = true
                accuracy = acc
            }
        }
    }
}
