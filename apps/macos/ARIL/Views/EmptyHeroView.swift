import SwiftUI

struct EmptyHeroView: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("ARIL")
                .font(ARILTheme.wordmarkFont)
                .foregroundStyle(ARILTheme.cream)
                .tracking(4)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

            Text("Adaptive Routing Intelligent Layer")
                .font(ARILTheme.captionFont)
                .foregroundStyle(ARILTheme.gold)
                .opacity(appeared ? 1 : 0)

            Text("Enter task. ARIL grades the prompt, routes the model, and estimates cost before you send.")
                .font(ARILTheme.bodyFont)
                .foregroundStyle(ARILTheme.creamMuted)
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
