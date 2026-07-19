import SwiftUI
import AppKit

/// Compact “ARIL” mark for the window title bar. Click opens About. Every ~60s it
/// crossfades into a random resting style (colour / typeface / tracking), with a short flourish.
struct ARILTitleWordmarkView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var look = TitleLook.resting
    @State private var opacity: Double = 1
    @State private var scale: CGFloat = 1
    @State private var glow: Double = 0
    @State private var shimmer: CGFloat = -1.2
    @State private var sparklePhase: Double = 0
    @State private var showSparkles = false
    @State private var letterOffsets: [CGFloat] = Array(repeating: 0, count: 4)
    @State private var activeFlourish: FlourishKind = .crossfade

    private let letters = Array("ARIL")
    private let cycleSeconds: UInt64 = 60

    var body: some View {
        Button {
            state.openToolPanel(.about)
        } label: {
            ZStack {
                wordmark
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .shadow(color: look.resolvedColor(theme.palette).opacity(glow), radius: glow > 0 ? 6 : 0)

                if showSparkles {
                    sparkleLayer
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 52, minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHelpBubble("About ARIL", detail: "Version, changelog, and credits")
        .accessibilityAddTraits(.isButton)
        .task { await runCycle() }
        .onAppear {
            look = .resting
        }
    }

    private var wordmark: some View {
        HStack(spacing: look.tracking) {
            ForEach(Array(letters.enumerated()), id: \.offset) { index, ch in
                Text(String(ch))
                    .font(look.font)
                    .foregroundStyle(foreground(for: index))
                    .offset(y: letterOffsets.indices.contains(index) ? letterOffsets[index] : 0)
            }
        }
        .overlay {
            if activeFlourish == .shimmer {
                LinearGradient(
                    colors: [
                        .clear,
                        theme.palette.text.opacity(0.55),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 28)
                .offset(x: shimmer * 40)
                .blendMode(.plusLighter)
                .mask(
                    HStack(spacing: look.tracking) {
                        ForEach(Array(letters.enumerated()), id: \.offset) { _, ch in
                            Text(String(ch)).font(look.font)
                        }
                    }
                )
            }
        }
    }

    private var sparkleLayer: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !showSparkles)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: i % 2 == 0 ? "sparkle" : "sparkles")
                        .font(.system(size: i == 2 ? 8 : 6, weight: .semibold))
                        .foregroundStyle(theme.palette.accentStrong.opacity(0.55 + 0.25 * sin(t * 4 + Double(i))))
                        .offset(
                            x: [-18, 16, 0, -10, 12][i] + CGFloat(sin(t * 2.2 + Double(i)) * 2),
                            y: [-6, -8, -12, 4, 2][i] + CGFloat(cos(t * 2.6 + Double(i)) * 1.5)
                        )
                        .opacity(0.35 + 0.45 * (0.5 + 0.5 * sin(t * 5 + Double(i))))
                        .scaleEffect(0.7 + 0.35 * sparklePhase)
                }
            }
        }
    }

    private func foreground(for index: Int) -> Color {
        let base = look.resolvedColor(theme.palette)
        if activeFlourish == .letterCascade, opacity < 1 {
            return base.opacity(0.35 + 0.65 * Double(index) / 3.0)
        }
        return base
    }

    private func runCycle() async {
        // Settle briefly after launch, then flourish on an interval.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        while !Task.isCancelled {
            await playRandomFlourish()
            try? await Task.sleep(nanoseconds: cycleSeconds * 1_000_000_000)
        }
    }

    @MainActor
    private func playRandomFlourish() async {
        let nextLook = TitleLook.random(excluding: look)
        let flourish = FlourishKind.allCases.randomElement() ?? .crossfade
        activeFlourish = flourish

        if reduceMotion {
            look = nextLook
            opacity = 1
            scale = 1
            glow = 0
            showSparkles = false
            letterOffsets = Array(repeating: 0, count: 4)
            return
        }

        switch flourish {
        case .crossfade:
            withAnimation(.easeIn(duration: 0.35)) { opacity = 0 }
            try? await Task.sleep(nanoseconds: 380_000_000)
            look = nextLook
            withAnimation(.easeOut(duration: 0.45)) { opacity = 1 }

        case .colourBloom:
            withAnimation(.easeInOut(duration: 0.55)) { glow = 0.55 }
            try? await Task.sleep(nanoseconds: 280_000_000)
            withAnimation(.easeInOut(duration: 0.55)) {
                look = nextLook
                glow = 0
            }

        case .sparkleFont:
            showSparkles = true
            withAnimation(.easeInOut(duration: 0.4)) {
                sparklePhase = 1
                opacity = 0.15
                scale = 0.96
            }
            try? await Task.sleep(nanoseconds: 420_000_000)
            look = nextLook
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                opacity = 1
                scale = 1
                sparklePhase = 0
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            showSparkles = false

        case .shimmer:
            shimmer = -1.2
            withAnimation(.easeInOut(duration: 0.9)) { shimmer = 1.2 }
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeInOut(duration: 0.4)) { look = nextLook }
            try? await Task.sleep(nanoseconds: 500_000_000)
            activeFlourish = .crossfade

        case .softPulse:
            withAnimation(.easeInOut(duration: 0.28)) { scale = 1.08 }
            try? await Task.sleep(nanoseconds: 280_000_000)
            look = nextLook
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { scale = 1 }

        case .letterCascade:
            for i in 0..<4 {
                withAnimation(.easeOut(duration: 0.18)) {
                    letterOffsets[i] = -4
                    opacity = 0.4
                }
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
            look = nextLook
            for i in 0..<4 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    letterOffsets[i] = 0
                    opacity = 1
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }
}

