import SwiftUI

/// Brand gold from the ARIL app icon (arrow shaft / head).
enum ARILLogoPalette {
    static let gold = Color(red: 0.922, green: 0.749, blue: 0.357) // #EBBF5B
    static let olive = Color(red: 0.455, green: 0.416, blue: 0.239) // #746A3D
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

/// Vector mark matching the app icon’s converging paths + gold arrow (no black tile).
struct ARILLogoMark: View {
    var gold: Color = ARILLogoPalette.gold
    var olive: Color = ARILLogoPalette.olive

    var body: some View {
        Canvas { context, size in
            let stroke = max(1.5, min(size.width, size.height) * 0.11)
            let inset = stroke * 0.55
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let w = rect.width
            let h = rect.height
            let midY = rect.midY
            let nodeX = rect.minX + w * 0.46
            let nodeR = stroke * 0.95

            var upper = Path()
            upper.move(to: CGPoint(x: rect.minX + stroke * 0.2, y: rect.minY + h * 0.18))
            upper.addQuadCurve(
                to: CGPoint(x: nodeX - nodeR * 0.35, y: midY - stroke * 0.15),
                control: CGPoint(x: rect.minX + w * 0.28, y: midY - h * 0.08)
            )
            context.stroke(
                upper,
                with: .color(olive),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
            )

            var lower = Path()
            lower.move(to: CGPoint(x: rect.minX + stroke * 0.2, y: rect.maxY - h * 0.18))
            lower.addQuadCurve(
                to: CGPoint(x: nodeX - nodeR * 0.35, y: midY + stroke * 0.15),
                control: CGPoint(x: rect.minX + w * 0.28, y: midY + h * 0.08)
            )
            context.stroke(
                lower,
                with: .color(olive),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
            )

            var shaft = Path()
            shaft.move(to: CGPoint(x: rect.minX + w * 0.22, y: midY))
            shaft.addLine(to: CGPoint(x: rect.maxX - w * 0.28, y: midY))
            context.stroke(
                shaft,
                with: .color(gold),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round)
            )

            let nodeRect = CGRect(x: nodeX - nodeR, y: midY - nodeR, width: nodeR * 2, height: nodeR * 2)
            context.fill(Path(ellipseIn: nodeRect), with: .color(gold))
            let holeR = nodeR * 0.38
            let hole = CGRect(x: nodeX - holeR, y: midY - holeR, width: holeR * 2, height: holeR * 2)
            context.fill(Path(ellipseIn: hole), with: .color(.black.opacity(0.92)))

            let tipX = rect.maxX - stroke * 0.15
            let baseX = rect.maxX - w * 0.26
            var head = Path()
            head.move(to: CGPoint(x: tipX, y: midY))
            head.addLine(to: CGPoint(x: baseX, y: midY - stroke * 1.15))
            head.addLine(to: CGPoint(x: baseX, y: midY + stroke * 1.15))
            head.closeSubpath()
            context.fill(head, with: .color(gold))
        }
        .accessibilityLabel("ARIL")
    }
}

/// Circular gold arrow (thick stroke + triangular head, logo style) while waiting for a reply.
struct ARILSpinningArrowMark: View {
    var color: Color = ARILLogoPalette.gold
    var size: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let degrees = (t.truncatingRemainder(dividingBy: 1.05) / 1.05) * 360
            Canvas { context, canvasSize in
                let stroke = max(1.8, min(canvasSize.width, canvasSize.height) * 0.145)
                let inset = stroke * 0.85
                let r = min(canvasSize.width, canvasSize.height) / 2 - inset
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

                var arc = Path()
                arc.addArc(
                    center: center,
                    radius: r,
                    startAngle: .degrees(-25),
                    endAngle: .degrees(250),
                    clockwise: false
                )
                context.stroke(
                    arc,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )

                // Hub node (matches logo hinge)
                let hubR = stroke * 0.55
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2)),
                    with: .color(color)
                )
                let holeR = hubR * 0.4
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - holeR, y: center.y - holeR, width: holeR * 2, height: holeR * 2)),
                    with: .color(.black.opacity(0.85))
                )

                // Arrowhead at arc end (~250°)
                let endAngle = Angle.degrees(250)
                let tip = CGPoint(
                    x: center.x + r * CGFloat(Foundation.cos(endAngle.radians)),
                    y: center.y + r * CGFloat(Foundation.sin(endAngle.radians))
                )
                let tangent = endAngle.radians + .pi / 2
                let headLen = stroke * 1.7
                let headHalf = stroke * 1.05
                let back = CGPoint(
                    x: tip.x - headLen * CGFloat(Foundation.cos(tangent)),
                    y: tip.y - headLen * CGFloat(Foundation.sin(tangent))
                )
                let left = CGPoint(
                    x: back.x + headHalf * CGFloat(Foundation.cos(tangent + .pi / 2)),
                    y: back.y + headHalf * CGFloat(Foundation.sin(tangent + .pi / 2))
                )
                let right = CGPoint(
                    x: back.x + headHalf * CGFloat(Foundation.cos(tangent - .pi / 2)),
                    y: back.y + headHalf * CGFloat(Foundation.sin(tangent - .pi / 2))
                )
                var head = Path()
                head.move(to: tip)
                head.addLine(to: left)
                head.addLine(to: right)
                head.closeSubpath()
                context.fill(head, with: .color(color))
            }
            .rotationEffect(.degrees(degrees))
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Waiting")
    }
}

/// Assistant-row mark: static logo tile, or spinning gold arrow while waiting / streaming.
struct ARILLogoAvatar: View {
    var animated: Bool
    var color: Color = ARILLogoPalette.gold
    var size: CGFloat = 28

    var body: some View {
        Group {
            if animated {
                ARILSpinningArrowMark(color: color, size: size)
            } else {
                ARILLogoImage(size: size)
            }
        }
        .frame(width: size + (animated ? 2 : 0), height: size + (animated ? 2 : 0))
    }
}

// MARK: - Compatibility aliases (previous ghost identity)

typealias ARILGhostMark = ARILLogoMark
typealias ARILGhostAvatar = ARILLogoAvatar
