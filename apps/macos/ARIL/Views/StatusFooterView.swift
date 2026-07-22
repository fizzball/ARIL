import SwiftUI
import AppKit

struct StatusFooterView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @State private var showModelBrowser = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(state.gatewayReady ? theme.palette.accent : theme.palette.danger)
                .frame(width: 6, height: 6)
            Text(state.gatewayStatus)
                .font(ARILTheme.captionFont)
                .foregroundStyle(
                    state.gatewayReady ? theme.palette.textMuted : theme.palette.danger
                )

            Circle()
                .fill(state.databaseReady ? theme.palette.accent : theme.palette.danger)
                .frame(width: 6, height: 6)
            Text(state.databaseStatus)
                .font(ARILTheme.captionFont)
                .foregroundStyle(
                    state.databaseReady ? theme.palette.textMuted : theme.palette.danger
                )
                .help(state.databasePath.isEmpty ? state.databaseDetail : state.databasePath)

            Circle()
                .fill(state.openRouterReady ? theme.palette.accent : theme.palette.danger)
                .frame(width: 6, height: 6)
            Text(state.openRouterStatus)
                .font(ARILTheme.captionFont)
                .foregroundStyle(
                    state.openRouterReady ? theme.palette.textMuted : theme.palette.danger
                )
                .help({
                    var parts: [String] = []
                    if let msg = state.openRouterCheckMessage, !msg.isEmpty {
                        parts.append(msg)
                    }
                    if let credits = state.openRouterCreditsRemaining {
                        parts.append(String(format: "Credits $%.2f", credits))
                    }
                    if !state.openRouterMaskedKey.isEmpty {
                        parts.append(state.openRouterMaskedKey)
                    }
                    return parts.isEmpty ? "OpenRouter" : parts.joined(separator: " · ")
                }())

            Circle()
                .fill(sessionCacheColor)
                .frame(width: 6, height: 6)
            Text("Cache Size \(state.sessionCacheLabel)")
                .font(ARILTheme.captionFont)
                .foregroundStyle(sessionCacheColor)
                .help(sessionCacheHelp)

            if state.lastCacheLabel == "cached" || state.lastCacheLabel == "not cached" {
                Text(state.lastCacheLabel)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(
                        state.lastCacheLabel == "cached"
                            ? theme.palette.accent
                            : theme.palette.textMuted
                    )
            }

            if state.generationPhase != .idle {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("\(state.generationPhase.label) · \(elapsedLabel)")
                        .font(ARILTheme.captionFont)
                        .foregroundStyle(theme.palette.accent)
                        .monospacedDigit()
                }
            } else if let err = state.lastError {
                Text(err)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.danger)
                    .lineLimit(1)
            } else if let guardMsg = state.localGuardrailStatusMessage {
                Text(guardMsg)
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.preferredHighlight)
                    .lineLimit(1)
            } else if let latency = state.lastLatencyMs {
                Text("last \(latency)ms")
                    .font(ARILTheme.captionFont)
                    .foregroundStyle(theme.palette.textMuted.opacity(0.8))
            }

            Spacer(minLength: 8)

            modelPicker

            Text(state.routeMode.label)
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted)
            Text("# v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.28")")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.textMuted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(theme.palette.sidebar.opacity(0.9))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.palette.hairline)
                .frame(height: 1)
        }
        .sheet(isPresented: $showModelBrowser) {
            OpenRouterModelBrowserView(title: "Choose OpenRouter model") { modelID in
                state.selectModelFromCatalog(modelID)
            }
            .environmentObject(state)
            .environmentObject(theme)
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(state.modelCatalog, id: \.self) { model in
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
            Divider()
            Button("Other…") {
                showModelBrowser = true
            }
        } label: {
            Text(shortModel(state.selectedModel))
                .font(ARILTheme.captionFont)
                .foregroundStyle(modelLabelColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help(modelHelp)
    }

    private var modelLabelColor: Color {
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
            return "Manual mode — model is locked (shown in red). Use Other… to browse the full OpenRouter catalog."
        case .compare:
            return "Judge mode — three models are evaluated side by side"
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

    private var elapsedLabel: String {
        let ms = state.generationElapsedMs
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private var sessionCacheColor: Color {
        switch state.sessionCacheHealth {
        case .healthy:
            return theme.palette.textMuted
        case .ok:
            return theme.palette.preferredHighlight
        case .warn:
            return theme.palette.danger
        }
    }

    private var sessionCacheHelp: String {
        switch state.sessionCacheHealth {
        case .healthy:
            return "Local session cache is a healthy size (\(state.sessionCacheLabel))."
        case .ok:
            return "Local session cache is growing (\(state.sessionCacheLabel)). Compact from Preferences if typing feels slow."
        case .warn:
            return "Local session cache is large (\(state.sessionCacheLabel)). Compact or clear it from Preferences to restore responsiveness."
        }
    }
}
