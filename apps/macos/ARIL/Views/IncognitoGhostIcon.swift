import SwiftUI

/// Compact ghost glyph for Incognito. SF Symbol `ghost` is not available on macOS.
struct IncognitoGhostIcon: View {
    var body: some View {
        IncognitoGhostShape()
            .fill(style: FillStyle(eoFill: true))
            .aspectRatio(0.78, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

private struct IncognitoGhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()

        // Dome head + body.
        path.move(to: CGPoint(x: w * 0.14, y: h * 0.42))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.86, y: h * 0.42),
            control: CGPoint(x: w * 0.50, y: h * -0.02)
        )
        path.addLine(to: CGPoint(x: w * 0.86, y: h * 0.76))

        // Wavy hem (3 scallops).
        path.addQuadCurve(
            to: CGPoint(x: w * 0.69, y: h * 0.76),
            control: CGPoint(x: w * 0.775, y: h * 0.98)
        )
        path.addQuadCurve(
            to: CGPoint(x: w * 0.50, y: h * 0.76),
            control: CGPoint(x: w * 0.595, y: h * 0.56)
        )
        path.addQuadCurve(
            to: CGPoint(x: w * 0.31, y: h * 0.76),
            control: CGPoint(x: w * 0.405, y: h * 0.98)
        )
        path.addQuadCurve(
            to: CGPoint(x: w * 0.14, y: h * 0.76),
            control: CGPoint(x: w * 0.225, y: h * 0.56)
        )
        path.closeSubpath()

        // Eye cutouts via even-odd fill.
        let eyeY = h * 0.36
        let eyeR = min(w, h) * 0.08
        path.addEllipse(in: CGRect(
            x: w * 0.33 - eyeR,
            y: eyeY - eyeR,
            width: eyeR * 2,
            height: eyeR * 2
        ))
        path.addEllipse(in: CGRect(
            x: w * 0.67 - eyeR,
            y: eyeY - eyeR,
            width: eyeR * 2,
            height: eyeR * 2
        ))

        return path
    }
}
