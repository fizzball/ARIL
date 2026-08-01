import SwiftUI
import AppKit

/// Compact ARIL wordmark for the window title bar. Click opens About. Every ~60s it
/// plays a short flourish (pulse / shimmer / sparkle) over the brand image.
struct ARILTitleWordmarkView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var opacity: Double = 1
    @State private var scale: CGFloat = 1
    @State private var glow: Double = 0
    @State private var shimmer: CGFloat = -1.2
    @State private var sparklePhase: Double = 0
    @State private var showSparkles = false
    @State private var activeFlourish: FlourishKind = .softPulse

    private let cycleSeconds: UInt64 = 60

    var body: some View {
        Button {
            state.openToolPanel(.about)
        } label: {
            ZStack {
                ARILWordmarkImage(height: 16)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .shadow(color: theme.palette.accent.opacity(glow), radius: glow > 0 ? 6 : 0)
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
                            .mask(ARILWordmarkImage(height: 16))
                        }
                    }

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

    private func runCycle() async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        while !Task.isCancelled {
            await playRandomFlourish()
            try? await Task.sleep(nanoseconds: cycleSeconds * 1_000_000_000)
        }
    }

    @MainActor
    private func playRandomFlourish() async {
        let flourish = FlourishKind.allCases.randomElement() ?? .softPulse
        activeFlourish = flourish

        if reduceMotion {
            opacity = 1
            scale = 1
            glow = 0
            showSparkles = false
            return
        }

        switch flourish {
        case .crossfade:
            withAnimation(.easeIn(duration: 0.35)) { opacity = 0.2 }
            try? await Task.sleep(nanoseconds: 380_000_000)
            withAnimation(.easeOut(duration: 0.45)) { opacity = 1 }

        case .colourBloom:
            withAnimation(.easeInOut(duration: 0.55)) { glow = 0.55 }
            try? await Task.sleep(nanoseconds: 280_000_000)
            withAnimation(.easeInOut(duration: 0.55)) { glow = 0 }

        case .sparkle:
            showSparkles = true
            withAnimation(.easeInOut(duration: 0.4)) {
                sparklePhase = 1
                opacity = 0.35
                scale = 0.96
            }
            try? await Task.sleep(nanoseconds: 420_000_000)
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
            try? await Task.sleep(nanoseconds: 950_000_000)
            activeFlourish = .softPulse

        case .softPulse:
            withAnimation(.easeInOut(duration: 0.28)) { scale = 1.08 }
            try? await Task.sleep(nanoseconds: 280_000_000)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { scale = 1 }
        }
    }
}

private enum FlourishKind: CaseIterable {
    case crossfade
    case colourBloom
    case sparkle
    case shimmer
    case softPulse
}

/// Hides the native window title string so the custom wordmark can own that spot.
enum WindowTitleHiding {
    static func hide(in window: NSWindow?) {
        guard let window else { return }
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if !window.title.isEmpty {
            window.title = ""
        }
        if window.subtitle.isEmpty == false {
            window.subtitle = ""
        }
    }
}

/// Re-applies title hiding when `refreshToken` changes (e.g. sidebar collapse), because
/// macOS often resurfaces the bundle name (“ARIL”) beside toolbar items.
struct WindowTitleVisibilityHidden<Token: Equatable>: NSViewRepresentable {
    var refreshToken: Token

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
        WindowTitleHiding.hide(in: nsView.window ?? NSApp.keyWindow)
    }

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []
        private var titleObservation: NSKeyValueObservation?
        private weak var window: NSWindow?

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                WindowTitleHiding.hide(in: view.window)
                guard let window = view.window, window !== self.window else { return }
                self.teardown()
                self.window = window
                self.titleObservation = window.observe(\.title, options: [.new]) { win, _ in
                    if !win.title.isEmpty {
                        WindowTitleHiding.hide(in: win)
                    }
                }
                let center = NotificationCenter.default
                for name in [
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didBecomeMainNotification,
                ] {
                    let token = center.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { _ in
                        WindowTitleHiding.hide(in: window)
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
            titleObservation?.invalidate()
            titleObservation = nil
            window = nil
        }

        deinit {
            teardown()
        }
    }
}
