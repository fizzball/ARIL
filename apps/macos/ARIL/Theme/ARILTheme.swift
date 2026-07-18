import SwiftUI
import AppKit
import Combine

enum AppThemeOption: String, CaseIterable, Identifiable, Codable {
    case system
    case noir, slate, light, forest
    case ocean, graphite, sand, dusk, midnight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .noir: return "Noir"
        case .slate: return "Slate"
        case .light: return "Light"
        case .forest: return "Forest"
        case .ocean: return "Ocean"
        case .graphite: return "Graphite"
        case .sand: return "Sand"
        case .dusk: return "Dusk"
        case .midnight: return "Midnight"
        }
    }

    /// Fixed light/dark for named themes; `nil` means follow macOS.
    var fixedColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .sand: return .light
        case .noir, .slate, .forest, .ocean, .graphite, .dusk, .midnight: return .dark
        }
    }
}

struct ThemePalette {
    let background: Color
    let backgroundElevated: Color
    /// Distinct fill for the intelligence/analysis strip above the prompt bar.
    let analysisFill: Color
    let sidebar: Color
    let text: Color
    /// Agent replies — cooler / softer than prompt text so turns are easy to scan.
    let assistantText: Color
    let textMuted: Color
    let accent: Color
    let accentStrong: Color
    let hairline: Color
    let inputFill: Color
    let danger: Color
    let preferredHighlight: Color
    /// Turn cost footer under assistant replies.
    let costFooter: Color
    let colorScheme: ColorScheme

