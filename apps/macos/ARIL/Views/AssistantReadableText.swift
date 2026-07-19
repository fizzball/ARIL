import SwiftUI
import Foundation

/// Turns model Markdown + common LaTeX into readable attributed text for chat bubbles.
enum AssistantReadableText {
    /// Prepare a single line (or short span) with inline Markdown + math cleanup.
    static func attributed(_ raw: String) -> AttributedString {
        let prepared = demathify(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(
            markdown: prepared,
            options: options,
            baseURL: nil
        ) {
            return parsed
        }
        return AttributedString(prepared)
    }

    /// Split model output into display rows so `\n` / blank lines show in SwiftUI `Text`
    /// (AttributedString Markdown otherwise collapses soft breaks into spaces).
    static func displayLines(_ raw: String) -> [String] {
        demathify(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Inline Markdown for one visual line (no embedded newlines).
    static func attributedLine(_ line: String) -> AttributedString {
        let prepared = line
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(
            markdown: prepared,
            options: options,
            baseURL: nil
        ) {
            return parsed
        }
        return AttributedString(prepared)
    }

    /// Convert inline/display LaTeX into plain Unicode-friendly math so `\(…\)` etc. don’t show raw.
    static func demathify(_ input: String) -> String {
        var s = input
        s = replaceMathDelimiters(s, open: "\\[", close: "\\]")
        s = replaceMathDelimiters(s, open: "\\(", close: "\\)")
        s = replaceMathDelimiters(s, open: "$$", close: "$$")
        // Single-dollar math (avoid bare currency like $5 by requiring non-space insides).
        s = replaceRegex(
            s,
            pattern: #"\$([^\$\n]+?)\$"#,
            templateHandler: { simplifyLatex($0) }
        )
        // Plain text exponents left outside math (e.g. cm^3).
        s = replaceRegex(s, pattern: #"\^([0-9])"#) { toSuperscript($0) }
        return s
    }

    // MARK: - Delimiters

    private static func replaceMathDelimiters(_ input: String, open: String, close: String) -> String {
        var s = input
        while let openRange = s.range(of: open) {
            guard let closeRange = s.range(of: close, range: openRange.upperBound..<s.endIndex) else {
                break
            }
            let inner = String(s[openRange.upperBound..<closeRange.lowerBound])
            let replacement = simplifyLatex(inner)
            s.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: replacement)
        }
        return s
    }

    private static func replaceRegex(
        _ input: String,
        pattern: String,
        templateHandler: (String) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let full = Range(match.range, in: result),
                  let inner = Range(match.range(at: 1), in: result)
            else { continue }
            result.replaceSubrange(full, with: templateHandler(String(result[inner])))
        }
        return result
    }

    // MARK: - LaTeX → readable

    static func simplifyLatex(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        // \frac{a}{b} (repeat for light nesting)
        for _ in 0..<8 {
            let next = replaceFrac(s)
            if next == s { break }
            s = next
        }

        // \sqrt{x}
        s = replaceRegex(s, pattern: #"\\sqrt\{([^{}]+)\}"#) { "√(\($0))" }
        s = s.replacingOccurrences(of: #"\\sqrt\s*"#, with: "√", options: .regularExpression)

        // Common symbols / words
        let symbols: [(String, String)] = [
            (#"\\times"#, "×"),
            (#"\\cdot"#, "·"),
            (#"\\approx"#, "≈"),
            (#"\\neq"#, "≠"),
            (#"\\leq"#, "≤"),
            (#"\\geq"#, "≥"),
            (#"\\pm"#, "±"),
            (#"\\infty"#, "∞"),
            (#"\\degree"#, "°"),
            (#"\\pi\b"#, "π"),
            (#"\\theta\b"#, "θ"),
            (#"\\alpha\b"#, "α"),
            (#"\\beta\b"#, "β"),
            (#"\\gamma\b"#, "γ"),
            (#"\\Delta\b"#, "Δ"),
            (#"\\sum\b"#, "Σ"),
            (#"\\prod\b"#, "Π"),
            (#"\\int\b"#, "∫"),
            (#"\\ldots"#, "…"),
            (#"\\cdots"#, "⋯"),
            (#"\\left"#, ""),
            (#"\\right"#, ""),
            (#"\\,"#, " "),
            (#"\\;"#, " "),
            (#"\\!"#, ""),
            (#"\\quad"#, " "),
            (#"\\qquad"#, "  "),
            (#"\\%"#, "%"),
            (#"\\_"#, "_"),
            (#"\\\{"#, "{"),
            (#"\\\}"#, "}"),
        ]
        for (pattern, replacement) in symbols {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        // \text{…} / \mathrm{…} / \mathbf{…}
        s = replaceRegex(s, pattern: #"\\(?:text|mathrm|mathbf|mathit|operatorname)\{([^{}]*)\}"#) { $0 }

        // Simple superscripts: x^2 or x^{10}
        s = replaceRegex(s, pattern: #"\^\{([0-9]+)\}"#) { toSuperscript($0) }
        s = replaceRegex(s, pattern: #"\^([0-9])"#) { toSuperscript($0) }
        s = replaceRegex(s, pattern: #"_\{([0-9]+)\}"#) { toSubscript($0) }
        s = replaceRegex(s, pattern: #"_([0-9])"#) { toSubscript($0) }

        // Drop remaining simple commands like \cos → cos
        s = s.replacingOccurrences(
            of: #"\\([a-zA-Z]+)"#,
            with: "$1",
            options: .regularExpression
        )

        // Unwrap leftover single-level braces
        s = s.replacingOccurrences(of: #"\{([^{}]+)\}"#, with: "$1", options: .regularExpression)

        // Collapse whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceFrac(_ input: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"\\frac\{([^{}]+)\}\{([^{}]+)\}"#,
            options: []
        ) else { return input }
        let ns = input as NSString
        guard let match = re.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3,
              let full = Range(match.range, in: input),
              let a = Range(match.range(at: 1), in: input),
              let b = Range(match.range(at: 2), in: input)
        else { return input }
        let num = String(input[a])
        let den = String(input[b])
        var out = input
        out.replaceSubrange(full, with: "(\(num)/\(den))")
        return out
    }

    private static func toSuperscript(_ digits: String) -> String {
        let map: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        ]
        let converted = String(digits.map { map[$0] ?? $0 })
        return converted == digits ? "^\(digits)" : converted
    }

    private static func toSubscript(_ digits: String) -> String {
        let map: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        ]
        let converted = String(digits.map { map[$0] ?? $0 })
        return converted == digits ? "_\(digits)" : converted
    }
}
