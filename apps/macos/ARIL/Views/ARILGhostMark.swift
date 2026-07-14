import SwiftUI

/// Hollow outline ghost mark used as the ARIL identity.
struct ARILGhostMark: View {
    var color: Color = Color(red: 0.78, green: 0.66, blue: 0.42)
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            let inset = lineWidth
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let w = rect.width
            let h = rect.height
            let x = rect.minX
            let y = rect.minY

            // Body silhouette — rounded head, scalloped hem
            var body = Path()
            body.move(to: CGPoint(x: x + w * 0.18, y: y + h * 0.42))
            body.addQuadCurve(
                to: CGPoint(x: x + w * 0.82, y: y + h * 0.42),
                control: CGPoint(x: x + w * 0.50, y: y - h * 0.02)
            )
            body.addLine(to: CGPoint(x: x + w * 0.82, y: y + h * 0.72))
            // Right scallop
            body.addQuadCurve(
                to: CGPoint(x: x + w * 0.66, y: y + h * 0.78),
                control: CGPoint(x: x + w * 0.82, y: y + h * 0.90)
            )
            // Middle scallop
            body.addQuadCurve(
                to: CGPoint(x: x + w * 0.34, y: y + h * 0.78),
                control: CGPoint(x: x + w * 0.50, y: y + h * 0.98)
            )
            // Left scallop
            body.addQuadCurve(
                to: CGPoint(x: x + w * 0.18, y: y + h * 0.72),
                control: CGPoint(x: x + w * 0.18, y: y + h * 0.90)
            )
            body.closeSubpath()

            context.stroke(
                body,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )

            // Hollow eyes
            let eyeW = w * 0.14
            let eyeH = h * 0.16
            let eyeY = y + h * 0.34
            let leftEye = Path(ellipseIn: CGRect(x: x + w * 0.30, y: eyeY, width: eyeW, height: eyeH))
            let rightEye = Path(ellipseIn: CGRect(x: x + w * 0.56, y: eyeY, width: eyeW, height: eyeH))
            context.stroke(leftEye, with: .color(color), lineWidth: lineWidth * 0.9)
            context.stroke(rightEye, with: .color(color), lineWidth: lineWidth * 0.9)

            // Hollow mouth
            let mouth = Path(
                ellipseIn: CGRect(
                    x: x + w * 0.42,
                    y: y + h * 0.52,
                    width: w * 0.16,
                    height: h * 0.10
                )
            )
            context.stroke(mouth, with: .color(color), lineWidth: lineWidth * 0.85)
        }
        .accessibilityLabel("ARIL")
    }
}

/// Levitating hollow ghost used while waiting for / streaming an agent reply.
struct ARILGhostAvatar: View {
    var animated: Bool
    var color: Color
    var size: CGFloat = 28

    var body: some View {
        // Separate view identities so repeatForever cannot leak after send ends.
        Group {
            if animated {
                LevitatingGhost(color: color, size: size)
            } else {
                ARILGhostMark(color: color, lineWidth: max(1.2, size * 0.055))
                    .frame(width: size, height: size)
            }
        }
        // Keep frame tight so the mark can sit on the same baseline as the "ARIL" caption.
        .frame(width: size + (animated ? 6 : 0), height: size + (animated ? 6 : 0))
    }
}

private struct LevitatingGhost: View {
    var color: Color
    var size: CGFloat
    @State private var phase = false

    var body: some View {
        ARILGhostMark(color: color, lineWidth: max(1.2, size * 0.055))
            .frame(width: size, height: size)
            .offset(x: phase ? 3 : -3, y: phase ? -4 : 2)
            .opacity(0.95)
            .onAppear {
                phase = false
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    phase = true
                }
            }
            .onDisappear {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { phase = false }
            }
    }
}
