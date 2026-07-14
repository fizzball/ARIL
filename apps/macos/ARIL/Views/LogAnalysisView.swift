import SwiftUI
import AppKit

struct LogAnalysisView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAll = false

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Log analysis", systemImage: "doc.text.magnifyingglass")
                    .font(ARILTheme.wordmarkFont)
                    .foregroundStyle(theme.palette.text)
                Spacer()
                if !state.exchangeLog.isEmpty {
                    Button {
                        copyToPasteboard(Self.formatLog(entries: state.exchangeLog, formatter: Self.timestampFormatter))
                        copiedAll = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedAll = false
                        }
                    } label: {
                        Label(copiedAll ? "Copied" : "Copy all", systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy all logged exchanges to the clipboard")
                    Button("Clear") {
                        state.clearExchangeLog()
                    }
                    .help("Clear the in-memory exchange log")
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Text("Last \(AppState.maxExchangeLogCapacity) message sends and agent responses (newest first). Stored in memory for this session only.")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider().background(theme.palette.hairline)

            if state.exchangeLog.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.palette.textMuted)
                    Text("No exchanges logged yet.")
                        .font(ARILTheme.bodyFont)
                        .foregroundStyle(theme.palette.textMuted)
                    Text("Send a prompt to start collecting the last 20 turns.")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.textMuted.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(state.exchangeLog) { entry in
                            ExchangeLogRow(entry: entry, formatter: Self.timestampFormatter)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 640, height: 560)
        .background(theme.palette.backgroundElevated)
    }

    static func formatLog(entries: [ExchangeLogEntry], formatter: DateFormatter) -> String {
        entries.map { formatEntry($0, formatter: formatter) }.joined(separator: "\n\n==========\n\n")
    }

    static func formatEntry(_ entry: ExchangeLogEntry, formatter: DateFormatter) -> String {
        var lines: [String] = [
            "Time: \(formatter.string(from: entry.timestamp))",
            "Status: \(entry.status.rawValue)",
            "Mode: \(entry.mode)",
            "Model: \(entry.model)",
        ]
        if let ms = entry.latencyMs {
            lines.append("Latency: \(ms)ms")
        }
        lines.append("")
        lines.append("SEND")
        lines.append(entry.prompt)
        lines.append("")
        if let err = entry.errorMessage, !err.isEmpty {
            lines.append("ERROR")
            lines.append(err)
        } else {
            lines.append("AGENT")
            lines.append(entry.response.isEmpty ? "(empty)" : entry.response)
        }
        return lines.joined(separator: "\n")
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct ExchangeLogRow: View {
    @EnvironmentObject private var theme: ThemeStore
    let entry: ExchangeLogEntry
    let formatter: DateFormatter
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatter.string(from: entry.timestamp))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                    .monospacedDigit()
                Text(entry.status.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusColor)
                Text(entry.mode)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.accent)
                Text(shortModel(entry.model))
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                Spacer()
                if let ms = entry.latencyMs {
                    Text("\(ms)ms")
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
                .help("Copy this exchange to the clipboard")
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse" : "Expand full exchange")
            }

            labeledBlock(title: "Send", text: entry.prompt, lineLimit: expanded ? nil : 3)

            if let err = entry.errorMessage, !err.isEmpty {
                labeledBlock(title: "Error", text: err, lineLimit: expanded ? nil : 2)
            } else {
                labeledBlock(
                    title: "Agent",
                    text: entry.response.isEmpty ? "(empty)" : entry.response,
                    lineLimit: expanded ? nil : 4
                )
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

    private var statusColor: Color {
        switch entry.status {
        case .completed: return theme.palette.accent
        case .compare: return theme.palette.preferredHighlight
        case .cancelled: return theme.palette.textMuted
        case .error: return theme.palette.danger
        }
    }

    @ViewBuilder
    private func labeledBlock(title: String, text: String, lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.palette.accent)
            Text(text)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.text)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shortModel(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