// MARK: - Looks & flourishes

private enum FlourishKind: CaseIterable {
    case crossfade
    case colourBloom
    case sparkleFont
    case shimmer
    case softPulse
    case letterCascade
}

private struct TitleLook: Equatable {
    enum Face: CaseIterable {
        case system, serif, rounded, mono
    }

    enum Tint: CaseIterable {
        case text, accent, accentStrong, muted, preferred
    }

    var face: Face
    var tint: Tint
    var tracking: CGFloat

    static let resting = TitleLook(face: .system, tint: .text, tracking: 1.2)

    var font: Font {
        switch face {
        case .system:
            return .system(size: 13, weight: .semibold, design: .default)
        case .serif:
            return .system(size: 13, weight: .semibold, design: .serif)
        case .rounded:
            return .system(size: 13, weight: .bold, design: .rounded)
        case .mono:
            return .system(size: 12, weight: .semibold, design: .monospaced)
        }
    }

    func resolvedColor(_ palette: ThemePalette) -> Color {
        switch tint {
        case .text: return palette.text
        case .accent: return palette.accent
        case .accentStrong: return palette.accentStrong
        case .muted: return palette.textMuted
        case .preferred: return palette.preferredHighlight
        }
    }

    static func random(excluding current: TitleLook) -> TitleLook {
        var next = current
        for _ in 0..<8 {
            next = TitleLook(
                face: Face.allCases.randomElement() ?? .system,
                tint: Tint.allCases.randomElement() ?? .text,
                tracking: [0.6, 1.2, 2.0, 2.8].randomElement() ?? 1.2
            )
            if next != current { break }
        }
        return next
    }
}

/// Hides the native window title string so the custom wordmark can own that spot.
struct WindowTitleVisibilityHidden: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private weak var window: NSWindow?

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.apply(to: view.window)
                guard let window = view.window, window !== self.window else { return }
                self.teardown()
                self.window = window
                let center = NotificationCenter.default
                for name in [
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didBecomeMainNotification,
                ] {
                    let token = center.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        self?.apply(to: window)
                    }
                    self.observers.append(token)
                }
            }
        }

        private func teardown() {
            let center = NotificationCenter.default
            for token in observers {
                center.removeObserver(token)
            }
            observers.removeAll()
            window = nil
        }

        private func apply(to window: NSWindow?) {
            guard let window else { return }
            // Empty title + hidden visibility prevents a second "ARIL" next to the wordmark.
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.title.isEmpty {
                window.title = ""
            }
        }

        deinit {
            teardown()
        }
    }
}
