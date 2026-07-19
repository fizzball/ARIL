import Foundation

/// Local content filters for Subscription → Guardrails toggles.
/// Prompt-injection patterns follow OpenRouter's documented regex set:
/// https://openrouter.ai/docs/guides/features/guardrails/prompt-injection
enum LocalGuardrailScanner {
    enum Kind: String {
        case promptInjection
        case sensitiveInfo
    }

    struct Hit: Equatable {
        let kind: Kind
        let patternName: String
        let match: String
    }

    struct Result: Equatable {
        var hits: [Hit] = []
        /// Text after sensitive-info redaction (unchanged when that toggle is off).
        var text: String
        var blocked: Bool { hits.contains { $0.kind == .promptInjection } }
        var didRedact: Bool {
            hits.contains { $0.kind == .sensitiveInfo }
        }

        var blockMessage: String? {
            guard blocked else { return nil }
            let names = hits
                .filter { $0.kind == .promptInjection }
                .map(\.patternName)
            let unique = Array(Set(names)).sorted()
            let listed = unique.prefix(3).joined(separator: ", ")
            let more = unique.count > 3 ? " (+\(unique.count - 3) more)" : ""
            return "Blocked by local Prompt Injection guardrail (\(listed)\(more)). Edit the prompt or disable the toggle in Preferences → Subscription."
        }

        var redactSummary: String? {
            guard didRedact else { return nil }
            let n = hits.filter { $0.kind == .sensitiveInfo }.count
            return "Redacted \(n) sensitive match\(n == 1 ? "" : "es") before send."
        }
    }

    static func apply(
        _ text: String,
        sensitiveInfo: Bool,
        promptInjection: Bool
    ) -> Result {
        var result = Result(text: text)
        guard !text.isEmpty, sensitiveInfo || promptInjection else { return result }

        if promptInjection {
            for (name, regex) in injectionPatterns {
                for match in matches(in: text, regex: regex) {
                    result.hits.append(Hit(kind: .promptInjection, patternName: name, match: match))
                }
            }
            // Character-spaced evasion: collapse spaces and re-scan.
            let collapsed = collapseSpacedLetters(text)
            if collapsed != text {
                for (name, regex) in injectionPatterns {
                    for match in matches(in: collapsed, regex: regex) {
                        result.hits.append(
                            Hit(kind: .promptInjection, patternName: "\(name)_spaced", match: match)
                        )
                    }
                }
            }
        }

        if sensitiveInfo {
            let (redacted, sensitiveHits) = redactSensitive(text)
            result.text = redacted
            result.hits.append(contentsOf: sensitiveHits)
        }

        return result
    }

    // MARK: - Sensitive info

