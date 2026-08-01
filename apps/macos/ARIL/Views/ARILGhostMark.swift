import SwiftUI
import AppKit

/// Mesh brand colors from the ARIL adaptive-routing identity sheet.
enum ARILLogoPalette {
    static let gold = Color(red: 0.922, green: 0.749, blue: 0.357) // legacy
    static let olive = Color(red: 0.455, green: 0.416, blue: 0.239) // legacy

    static let meshNode = Color(red: 0.22, green: 0.38, blue: 0.72)
    static let meshEdge = Color(red: 0.18, green: 0.32, blue: 0.62).opacity(0.85)
    static let cyan = Color(red: 0.0, green: 0.90, blue: 1.0)
    static let green = Color(red: 0.49, green: 1.0, blue: 0.42)
    static let purple = Color(red: 0.62, green: 0.36, blue: 0.95)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.28)
    static let magenta = Color(red: 0.95, green: 0.35, blue: 0.72)
}

/// Path tint for the adaptive mesh — used in chat by selected / reply model.
enum ARILMeshStyle: String, CaseIterable, Identifiable {
    case fullColor
    case cyan
    case green
    case purple
    case monoLight
    case monoDark

    var id: String { rawValue }

    var pathStart: Color {
        switch self {
        case .fullColor: return ARILLogoPalette.cyan
        case .cyan: return ARILLogoPalette.cyan
        case .green: return ARILLogoPalette.green
        case .purple: return ARILLogoPalette.purple
        case .monoLight: return Color.white
        case .monoDark: return Color(white: 0.28)
        }
    }

    var pathEnd: Color {
        switch self {
        case .fullColor: return ARILLogoPalette.green
        case .cyan: return Color(red: 0.25, green: 0.78, blue: 1.0)
        case .green: return Color(red: 0.35, green: 0.92, blue: 0.30)
        case .purple: return Color(red: 0.78, green: 0.45, blue: 1.0)
        case .monoLight: return Color(white: 0.92)
        case .monoDark: return Color(white: 0.18)
        }
    }

    /// Primary accent for spinners / status tinting.
    var accent: Color { pathStart }

    /// Map an OpenRouter-style model id (or leaf name) to a mesh style variant.
    static func forModel(_ modelId: String?) -> ARILMeshStyle {
        guard let raw = modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .fullColor
        }
        let id = raw.lowercased()
        let provider = id.split(separator: "/").first.map(String.init) ?? id

        if provider.contains("anthropic") || id.contains("claude") { return .purple }
        if provider.contains("google") || id.contains("gemini") { return .green }
        if provider.contains("meta") || id.contains("llama") { return .green }
        if provider.contains("openai") || id.contains("gpt") || id.contains("o1") || id.contains("o3") || id.contains("o4") {
            return .cyan
        }
        if provider.contains("x-ai") || provider.contains("xai") || id.contains("grok") { return .cyan }
        if provider.contains("deepseek") { return .cyan }
        if provider.contains("mistral") || provider.contains("qwen") { return .purple }
        if provider.contains("cohere") || provider.contains("perplexity") { return .monoLight }
        if id.contains("ollama") || provider.contains("local") { return .monoDark }

        // Stable fallback so unknown providers still get a consistent tint.
        let variants: [ARILMeshStyle] = [.cyan, .green, .purple, .fullColor]
        let hash = abs(id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return variants[hash % variants.count]
    }
}

/// Raster app mark from Assets (`ARILMark`) — full icon tile for hero / About / title.
struct ARILLogoImage: View {
    var size: CGFloat = 28
    var cornerRadius: CGFloat? = nil

    var body: some View {
        Image("ARILMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.22, style: .continuous))
            .accessibilityLabel("ARIL")
    }
}

/// Cyan/white wordmark from Assets (`ARILWordmark`) — replaces typographic “ARIL” on the empty hero.
struct ARILWordmarkImage: View {
    var height: CGFloat = 44

    var body: some View {
        Image("ARILWordmark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
            .accessibilityLabel("ARIL")
    }
}

/// Vector adaptive mesh: candidate nodes + highlighted best path (input → selected).
struct ARILMeshMark: View {
    var style: ARILMeshStyle = .fullColor
    var showsBackground: Bool = false

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let r = s * 0.42

