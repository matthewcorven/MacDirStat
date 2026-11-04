import SwiftUI

/// Persistent legend that makes linked git worktrees easy to spot and shows
/// their combined size separately from the rest of the scan.
struct WorktreeSummaryBadge: View {
    let count: Int
    let totalSize: Int64

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(GitWorktreeStyle.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(GitWorktreeStyle.legendTitle)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(GitWorktreeStyle.legendTitle): \(detail)")
        .allowsHitTesting(false)
    }

    private var detail: String {
        if count == 0 { return "None detected" }
        return "\(count.formatted()) worktree\(count == 1 ? "" : "s") · \(ByteFormatter.string(from: totalSize))"
    }
}
