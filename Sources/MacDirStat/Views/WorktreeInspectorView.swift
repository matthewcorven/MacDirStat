import SwiftUI

/// Sheet listing every worktree with the facts needed to decide whether to
/// delete it, a stale-and-clean filter, and a one-click prune for registrations
/// whose folder is gone.
struct WorktreeInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState

    @State private var pendingDelete: WorktreeRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 440)
        .confirmationDialog(
            "Move “\(pendingDelete?.name ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { record in
            Button("Move to Trash", role: .destructive) {
                state.deleteWorktree(recordPath: record.path)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { record in
            Text(record.isPrunable
                 ? "This only removes git's registration; the folder is already gone."
                 : "The worktree is clean, so no uncommitted work will be lost.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(GitWorktreeStyle.legendTitle, systemImage: GitWorktreeStyle.sfSymbol)
                    .font(.title3.bold())
                if state.isAnalyzingWorktrees {
                    ProgressView().controlSize(.small)
                    Text("Checking with git…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                Picker("Filter", selection: $state.worktreeFilter) {
                    ForEach(WorktreeFilter.allCases) { filter in
                        Text(label(for: filter)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
        }
        .padding(16)
    }

    private var list: some View {
        Group {
            if state.worktreeRecords.isEmpty && !state.isAnalyzingWorktrees {
                ContentUnavailableView(
                    "No Worktrees",
                    systemImage: GitWorktreeStyle.sfSymbol,
                    description: Text("This scan didn't find linked git worktrees.")
                )
            } else if state.visibleWorktreeRecords.isEmpty && !state.isAnalyzingWorktrees {
                ContentUnavailableView(
                    "Nothing Matches",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No worktrees in the “\(state.worktreeFilter.rawValue)” filter.")
                )
            } else {
                List {
                    if state.scanUnreadableFolderCount > 0 {
                        unreadableBanner
                    }
                    ForEach(state.visibleWorktreeRecords) { record in
                        WorktreeRow(
                            record: record,
                            size: state.worktreeSizesByPath[record.path],
                            staleThreshold: WorktreeSettings.staleThreshold
                        )
                        .contextMenu { menu(for: record) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func menu(for record: WorktreeRecord) -> some View {
        if state.worktreeNode(for: record.path) != nil {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(record.path, inFileViewerRootedAtPath: "")
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.path, forType: .string)
            }
            Divider()
        }
        if record.isSafeToDelete {
            Button("Move to Trash…", role: .destructive) { pendingDelete = record }
        } else if record.isClean == false {
            Text("Delete blocked: uncommitted changes")
            Button("Delete Immediately…", role: .destructive) {
                state.deleteWorktree(recordPath: record.path, skipTrash: true)
            }
        }
    }

    private var unreadableBanner: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.scanUnreadableFolderCount.formatted()) folders unreadable, worktrees there may be missed")
                    .font(.caption)
                if !state.scanHadFullDiskAccess {
                    Text("Grant Full Disk Access in Settings › Scanning to include protected folders.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    private var footer: some View {
        HStack {
            if state.prunableWorktreeCount > 0 {
                Button {
                    state.pruneOrphanedWorktrees()
                } label: {
                    Label("Prune \(state.prunableWorktreeCount) Missing Worktree\(state.prunableWorktreeCount == 1 ? "" : "s")",
                          systemImage: "scissors")
                }
                .help("Runs git worktree prune for repositories with registrations whose folder is gone")
            }
            Spacer()
            Text("Delete is blocked while a worktree has uncommitted changes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private var summary: String {
        let dirty = state.worktreeRecords.filter { $0.isClean == false }.count
        let prunable = state.prunableWorktreeCount
        var parts = ["\(state.worktreeRecords.count.formatted()) total",
                     "\(state.unusedWorktreeCount) unused"]
        if dirty > 0 { parts.append("\(dirty) dirty") }
        if prunable > 0 { parts.append("\(prunable) prunable") }
        return parts.joined(separator: " · ")
    }

    private func label(for filter: WorktreeFilter) -> String {
        switch filter {
        case .all: "All"
        case .unused: "Stale & Clean (\(state.unusedWorktreeCount))"
        case .dirty: "Needs Attention"
        }
    }
}
