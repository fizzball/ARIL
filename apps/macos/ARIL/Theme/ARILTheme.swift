import SwiftUI

enum ARILTheme {
    // Hermes-inspired noir: chocolate / near-black + cream / muted gold
    static let background = Color(red: 0.09, green: 0.07, blue: 0.06)
    static let backgroundElevated = Color(red: 0.12, green: 0.10, blue: 0.09)
    static let sidebar = Color(red: 0.07, green: 0.06, blue: 0.05)
    static let cream = Color(red: 0.92, green: 0.88, blue: 0.80)
    static let creamMuted = Color(red: 0.72, green: 0.68, blue: 0.60)
    static let gold = Color(red: 0.78, green: 0.66, blue: 0.42)
    static let goldStrong = Color(red: 0.85, green: 0.72, blue: 0.40)
    static let hairline = Color.white.opacity(0.08)
    static let inputFill = Color(red: 0.14, green: 0.12, blue: 0.10)
    static let danger = Color(red: 0.75, green: 0.35, blue: 0.30)

    static let wordmarkFont = Font.system(size: 44, weight: .bold, design: .serif)
    static let bodyFont = Font.system(size: 13, weight: .regular, design: .default)
    static let captionFont = Font.system(size: 11, weight: .medium, design: .default)
}