    /// Card number allowing optional spaces/dashes between digit groups
    /// (e.g. `4111 1111 1111 1111`, `4111-1111-1111-1111`, `4111111111111111`).
    private static let cardGroupedRegex: NSRegularExpression = {
        // Visa / Mastercard / Discover: 4 groups of 4 (16 digits) with optional separators.
        let visaMcDisc =
            #"(?:4[0-9]{3}|5[1-5][0-9]{2}|6(?:011|5[0-9]{2}))(?:[-\s]?[0-9]{4}){3}"#
        // Amex: 4-6-5 grouping (15 digits).
        let amex = #"3[47][0-9]{2}(?:[-\s]?[0-9]{6})(?:[-\s]?[0-9]{5})"#
        let pattern = #"\b(?:"# + visaMcDisc + #"|"# + amex + #")\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Contiguous PAN (no separators) — Visa 13/16, MC 16, Amex 15, Discover 16.
    private static let cardContiguousRegex: NSRegularExpression = {
        let pattern =
            #"\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})\b"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let ssnRegex: NSRegularExpression = {
        let pattern =
            #"(?:Social.*?\d{3}-\d{2}-\d{4}|\d{3}-\d{2}-\d{4}.*?Social)"#
        return try! NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }()

    private static let confidentialRegex: NSRegularExpression = {
        let pattern = #"\b(?:internal use only|confidential|do not share)\b"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func redactSensitive(_ text: String) -> (String, [Hit]) {
        struct Span: Comparable {
            let range: Range<String.Index>
            let placeholder: String
            let patternName: String
            let matched: String
            static func < (lhs: Span, rhs: Span) -> Bool {
                lhs.range.lowerBound < rhs.range.lowerBound
            }
        }

        var spans: [Span] = []
        func collect(_ regex: NSRegularExpression, placeholder: String, name: String) {
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: text, options: [], range: full) {
                guard let range = Range(match.range, in: text) else { continue }
                let matched = String(text[range])
                spans.append(
                    Span(range: range, placeholder: placeholder, patternName: name, matched: matched)
                )
            }
        }

        collect(cardGroupedRegex, placeholder: "[CREDIT_CARD]", name: "credit_card")
        collect(cardContiguousRegex, placeholder: "[CREDIT_CARD]", name: "credit_card")
        collect(ssnRegex, placeholder: "[SSN]", name: "ssn")
        collect(confidentialRegex, placeholder: "[REDACTED]", name: "confidential")

        guard !spans.isEmpty else { return (text, []) }

        // Drop overlapping spans (keep earliest / longest).
        let sorted = spans.sorted()
        var selected: [Span] = []
        for span in sorted {
            if let last = selected.last, span.range.overlaps(last.range) {
                if span.matched.count > last.matched.count {
                    selected[selected.count - 1] = span
                }
                continue
            }
            selected.append(span)
        }

        var hits: [Hit] = []
        var parts: [String] = []
        var cursor = text.startIndex
        for span in selected {
            hits.append(
                Hit(kind: .sensitiveInfo, patternName: span.patternName, match: span.matched)
            )
            if cursor < span.range.lowerBound {
                parts.append(String(text[cursor..<span.range.lowerBound]))
            }
            parts.append(span.placeholder)
            cursor = span.range.upperBound
        }
        if cursor < text.endIndex {
            parts.append(String(text[cursor...]))
        }
        return (parts.joined(), hits)
    }

    // MARK: - Prompt injection (OpenRouter pattern set)