            if showsBackground {
                let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: s * 0.22, style: .continuous)
                context.fill(bg, with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.06, green: 0.10, blue: 0.22),
                        Color(red: 0.02, green: 0.03, blue: 0.08)
                    ]),
                    startPoint: CGPoint(x: cx, y: 0),
                    endPoint: CGPoint(x: cx, y: size.height)
                ))
            }

            let nodes = Self.meshNodes(center: CGPoint(x: cx, y: cy), radius: r)
            let edges = Self.meshEdges

            // Base mesh edges
            for (a, b) in edges {
                var path = Path()
                path.move(to: nodes[a])
                path.addLine(to: nodes[b])
                context.stroke(
                    path,
                    with: .color(ARILLogoPalette.meshEdge),
                    style: StrokeStyle(lineWidth: max(0.6, s * 0.012), lineCap: .round)
                )
            }

            // Candidate nodes
            let nodeR = max(1.2, s * 0.028)
            for p in nodes {
                let rect = CGRect(x: p.x - nodeR, y: p.y - nodeR, width: nodeR * 2, height: nodeR * 2)
                context.fill(Path(ellipseIn: rect), with: .color(ARILLogoPalette.meshNode))
            }

            // Best path indices through the mesh (left → right)
            let pathIdx = [0, 3, 7, 11, 15, 18]
            let pathPts = pathIdx.map { nodes[$0] }
            let input = CGPoint(x: cx - r * 1.08, y: cy)
            let selected = CGPoint(x: cx + r * 1.05, y: cy)

            // Soft glow under path
            var glow = Path()
            glow.move(to: input)
            for p in pathPts { glow.addLine(to: p) }
            glow.addLine(to: selected)
            context.stroke(
                glow,
                with: .color(style.pathStart.opacity(0.35)),
                style: StrokeStyle(lineWidth: max(2.5, s * 0.055), lineCap: .round, lineJoin: .round)
            )

            // Gradient path segments
            let allPts = [input] + pathPts + [selected]
            for i in 0..<(allPts.count - 1) {
                let t0 = CGFloat(i) / CGFloat(allPts.count - 1)
                let t1 = CGFloat(i + 1) / CGFloat(allPts.count - 1)
                let c0 = Self.lerp(style.pathStart, style.pathEnd, t0)
                let c1 = Self.lerp(style.pathStart, style.pathEnd, t1)
                var seg = Path()
                seg.move(to: allPts[i])
                seg.addLine(to: allPts[i + 1])
                context.stroke(
                    seg,
                    with: .linearGradient(
                        Gradient(colors: [c0, c1]),
                        startPoint: allPts[i],
                        endPoint: allPts[i + 1]
                    ),
                    style: StrokeStyle(lineWidth: max(1.4, s * 0.028), lineCap: .round)
                )
            }

            // Path nodes
            for (i, p) in pathPts.enumerated() {
                let t = CGFloat(i + 1) / CGFloat(pathPts.count + 1)
                let c = Self.lerp(style.pathStart, style.pathEnd, t)
                let pr = max(1.6, s * 0.036)
                let rect = CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2)
                context.fill(Path(ellipseIn: rect), with: .color(c))
            }

            // Input ring (hollow)
            let inR = max(2.2, s * 0.045)
            let inRect = CGRect(x: input.x - inR, y: input.y - inR, width: inR * 2, height: inR * 2)
            context.stroke(
                Path(ellipseIn: inRect),
                with: .color(.white),
                style: StrokeStyle(lineWidth: max(1.2, s * 0.022))
            )

            // Selected model node (filled + ring)
            let outR = max(2.8, s * 0.055)
            let halo = CGRect(x: selected.x - outR * 1.55, y: selected.y - outR * 1.55, width: outR * 3.1, height: outR * 3.1)
            context.fill(Path(ellipseIn: halo), with: .color(style.pathEnd.opacity(0.28)))
            let outOuter = CGRect(x: selected.x - outR, y: selected.y - outR, width: outR * 2, height: outR * 2)
            context.stroke(
                Path(ellipseIn: outOuter),
                with: .color(style.pathEnd),
                style: StrokeStyle(lineWidth: max(1.4, s * 0.025))
            )
            let coreR = outR * 0.45
            let core = CGRect(x: selected.x - coreR, y: selected.y - coreR, width: coreR * 2, height: coreR * 2)
            context.fill(Path(ellipseIn: core), with: .color(.white))
        }
        .accessibilityLabel("ARIL")
    }

    /// Fibonacci-ish sphere projection → flat circle of candidate nodes.
    private static func meshNodes(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        // Fixed layout tuned for left→right “best path” readability at small sizes.
        let coords: [(CGFloat, CGFloat)] = [
            (-0.92, 0.00), (-0.72, -0.42), (-0.72, 0.42),
            (-0.55, 0.00), (-0.48, -0.68), (-0.48, 0.68),
            (-0.28, -0.35), (-0.28, 0.35), (-0.18, -0.82), (-0.18, 0.82),
            (-0.05, 0.00), (0.08, -0.55), (0.08, 0.55),
            (0.22, -0.28), (0.22, 0.28), (0.35, 0.00),
            (0.48, -0.62), (0.48, 0.62), (0.62, 0.00),
            (0.72, -0.38), (0.72, 0.38), (0.88, 0.00)
        ]
        return coords.map { CGPoint(x: center.x + $0.0 * radius, y: center.y + $0.1 * radius) }
    }

    private static let meshEdges: [(Int, Int)] = [
        (0, 1), (0, 2), (0, 3),
        (1, 3), (1, 4), (1, 6),
        (2, 3), (2, 5), (2, 7),
        (3, 6), (3, 7), (3, 10),
        (4, 6), (4, 8),
        (5, 7), (5, 9),
        (6, 10), (6, 11),
        (7, 10), (7, 12),
        (8, 11), (9, 12),
        (10, 11), (10, 12), (10, 13), (10, 14), (10, 15),
        (11, 13), (11, 16),
        (12, 14), (12, 17),
        (13, 15), (13, 16), (13, 19),
        (14, 15), (14, 17), (14, 20),
        (15, 18), (15, 19), (15, 20),
        (16, 19), (17, 20),
        (18, 19), (18, 20), (18, 21),
        (19, 21), (20, 21)
    ]

    private static func lerp(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
        let t = max(0, min(1, t))
        #if canImport(AppKit)
        let nsA = NSColor(a)
        let nsB = NSColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        nsA.usingColorSpace(.sRGB)?.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        nsB.usingColorSpace(.sRGB)?.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red: ar + (br - ar) * t,
            green: ag + (bg - ag) * t,
            blue: ab + (bb - ab) * t,
            opacity: aa + (ba - aa) * t
        )
        #else
        return t < 0.5 ? a : b
        #endif
    }
}

