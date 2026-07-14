import SwiftUI

struct EmptyHeroView: View {
    @EnvironmentObject private var theme: ThemeStore
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image("ARILMark")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.92)

            Text("ARIL")
                .font(ARILTheme.wordmarkFont)
                .foregroundStyle(theme.palette.text)
                .tracking(4)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

            Text("Adaptive Routing Intelligence Layer")
                .font(ARILTheme.captionFont)
                .foregroundStyle(theme.palette.accent)
                .opacity(appeared ? 1 : 0)

            Text("Enter task. ARIL grades the prompt, routes the model, and estimates cost before you send.")
                .font(ARILTheme.bodyFont)
                .foregroundStyle(theme.palette.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .opacity(appeared ? 1 : 0)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) {
                appeared = true
            }
        }
    }
}
