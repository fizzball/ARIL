import SwiftUI

struct CompareResultsView: View {
    let results: [CompareResultDTO]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(short(result.model))
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(ARILTheme.gold)
                            Spacer()
                            if result.cached {
                                Text("CACHE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(ARILTheme.gold)
                            }
                        }
                        Text("\(result.latencyMs)ms · $\(String(format: "%.4f", result.costUsd))")
                            .font(ARILTheme.captionFont)
                            .foregroundStyle(ARILTheme.creamMuted)
                        if let err = result.error {
                            Text(err)
                                .font(ARILTheme.captionFont)
                                .foregroundStyle(ARILTheme.danger)
                        } else {
                            Text(result.content)
                                .font(ARILTheme.bodyFont)
                                .foregroundStyle(ARILTheme.cream)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .frame(width: 320, alignment: .topLeading)
                    .background(ARILTheme.backgroundElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ARILTheme.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
        }
    }

    private func short(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