    private static let injectionPatterns: [(String, NSRegularExpression)] = {
        let raw: [(String, String)] = [
            // Direct instruction override
            ("ignore_previous_instructions",
             #"ignore\s+(all\s+)?(previous|prior)\s+((?:safety|security|system|operational|internal|core|original|initial|existing|given|stated|provided|defined|specified|established)\s+)?(instructions?|rules?|guidelines?|constraints?|directives?)"#),
            ("disregard_instructions",
             #"disregard\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|guidelines?|constraints?|directives?)"#),
            ("forget_instructions",
             #"forget\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|guidelines?|constraints?|directives?)"#),
            ("new_instructions", #"new\s+instructions?:"#),
            ("do_not_follow",
             #"do\s+not\s+follow\s+(the\s+)?(system|developer|previous|original)"#),
            ("supersede_instructions",
             #"supersedes?\s+(all\s+)?(prior|previous)\s+(instructions?|rules?|guidelines?|constraints?|directives?)"#),
            ("void_instructions",
             #"(all\s+)?(previous|prior)\s+instructions?\s+(are|is)\s+(void|invalid|null|obsolete|cancelled|revoked)"#),
            // Developer / admin mode
            ("developer_mode", #"you\s+are\s+now\s+(in\s+)?developer\s+mode"#),
            ("enter_special_mode", #"enter\s+(developer|admin|debug|maintenance)\s+mode"#),
            ("activate_special_mode", #"activate\s+(developer|admin|debug|jailbreak)\s+mode"#),
            // System override
            ("system_override", #"\bsystem\s+override\b"#),
            ("override_instructions",
             #"override\s+(your\s+)?(instructions?|rules?|guidelines?|constraints?|directives?)"#),
            // Prompt extraction
            ("reveal_prompt",
             #"reveal\s+((?:your?|yoru|yuor|the|my|its|his|her|our|their)\s+)?((?:(?:full|hidden|complete|internal|secret|original|entire|exact|actual|real)\s+){0,2})((?:system|systme|sysetm|systemp?)\s+)?prompt\b"#),
            ("show_prompt",
             #"show\s+(me\s+)?((?:your?|yoru|yuor|the|my|its|his|her|our|their)\s+)((?:system|systme|sysetm|systemp?)\s+)?prompt\b"#),
            ("what_instructions", #"what\s+(are|were)\s+(your\s+)?(exact\s+)?instructions"#),
            ("repeat_instructions", #"repeat\s+(the\s+)?(text|instructions?)\s+(above|before)"#),
            ("output_prompt",
             #"output\s+(your\s+)?(initial|original|system)\s+(prompt|instructions?)"#),
            // Role manipulation
            ("remove_restrictions", #"you\s+are\s+no\s+longer\s+(bound|restricted|limited)"#),
            ("act_unbound", #"act\s+as\s+if\s+(you('re|\s+are)\s+)?not\s+bound"#),
            ("pretend_different",
             #"pretend\s+(you('re|\s+are)\s+)?(a\s+)?different\s+(ai|assistant|model)"#),
            ("identity_hijack",
             #"you\s+are\s+now\s+(?:(?:a|an)\s+)?\w+.{0,40}(without\s+(any\s+)?restrict|ignor\w*\s+(all|any|every|prev)|bypass|unrestrict|unlimit|obey\s+only|no\s+(rules|limits|restrict|boundari))"#),
            // DAN-style
            ("dan_jailbreak", #"\bDAN\b.*\bdo\s+anything\s+now\b"#),
            ("jailbreak_mode", #"jailbreak(ed)?\s+(mode|prompt)"#),
            // Safety bypass
            ("bypass_safety",
             #"bypass\s+(your\s+)?(safety|security|content|ethical)\s+(filters?|measures?|guidelines?|restrictions?)"#),
            ("disable_safety",
             #"disable\s+(your\s+)?(safety|security|content)\s+(filters?|measures?)"#),
            ("ignore_safety",
             #"(ignore|disregard)\s+(all\s+)?(your\s+)?(safety|security|ethical|content)\s+(guidelines?|rules?|restrictions?|measures?|filters?|polic(?:y|ies)|protocols?)"#),
            // Tag / role spoofing
            ("system_tag_injection", #"<\s*/?\s*system\s*/?>"#),
            ("role_tag_injection", #"<\s*/?\s*(assistant|developer|tool|function)\s*/?>"#),
            ("role_delimiter_injection", #"\]\s*\n\s*\[?(system|assistant|user)\]?:"#),
            ("bracketed_role_spoofing", #"\[\s*(System\s*Message|System|Assistant|Internal)\s*\]"#),
            ("system_prefix_spoofing", #"^\s*System:\s+"#),
            // Control tokens
            ("control_token_injection", #"<\|(?:im_start|im_end|eot_id|start_header_id|end_header_id|endoftext)\|>"#),
        ]

        return raw.compactMap { name, pattern in
            var options: NSRegularExpression.Options = [.caseInsensitive]
            if name == "dan_jailbreak" {
                // OpenRouter: case-sensitive for DAN token — keep caseInsensitive off for whole pattern
                // but DAN is uppercase in pattern; use default case-sensitive for this one only.
                options = []
            }
            if name == "system_prefix_spoofing" {
                options.insert(.anchorsMatchLines)
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return nil
            }
            return (name, regex)
        }
    }()

    private static func matches(in text: String, regex: NSRegularExpression) -> [String] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, options: [], range: full).compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            return ns.substring(with: match.range)
        }
    }

    /// Normalize `i g n o r e  p r e v i o u s` style spacing for a second pass.
    private static func collapseSpacedLetters(_ text: String) -> String {
        // Collapse single-char tokens separated by spaces into words, conservatively.
        let pattern = #"(?<=\b\w)(?:\s+\w){2,}(?=\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out = text
        let found = regex.matches(in: text, options: [], range: full)
        for match in found.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let chunk = String(out[range]).replacingOccurrences(of: " ", with: "")
            out.replaceSubrange(range, with: chunk)
        }
        return out
    }
}
