import SwiftUI

/// Sheet listing every worktree with the facts needed to decide whether to
/// delete it, a stale-and-clean filter, and a one-click prune for registrations
/// whose folder is gone.
struct WorktreeInspectorView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var state: AppState

    @State private var selection: Set<String> = []
    /// Anchor for Shift-click range selection.
    @State private var selectionAnchor: String?
    @State private var pendingBatchDelete: [WorktreeRecord] = []
    @State private var pendingBatchImmediate: [WorktreeRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        // Minimums only: the window is user-resizable, and the list scrolls
        // inside whatever height it is given.
        .frame(minWidth: 640, idealWidth: 780, minHeight: 360, idealHeight: 560)
        .confirmationDialog(
            batchTitle(toTrash: true),
            isPresented: Binding(
                get: { !pendingBatchDelete.isEmpty },
                set: { if !$0 { pendingBatchDelete = [] } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                let paths = pendingBatchDelete.map(\.path)
                pendingBatchDelete = []
                selection = []
                Task { await state.deleteWorktrees(paths: paths, allowDirty: false) }
            }
            Button("Cancel", role: .cancel) { pendingBatchDelete = [] }
        } message: {
            Text("Clean worktrees are moved to the Trash. Anything with uncommitted changes is left alone and reported.")
        }
        .confirmationDialog(
            batchTitle(toTrash: false),
            isPresented: Binding(
                get: { !pendingBatchImmediate.isEmpty },
                set: { if !$0 { pendingBatchImmediate = [] } }
            )
        ) {
            Button("Delete Immediately", role: .destructive) {
                let paths = pendingBatchImmediate.map(\.path)
                pendingBatchImmediate = []
                selection = []
                Task { await state.deleteWorktrees(paths: paths, allowDirty: true) }
            }
            Button("Cancel", role: .cancel) { pendingBatchImmediate = [] }
        } message: {
            Text("These folders are deleted outright and cannot be undone, including any uncommitted changes inside them.")
        }
        .worktreeDeletionAlert(state: state)
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
                Button("Close") { dismissWindow(id: WorktreeReportWindow.id) }
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
                List(selection: $selection) {
                    if state.scanUnreadableFolderCount > 0 {
                        unreadableBanner
                    }
                    ForEach(state.visibleWorktreeRecords) { record in
                        WorktreeRow(
                            record: record,
                            size: state.worktreeSizesByPath[record.path],
                            staleThreshold: WorktreeSettings.staleThreshold
                        )
                        .tag(record.path)
                        .contextMenu { menu(for: record) }
                        // SwiftUI's List only tracks the clicked row; handle
                        // Shift (contiguous) and Command (toggle) ourselves so
                        // the usual macOS pattern works here too.
                        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
                            extendSelection(to: record)
                        })
                        .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                            toggleSelection(record)
                        })
                        .simultaneousGesture(TapGesture().onEnded {
                            selectSingle(record)
                        })
                    }
                }
                .listStyle(.inset)
                .onChange(of: state.worktreeFilter) {
                    // Paths in the new filter may not include the old selection.
                    selection = selection.intersection(
                        Set(state.visibleWorktreeRecords.map(\.path)))
                    selectionAnchor = nil
                }
                // Take all remaining height so a long list scrolls here rather
                // than pushing the footer out of the window.
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for record: WorktreeRecord) -> some View {
        // Always available, whether or not the scan reached this folder and
        // whatever the git state is: revealing and copying neither reads nor
        // changes the worktree.
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(record.path, inFileViewerRootedAtPath: "")
        }
        .disabled(!record.canRevealInFinder)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.path, forType: .string)
        }
        Divider()
        // Act on the whole selection when the clicked row is part of it, which
        // is what makes a multi-row selection useful.
        let targets = pendingTargets(for: record)
        let isBatch = targets.count > 1
        if targets.allSatisfy(\.isSafeToDelete) {
            Button(isBatch ? "Move \(targets.count) to Trash…" : "Move to Trash…",
                   role: .destructive) {
                pendingBatchDelete = targets
            }
        }
        if targets.contains(where: { $0.isClean == false }) || !targets.allSatisfy(\.isSafeToDelete) {
            if !isBatch {
                Text("This worktree has uncommitted changes")
            }
            Button(isBatch ? "Delete \(targets.count) Immediately…" : "Delete Immediately…",
                   role: .destructive) {
                pendingBatchImmediate = targets
            }
        }
    }

    /// The rows an action applies to: the current selection when the row is part
    /// of it, otherwise just that row.
    private func pendingTargets(for record: WorktreeRecord) -> [WorktreeRecord] {
        if selection.contains(record.path), selectedRecords.count > 1 {
            return selectedRecords
        }
        return [record]
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
            if selection.count > 1 {
                Button(role: .destructive) {
                    pendingBatchDelete = selectedRecords
                } label: {
                    Label("Move \(selection.count) to Trash", systemImage: "trash")
                }
                .help("Moves the selected clean worktrees to the Trash; dirty ones are left and reported")

                Button(role: .destructive) {
                    pendingBatchImmediate = selectedRecords
                } label: {
                    Label("Delete \(selection.count) Immediately…", systemImage: "trash.slash")
                }
                .help("Deletes the selected worktrees outright, including uncommitted changes")
            }
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
            if selection.count > 1 {
                Text("\(selection.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Shift-click selects a range, Command-click toggles.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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

    // MARK: - Selection

    private var selectedRecords: [WorktreeRecord] {
        state.visibleWorktreeRecords.filter { selection.contains($0.path) }
    }

    private func selectSingle(_ record: WorktreeRecord) {
        selection = [record.path]
        selectionAnchor = record.path
    }

    private func toggleSelection(_ record: WorktreeRecord) {
        if selection.contains(record.path) {
            selection.remove(record.path)
        } else {
            selection.insert(record.path)
            selectionAnchor = record.path
        }
    }

    /// Shift-click: select everything between the anchor and this row.
    private func extendSelection(to record: WorktreeRecord) {
        let rows = state.visibleWorktreeRecords.map(\.path)
        guard let anchor = selectionAnchor,
              let start = rows.firstIndex(of: anchor),
              let end = rows.firstIndex(of: record.path) else {
            selection = [record.path]
            selectionAnchor = record.path
            return
        }
        let range = start <= end ? start...end : end...start
        selection = Set(rows[range])
    }

    private func batchTitle(toTrash: Bool) -> String {
        let records = toTrash ? pendingBatchDelete : pendingBatchImmediate
        if records.count == 1 {
            let name = records[0].name
            return toTrash ? "Move “\(name)” to the Trash?" : "Delete “\(name)” immediately?"
        }
        return toTrash
            ? "Move \(records.count) worktrees to the Trash?"
            : "Delete \(records.count) worktrees immediately?"
    }

    private func label(for filter: WorktreeFilter) -> String {
        switch filter {
        case .all: "All"
        case .unused: "Stale & Clean (\(state.unusedWorktreeCount))"
        case .dirty: "Needs Attention"
        }
    }
}
