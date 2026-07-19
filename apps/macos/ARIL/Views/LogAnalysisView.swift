import SwiftUI
import AppKit

struct LogAnalysisView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @State private var copiedAll = false
    @State private var isLoading = false

    private static let maxRows = 25

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private var rows: [StoreRecordDTO] {
        Array(
            state.storeRecords
                .filter { $0.kind == "chat_transaction" }
                .prefix(Self.maxRows)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log analysis")
                    .font(ARILTheme.bodyFont.weight(.semibold))
                    .foregroundStyle(theme.palette.text)
                Spacer()
                if !rows.isEmpty {
                    Button {
                        copyToPasteboard(Self.formatLog(entries: rows, formatter: Self.timestampFormatter))
                        copiedAll = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedAll = false
                        }
                    } label: {
                        Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.palette.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Copy OpenRouter transactions to the clipboard")
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Reload the latest OpenRouter transactions")
                Button {
                    state.closeToolPanel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .padding(16)

            Text("Last \(Self.maxRows) OpenRouter API transactions (newest first). Tokens and cost come from OpenRouter usage metadata stored by the local gateway.")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider().background(theme.palette.hairline)

            if isLoading && rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.palette.textMuted)
                    Text("No OpenRouter transactions yet.")
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.textMuted)
                    Text("Send a prompt with OpenRouter connected to start collecting the last \(Self.maxRows) calls.")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { entry in
                            OpenRouterTransactionRow(entry: entry, formatter: Self.timestampFormatter)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.backgroundElevated)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await state.loadStoreBrowser()
    }

    static func formatLog(entries: [StoreRecordDTO], formatter: DateFormatter) -> String {
        entries.map { formatEntry($0, formatter: formatter) }.joined(separator: "\n\n==========\n\n")
    }

    static func formatEntry(_ entry: StoreRecordDTO, formatter: DateFormatter) -> String {
        var lines: [String] = [
            "Time: \(displayTime(entry.createdAt, formatter: formatter))",
            "Model: \(entry.model ?? "—")",
            "Category: \(entry.category ?? "—")",
        ]
        if let inn = entry.inputTokens, let out = entry.outputTokens {
            lines.append("Tokens: \(inn) in / \(out) out")
        } else if let inn = entry.inputTokens {
            lines.append("Tokens: \(inn) in")
        } else if let out = entry.outputTokens {
            lines.append("Tokens: \(out) out")
        }
        if let cost = entry.costUsd {
            lines.append(String(format: "Cost: $%.4f", cost))
        }
        if entry.cached == true {
            lines.append("Cached: yes")
        }
        if let sid = entry.sessionId, !sid.isEmpty {
            lines.append("Session: \(sid)")
        }
        lines.append("")
        lines.append("PROMPT")
        lines.append(entry.promptSnippet.isEmpty ? "(empty)" : entry.promptSnippet)
        return lines.joined(separator: "\n")
    }

    static func displayTime(_ raw: String?, formatter: DateFormatter) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
            return formatter.string(from: date)
        }
        return raw
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct OpenRouterTransactionRow: View {
    @EnvironmentObject private var theme: ThemeStore
    let entry: StoreRecordDTO
    let formatter: DateFormatter
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LogAnalysisView.displayTime(entry.createdAt, formatter: formatter))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                    .monospacedDigit()
                Text("OPENROUTER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.palette.accent)
                if let category = entry.category, !category.isEmpty {
                    Text(category)
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.preferredHighlight)
                }
                Text(shortModel(entry.model ?? ""))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                Spacer()
                if let inn = entry.inputTokens, let out = entry.outputTokens {
                    Text("\(inn)/\(out)")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted.opacity(0.8))
                        .monospacedDigit()
                        .help("Input / output tokens")
                }
                if let cost = entry.costUsd {
                    Text(String(format: "$%.4f", cost))
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted.opacity(0.8))
                        .monospacedDigit()
                }
                Button {
                    copyToPasteboard(LogAnalysisView.formatEntry(entry, formatter: formatter))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Copy this transaction")
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
            }

            Text(entry.promptSnippet.isEmpty ? "(empty prompt)" : entry.promptSnippet)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.text)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if expanded {
                HStack(spacing: 12) {
                    if let sid = entry.sessionId, !sid.isEmpty {
                        metaChip("Session", String(sid.prefix(8)))
                    }
                    if entry.cached == true {
                        metaChip("Cached", "yes")
                    }
                    metaChip("ID", String(entry.id.prefix(8)))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.background)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metaChip(_ title: String, _ value: String) -> some View {
        Text("\(title): \(value)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.palette.textMuted)
    }

    private func shortModel(_ id: String) -> String {
        guard !id.isEmpty else { return "—" }
        return id.split(separator: "/").last.map(String.init) ?? id
    }
}
