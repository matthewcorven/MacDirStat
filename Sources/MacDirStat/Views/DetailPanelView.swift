import SwiftUI

struct DetailPanelView: View {
    let node: FileNode
    let sizeMetric: SizeMetric
    var onDeleteWorktree: ((FileNode, Bool) -> Void)?

    /// The worktree containing this node, or the node itself.
    private var worktreeRoot: FileNode? {
        var current: FileNode? = node
        while let candidate = current {
            if candidate.isGitWorktree { return candidate }
            current = candidate.parent
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: node.isGitWorktree
                          ? GitWorktreeStyle.sfSymbol
                          : (node.isDirectory ? "folder.fill" : node.category.sfSymbol))
                        .font(.title2)
                        .foregroundStyle(node.isGitWorktree ? GitWorktreeStyle.color : node.category.color)

                    VStack(alignment: .leading) {
                        Text(node.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(node.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Divider()

                // Size info
                LabeledContent("File Size", value: ByteFormatter.string(from: node.totalSize))
                LabeledContent("Allocated", value: ByteFormatter.string(from: node.totalAllocatedSize))

                if node.isDirectory {
                    LabeledContent("Files", value: "\(node.fileCount.formatted())")
                    LabeledContent("Directories", value: "\(node.directoryCount.formatted())")
                }

                if let worktree = worktreeRoot {
                    Label(worktree === node
                          ? "Linked git worktree"
                          : "Inside worktree \(worktree.name)",
                          systemImage: GitWorktreeStyle.sfSymbol)
                        .font(.caption)
                        .foregroundStyle(GitWorktreeStyle.color)
                }

                if node.isDataless {
                    Label("Cloud-only: contents are not stored locally", systemImage: "icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if node.cloudOnlyFileCount > 0 {
                    LabeledContent("Cloud-only files", value: node.cloudOnlyFileCount.formatted())
                }
                if let issue = node.scanIssue {
                    Label(
                        node.scanIssueCountsAsIncomplete ? "Contents not included" : "Contents not included (expected)",
                        systemImage: node.scanIssueCountsAsIncomplete ? "exclamationmark.triangle" : "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(node.scanIssueCountsAsIncomplete ? .orange : .secondary)
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if node.unscannedDirectoryCount > 0 {
                    Label("Incomplete scan", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("\(node.unscannedDirectoryCount.formatted()) folder\(node.unscannedDirectoryCount == 1 ? "" : "s") could not be read because macOS blocked access. Totals include only accessible metadata.")
                        .font(.caption)
                }
                if node.totalUnavailableEntryCount > 0 {
                    Text("\(node.totalUnavailableEntryCount.formatted()) entr\(node.totalUnavailableEntryCount == 1 ? "y" : "ies") were skipped while listing folders.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if node.expectedUnreadableDirectoryCount > 0 {
                    Label("\(node.expectedUnreadableDirectoryCount.formatted()) folder\(node.expectedUnreadableDirectoryCount == 1 ? "" : "s") readable only by their owner", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let date = node.modificationDate {
                    LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .shortened))
                }

                if node.isDirectory {
                    Divider()

                    // Category breakdown
                    Text("Category Breakdown")
                        .font(.headline)

                    let breakdown = node.categoryBreakdown(metric: sizeMetric)
                    let total = max(1, breakdown.reduce(0) { $0 + $1.size })

                    // Bar chart
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                ForEach(breakdown, id: \.category) { item in
                                    let fraction = CGFloat(item.size) / CGFloat(total)
                                    if fraction > 0.005 {
                                        Rectangle()
                                            .fill(item.category.color)
                                            .frame(width: geo.size.width * fraction)
                                    }
                                }
                            }
                        }
                        .frame(height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    // Legend
                    ForEach(breakdown, id: \.category) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(item.category.color)
                                .frame(width: 10, height: 10)
                            Image(systemName: item.category.sfSymbol)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            Text(item.category.displayName)
                            Spacer()
                            Text(ByteFormatter.string(from: item.size))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                Divider()

                // Actions
                Button {
                    NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)

                if let worktree = worktreeRoot, let onDeleteWorktree {
                    Button {
                        onDeleteWorktree(worktree, false)
                    } label: {
                        Label(worktree === node
                              ? "Move Worktree to Trash"
                              : "Move Worktree \(worktree.name) to Trash",
                              systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Deletes the whole worktree, not just this folder. Refused while it has uncommitted changes.")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}