    static func palette(for option: AppThemeOption, systemIsDark: Bool) -> ThemePalette {
        switch option {
        case .system:
            return systemIsDark ? graphitePalette : sandPalette
        case .noir:
            return ThemePalette(
                background: Color(red: 0.09, green: 0.07, blue: 0.06),
                backgroundElevated: Color(red: 0.12, green: 0.10, blue: 0.09),
                analysisFill: Color(red: 0.22, green: 0.17, blue: 0.11),
                sidebar: Color(red: 0.07, green: 0.06, blue: 0.05),
                text: Color(red: 0.92, green: 0.88, blue: 0.80),
                assistantText: Color(red: 0.72, green: 0.82, blue: 0.88),
                textMuted: Color(red: 0.72, green: 0.68, blue: 0.60),
                accent: Color(red: 0.78, green: 0.66, blue: 0.42),
                accentStrong: Color(red: 0.85, green: 0.72, blue: 0.40),
                hairline: Color.white.opacity(0.08),
                inputFill: Color(red: 0.12, green: 0.10, blue: 0.09),
                danger: Color(red: 0.75, green: 0.35, blue: 0.30),
                preferredHighlight: Color(red: 0.95, green: 0.78, blue: 0.35),
                costFooter: Color(red: 0.95, green: 0.78, blue: 0.35),
                colorScheme: .dark
            )
        case .slate:
            return ThemePalette(
                background: Color(red: 0.10, green: 0.12, blue: 0.15),
                backgroundElevated: Color(red: 0.14, green: 0.16, blue: 0.20),
                analysisFill: Color(red: 0.18, green: 0.26, blue: 0.36),
                sidebar: Color(red: 0.08, green: 0.09, blue: 0.12),
                text: Color(red: 0.90, green: 0.92, blue: 0.95),
                assistantText: Color(red: 0.62, green: 0.80, blue: 0.92),
                textMuted: Color(red: 0.65, green: 0.70, blue: 0.78),
                accent: Color(red: 0.45, green: 0.70, blue: 0.95),
                accentStrong: Color(red: 0.55, green: 0.78, blue: 1.0),
                hairline: Color.white.opacity(0.10),
                inputFill: Color(red: 0.13, green: 0.15, blue: 0.18),
                danger: Color(red: 0.85, green: 0.40, blue: 0.40),
                preferredHighlight: Color(red: 0.40, green: 0.85, blue: 0.90),
                costFooter: Color(red: 0.40, green: 0.85, blue: 0.90),
                colorScheme: .dark
            )
        case .light:
            return ThemePalette(
                background: Color(red: 0.96, green: 0.96, blue: 0.95),
                backgroundElevated: Color.white,
                analysisFill: Color(red: 0.88, green: 0.84, blue: 0.74),
                sidebar: Color(red: 0.93, green: 0.93, blue: 0.92),
                text: Color(red: 0.15, green: 0.15, blue: 0.14),
                assistantText: Color(red: 0.18, green: 0.32, blue: 0.48),
                textMuted: Color(red: 0.40, green: 0.40, blue: 0.38),
                accent: Color(red: 0.45, green: 0.32, blue: 0.15),
                accentStrong: Color(red: 0.55, green: 0.38, blue: 0.12),
                hairline: Color.black.opacity(0.08),
                inputFill: Color(red: 0.99, green: 0.99, blue: 0.98),
                danger: Color(red: 0.75, green: 0.20, blue: 0.18),
                preferredHighlight: Color(red: 0.15, green: 0.45, blue: 0.35),
                costFooter: Color(red: 0.12, green: 0.42, blue: 0.36),
                colorScheme: .light
            )
        case .forest:
            return ThemePalette(
                background: Color(red: 0.07, green: 0.11, blue: 0.09),
                backgroundElevated: Color(red: 0.10, green: 0.15, blue: 0.12),
                analysisFill: Color(red: 0.14, green: 0.28, blue: 0.18),
                sidebar: Color(red: 0.05, green: 0.09, blue: 0.07),
                text: Color(red: 0.88, green: 0.93, blue: 0.88),
                assistantText: Color(red: 0.70, green: 0.88, blue: 0.78),
                textMuted: Color(red: 0.60, green: 0.70, blue: 0.62),
                accent: Color(red: 0.55, green: 0.78, blue: 0.50),
                accentStrong: Color(red: 0.65, green: 0.88, blue: 0.55),
                hairline: Color.white.opacity(0.08),
                inputFill: Color(red: 0.09, green: 0.13, blue: 0.11),
                danger: Color(red: 0.80, green: 0.40, blue: 0.35),
                preferredHighlight: Color(red: 0.85, green: 0.75, blue: 0.35),
                costFooter: Color(red: 0.85, green: 0.75, blue: 0.35),
                colorScheme: .dark
            )
        case .ocean:
            return ThemePalette(
                background: Color(red: 0.06, green: 0.11, blue: 0.16),
                backgroundElevated: Color(red: 0.09, green: 0.15, blue: 0.21),
                analysisFill: Color(red: 0.10, green: 0.28, blue: 0.36),
                sidebar: Color(red: 0.04, green: 0.08, blue: 0.12),
                text: Color(red: 0.88, green: 0.94, blue: 0.96),
                assistantText: Color(red: 0.55, green: 0.85, blue: 0.90),
                textMuted: Color(red: 0.55, green: 0.68, blue: 0.74),
                accent: Color(red: 0.25, green: 0.72, blue: 0.78),
                accentStrong: Color(red: 0.35, green: 0.85, blue: 0.88),
                hairline: Color.white.opacity(0.09),
                inputFill: Color(red: 0.08, green: 0.13, blue: 0.18),
                danger: Color(red: 0.90, green: 0.42, blue: 0.40),
                preferredHighlight: Color(red: 0.95, green: 0.72, blue: 0.35),
                costFooter: Color(red: 0.95, green: 0.72, blue: 0.35),
                colorScheme: .dark
            )
        case .graphite:
            return graphitePalette
        case .sand:
            return sandPalette
        case .dusk:
            return ThemePalette(
                background: Color(red: 0.10, green: 0.08, blue: 0.14),
                backgroundElevated: Color(red: 0.14, green: 0.11, blue: 0.19),
                analysisFill: Color(red: 0.22, green: 0.16, blue: 0.30),
                sidebar: Color(red: 0.07, green: 0.06, blue: 0.11),
                text: Color(red: 0.92, green: 0.90, blue: 0.96),
                assistantText: Color(red: 0.78, green: 0.72, blue: 0.92),
                textMuted: Color(red: 0.68, green: 0.64, blue: 0.76),
                accent: Color(red: 0.72, green: 0.55, blue: 0.88),
                accentStrong: Color(red: 0.82, green: 0.65, blue: 0.95),
                hairline: Color.white.opacity(0.09),
                inputFill: Color(red: 0.12, green: 0.10, blue: 0.17),
                danger: Color(red: 0.88, green: 0.40, blue: 0.45),
                preferredHighlight: Color(red: 0.95, green: 0.70, blue: 0.45),
                costFooter: Color(red: 0.95, green: 0.70, blue: 0.45),
                colorScheme: .dark
            )
        case .midnight:
            return ThemePalette(
                background: Color(red: 0.04, green: 0.06, blue: 0.12),
                backgroundElevated: Color(red: 0.07, green: 0.10, blue: 0.18),
                analysisFill: Color(red: 0.10, green: 0.18, blue: 0.36),
                sidebar: Color(red: 0.03, green: 0.04, blue: 0.09),
                text: Color(red: 0.90, green: 0.93, blue: 0.98),
                assistantText: Color(red: 0.60, green: 0.75, blue: 0.95),
                textMuted: Color(red: 0.55, green: 0.62, blue: 0.75),
                accent: Color(red: 0.40, green: 0.58, blue: 0.95),
                accentStrong: Color(red: 0.50, green: 0.68, blue: 1.0),
                hairline: Color.white.opacity(0.10),
                inputFill: Color(red: 0.06, green: 0.09, blue: 0.16),
                danger: Color(red: 0.90, green: 0.38, blue: 0.42),
                preferredHighlight: Color(red: 0.35, green: 0.85, blue: 0.75),
                costFooter: Color(red: 0.35, green: 0.85, blue: 0.75),
                colorScheme: .dark
            )
        }
    }

