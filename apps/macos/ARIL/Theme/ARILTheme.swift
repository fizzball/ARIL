import SwiftUI
import Combine

enum AppThemeOption: String, CaseIterable, Identifiable, Codable {
    case noir, slate, light, forest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .noir: return "Noir"
        case .slate: return "Slate"
        case .light: return "Light"
        case .forest: return "Forest"
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

    static func palette(for option: AppThemeOption) -> ThemePalette {
        switch option {
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
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var option: AppThemeOption {
        didSet {
            UserDefaults.standard.set(option.rawValue, forKey: "aril.theme")
            palette = ThemePalette.palette(for: option)
        }
    }
    @Published private(set) var palette: ThemePalette

    init() {
        let raw = UserDefaults.standard.string(forKey: "aril.theme") ?? AppThemeOption.noir.rawValue
        let opt = AppThemeOption(rawValue: raw) ?? .noir
        option = opt
        palette = ThemePalette.palette(for: opt)
    }
}

/// Back-compat aliases used across views.
enum ARILTheme {
    static let wordmarkFont = Font.system(size: 44, weight: .bold, design: .serif)
    static let bodyFont = Font.system(size: 13, weight: .regular, design: .default)
    static let captionFont = Font.system(size: 11, weight: .medium, design: .default)
}