/// Vector mark matching the adaptive mesh identity (no tile).
struct ARILLogoMark: View {
    var style: ARILMeshStyle = .fullColor
    /// Legacy parameters kept so older call sites still compile.
    var gold: Color = ARILLogoPalette.gold
    var olive: Color = ARILLogoPalette.olive

    var body: some View {
        ARILMeshMark(style: style, showsBackground: false)
    }
}

/// Soft pulse on the mesh path while waiting for a reply.
struct ARILSpinningArrowMark: View {
    var color: Color = ARILLogoPalette.cyan
    var style: ARILMeshStyle = .fullColor
    var size: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.72 + 0.28 * sin(t * .pi * 2 / 1.1)
            ARILMeshMark(style: style)
                .opacity(pulse)
                .scaleEffect(0.92 + 0.08 * CGFloat((sin(t * .pi * 2 / 1.1) + 1) / 2))
                .frame(width: size, height: size)
        }
        .accessibilityLabel("Waiting")
    }
}

/// Assistant-row mark: mesh tinted by model style, pulses while waiting / streaming.
struct ARILLogoAvatar: View {
    var animated: Bool
    var style: ARILMeshStyle = .fullColor
    var color: Color = ARILLogoPalette.cyan
    var size: CGFloat = 28

    var body: some View {
        Group {
            if animated {
                ARILSpinningArrowMark(color: style.accent, style: style, size: size)
            } else {
                ARILMeshMark(style: style)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size + (animated ? 2 : 0), height: size + (animated ? 2 : 0))
    }
}

// MARK: - Compatibility aliases (previous ghost identity)

typealias ARILGhostMark = ARILLogoMark
typealias ARILGhostAvatar = ARILLogoAvatar
