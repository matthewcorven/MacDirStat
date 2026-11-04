import SwiftUI

/// Answers "which worktrees can I delete?" for one worktree: whether it has
/// uncommitted work, when a file last changed, its branch and its size.
struct WorktreeRow: View {
    let record: WorktreeRecord
    let size: Int64?
    let staleThreshold: TimeInterval
    var now = Date()

    private var isUnused: Bool {
        record.isUnusedCandidate(staleThreshold: staleThreshold, now: now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .font(.system(size: 15))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if record.isPrunable {
                        Tag("Prunable", color: .red)
                    } else if isUnused {
                        Tag("Unused", color: .green)
                    }
                    if record.isOrphaned {
                        Tag("Orphaned", color: .red)
                    }
                    if record.isDetached {
                        Tag("Detached", color: .orange)
                    }
                }

                Text(record.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                HStack(spacing: 12) {
                    Label(record.branch ?? (record.isDetached ? "detached HEAD" : "unknown branch"),
                          systemImage: "arrow.triangle.branch")
                    Label(changesDescription, systemImage: record.isClean == false ? "pencil" : "checkmark.circle")
                        .foregroundStyle(record.isClean == false ? .orange : .secondary)
                    Label(lastChangeDescription, systemImage: "clock")
                    if let size {
                        Label(ByteFormatter.string(from: size), systemImage: "internaldrive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if record.isOrphaned {
                    Text("The main repository this worktree belongs to is gone.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if isUnused, let age = unusedReason {
                    Text(age)
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if let note = record.pruneReason ?? record.gitLinkIssue ?? record.scanMissedReason {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name), \(changesDescription), \(lastChangeDescription)")
    }

    /// Explains why the record counts as unused, so the green tag is never a
    /// black box.
    private var unusedReason: String? {
        if record.isDetached {
            return "Detached HEAD with no uncommitted changes"
        }
        guard let latest = record.latestChange else { return nil }
        let days = Int(now.timeIntervalSince(latest) / (24 * 60 * 60))
        return "Clean and unchanged for \(days) days"
    }

    private var statusSymbol: String {
        if record.isOrphaned { return "link.badge.plus" }
        if record.isPrunable { return "questionmark.folder" }
        if record.isClean == false { return "exclamationmark.circle.fill" }
        if isUnused { return "trash.circle" }
        return "arrow.triangle.branch.circle"
    }

    private var statusColor: Color {
        if record.isPrunable || record.isOrphaned { return .red }
        if record.isClean == false { return .orange }
        if isUnused { return .green }
        return .secondary
    }

    private var changesDescription: String {
        if record.isPrunable { return "folder missing" }
        guard let changes = record.uncommittedChanges else { return "changes unknown" }
        return changes == 0 ? "clean" : "uncommitted changes"
    }

    private var lastChangeDescription: String {
        guard let date = record.latestChange else { return "last change unknown" }
        // Ages beyond a year are more useful as a date than as "1y ago", which
        // hides whether it was two or twenty years.
        let age = now.timeIntervalSince(date)
        if age >= 365 * 24 * 60 * 60 {
            return "last changed " + date.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "changed " + formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
