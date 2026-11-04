import SwiftUI

/// Legend badge that now doubles as the entry point to the worktree list.
struct WorktreeSummaryBadge: View {
    let count: Int
    let totalSize: Int64
    let unusedCount: Int
    let prunableCount: Int
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
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

                if unusedCount > 0 || prunableCount > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(GitWorktreeStyle.legendTitle): \(detail)")
        .help("Show each worktree's branch, uncommitted changes, last change and size")
    }

    private var detail: String {
        if count == 0 { return "None detected" }
        var parts = ["\(count.formatted()) worktree\(count == 1 ? "" : "s")",
                     ByteFormatter.string(from: totalSize)]
        if unusedCount > 0 { parts.append("\(unusedCount) unused") }
        if prunableCount > 0 { parts.append("\(prunableCount) prunable") }
        return parts.joined(separator: " · ")
    }
}