    /// Neutral dark used by Graphite and System (when macOS is dark).
    private static var graphitePalette: ThemePalette {
        ThemePalette(
            background: Color(red: 0.11, green: 0.11, blue: 0.12),
            backgroundElevated: Color(red: 0.16, green: 0.16, blue: 0.17),
            analysisFill: Color(red: 0.20, green: 0.22, blue: 0.26),
            sidebar: Color(red: 0.08, green: 0.08, blue: 0.09),
            text: Color(red: 0.92, green: 0.92, blue: 0.93),
            assistantText: Color(red: 0.72, green: 0.78, blue: 0.86),
            textMuted: Color(red: 0.62, green: 0.62, blue: 0.66),
            accent: Color(red: 0.55, green: 0.62, blue: 0.72),
            accentStrong: Color(red: 0.68, green: 0.74, blue: 0.84),
            hairline: Color.white.opacity(0.10),
            inputFill: Color(red: 0.14, green: 0.14, blue: 0.15),
            danger: Color(red: 0.88, green: 0.40, blue: 0.38),
            preferredHighlight: Color(red: 0.55, green: 0.78, blue: 0.70),
            costFooter: Color(red: 0.55, green: 0.78, blue: 0.70),
            colorScheme: .dark
        )
    }

    /// Warm light used by Sand and System (when macOS is light).
    private static var sandPalette: ThemePalette {
        ThemePalette(
            background: Color(red: 0.97, green: 0.96, blue: 0.93),
            backgroundElevated: Color(red: 1.0, green: 0.99, blue: 0.97),
            analysisFill: Color(red: 0.90, green: 0.88, blue: 0.80),
            sidebar: Color(red: 0.94, green: 0.93, blue: 0.90),
            text: Color(red: 0.18, green: 0.16, blue: 0.14),
            assistantText: Color(red: 0.22, green: 0.34, blue: 0.42),
            textMuted: Color(red: 0.45, green: 0.42, blue: 0.38),
            accent: Color(red: 0.55, green: 0.40, blue: 0.22),
            accentStrong: Color(red: 0.65, green: 0.48, blue: 0.26),
            hairline: Color.black.opacity(0.08),
            inputFill: Color(red: 0.99, green: 0.98, blue: 0.96),
            danger: Color(red: 0.78, green: 0.22, blue: 0.18),
            preferredHighlight: Color(red: 0.20, green: 0.48, blue: 0.40),
            costFooter: Color(red: 0.18, green: 0.45, blue: 0.38),
            colorScheme: .light
        )
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var option: AppThemeOption {
        didSet {
            UserDefaults.standard.set(option.rawValue, forKey: "aril.theme")
            refreshPalette()
        }
    }
    @Published private(set) var palette: ThemePalette

    /// `nil` when Theme is System — SwiftUI / windows follow macOS light·dark·auto.
    var preferredColorScheme: ColorScheme? { option.fixedColorScheme }

    private var appearanceObservation: NSKeyValueObservation?

    init() {
        let raw = UserDefaults.standard.string(forKey: "aril.theme") ?? AppThemeOption.noir.rawValue
        let opt = AppThemeOption(rawValue: raw) ?? .noir
        option = opt
        palette = ThemePalette.palette(for: opt, systemIsDark: Self.macOSIsDark)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshPalette()
            }
        }
    }

    deinit {
        appearanceObservation?.invalidate()
    }

    func refreshPalette() {
        palette = ThemePalette.palette(for: option, systemIsDark: Self.macOSIsDark)
    }

    static var macOSIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Back-compat aliases used across views.
enum ARILTheme {
    static let wordmarkFont = Font.system(size: 44, weight: .bold, design: .serif)
    static let bodyFont = Font.system(size: 13, weight: .regular, design: .default)
    static let captionFont = Font.system(size: 11, weight: .medium, design: .default)
}
