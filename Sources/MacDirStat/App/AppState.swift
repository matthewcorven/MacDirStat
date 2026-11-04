import SwiftUI

enum ScanStatus: Equatable {
    case idle
    case scanning(fileCount: Int, byteCount: Int64, currentPath: String)
    case completed
    case error(String)

    static func == (lhs: ScanStatus, rhs: ScanStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.completed, .completed): true
        case let (.scanning(lf, lb, lp), .scanning(rf, rb, rp)):
            lf == rf && lb == rb && lp == rp
        case let (.error(l), .error(r)): l == r
        default: false
        }
    }
}

enum SizeMetric: String, CaseIterable, Sendable {
    case fileSize = "File Size"
    case allocatedSize = "Allocated Size"
}

/// Which worktrees the summary sheet shows.
enum WorktreeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case unused = "Stale & Clean"
    case dirty = "Needs Attention"

    var id: String { rawValue }
}

@Observable
@MainActor
final class AppState {
    var scanStatus: ScanStatus = .idle
    var rootNode: FileNode?
    var treemapRoot: FileNode?
    var selectedNode: FileNode?
    var breadcrumbs: [FileNode] = []
    var sizeMetric: SizeMetric = .allocatedSize
    var showInspector: Bool = true
    /// Persisted user choice; toggling it after a scan rescans (or re-marks) the tree.
    var detectGitWorktrees: Bool = UserDefaults.standard.bool(forKey: AppState.worktreeDefaultsKey) {
        didSet {
            UserDefaults.standard.set(detectGitWorktrees, forKey: Self.worktreeDefaultsKey)
            guard !isScanning, let root = rootNode else { return }
            if detectGitWorktrees {
                GitWorktreeDetector.markWorktrees(in: root)
            } else {
                GitWorktreeDetector.clearWorktreeMarks(in: root)
            }
            refreshDetectedWorktrees()
            let enabled = self.detectGitWorktrees
            let count = self.worktreeCount
            let total = self.worktreeTotalSize
            AppLog.state.notice("Worktree detection toggled: enabled=\(enabled) worktrees=\(count) total=\(AppLog.bytes(total))")
        }
    }
    /// Bumped whenever worktree marks change or a worktree is removed so
    /// computed worktree totals invalidate even though `FileNode` is not observable.
    private(set) var worktreeRevision = 0
    private(set) var worktreeShrinkRevision = 0
    private var detectedWorktrees: [FileNode] = []

    /// Filesystem + git view of every worktree, including prunable registrations
    /// the scan can't see. Populated asynchronously after a scan.
    private(set) var worktreeRecords: [WorktreeRecord] = []
    private(set) var isAnalyzingWorktrees = false
    var worktreeFilter: WorktreeFilter = .all
    /// Set when the last scan couldn't read folders that may have hidden worktrees.
    var scanUnreadableFolderCount: Int = 0
    var scanHadFullDiskAccess: Bool = FullDiskAccess.isGranted
    private var analysisTask: Task<Void, Never>?
    /// Incremented for every analysis request so a slow result from an older
    /// scan can't overwrite the current one.
    private var analysisGeneration = 0
    /// Set when a delete was refused, so the UI can explain why instead of
    /// silently doing nothing.
    var worktreeAlert: String?
    /// Set by the app delegate when a folder is opened from Finder before the
    /// main window exists.
    var pendingScanPath: String?
    /// Set once the main window is on screen; starts a requested scan.
    var scanRequester: ((String) -> Void)?

    static let worktreeDefaultsKey = "detectGitWorktrees"

    var isScanning: Bool {
        if case .scanning = scanStatus { return true }
        return false
    }

    var hasData: Bool {
        rootNode != nil
    }

    var worktrees: [FileNode] {
        detectGitWorktrees ? detectedWorktrees : []
    }

    var worktreeCount: Int {
        worktrees.count
    }

    func worktreeNode(for path: String) -> FileNode? {
        detectedWorktrees.first { $0.path == path }
    }

    /// Deletes a worktree by path, whether the scan reached it or only git
    /// reported it. Prunable entries have no folder to remove, so they are
    /// dropped from the list and their registration pruned instead.
    func deleteWorktree(recordPath path: String, skipTrash: Bool = false) {
        if let node = worktreeNode(for: path) {
            deleteWorktree(node, skipTrash: skipTrash)
            return
        }
        guard let record = worktreeRecords.first(where: { $0.path == path }) else { return }
        if record.isPrunable {
            worktreeRecords.removeAll { $0.path == path }
            pruneOrphanedWorktrees()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let reason = await self.verifyCleanliness(of: path) {
                AppLog.worktree.notice("Refused to delete worktree \(path): \(reason)")
                self.worktreeAlert = reason
                return
            }
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    let url = URL(fileURLWithPath: path)
                    if skipTrash {
                        try FileManager.default.removeItem(at: url)
                    } else {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                AppLog.worktree.error("Could not delete worktree \(path): \(failure)")
                return
            }
            self.worktreeRecords.removeAll { $0.path == path }
            self.worktreeRevision &+= 1
            AppLog.worktree.notice("Deleted worktree not present in the scan tree: \(path)")
        }
    }

    /// Sizes for the summary sheet, keyed by path so git-only records (prunable
    /// entries the scan never saw) can be shown without a size.
    var worktreeSizesByPath: [String: Int64] {
        _ = worktreeShrinkRevision
        var sizes: [String: Int64] = [:]
        for node in detectedWorktrees {
            sizes[node.path] = node.size(for: sizeMetric)
        }
        return sizes
    }

    var unusedWorktreeCount: Int {
        let threshold = WorktreeSettings.staleThreshold
        return worktreeRecords.filter { $0.isUnusedCandidate(staleThreshold: threshold) }.count
    }

    var prunableWorktreeCount: Int {
        worktreeRecords.filter(\.isPrunable).count
    }

    var orphanedWorktreeCount: Int {
        worktreeRecords.filter(\.isOrphaned).count
    }

    var worktreeTotalSize: Int64 {
        _ = worktreeShrinkRevision
        return worktrees.reduce(0) { $0 + $1.size(for: sizeMetric) }
    }

    private func refreshDetectedWorktrees() {
        analysisTask?.cancel()
        analysisGeneration &+= 1
        guard detectGitWorktrees, let root = rootNode else {
            detectedWorktrees = []
            worktreeRecords = []
            isAnalyzingWorktrees = false
            worktreeRevision &+= 1
            return
        }
        detectedWorktrees = GitWorktreeDetector.worktreeRoots(in: root)
        worktreeRevision &+= 1
        worktreeShrinkRevision &+= 1
        startWorktreeAnalysis(root: root)
    }

    /// Cross-checks the scan against git on a background task. Records appear as
    /// soon as git answers, so the list is usable before the slow status checks
    /// finish.
    private func startWorktreeAnalysis(root: FileNode) {
        analysisTask?.cancel()
        guard detectGitWorktrees, GitRunner.shared != nil else {
            // Without git, the filesystem view is all we can report.
            worktreeRecords = WorktreeAnalyzer.analyze(root: root, runner: nil)
            isAnalyzingWorktrees = false
            return
        }
        isAnalyzingWorktrees = true
        analysisGeneration &+= 1
        let generation = analysisGeneration
        let threshold = WorktreeSettings.staleThreshold
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            var options = WorktreeAnalyzer.Options()
            options.staleThreshold = threshold
            let records = WorktreeAnalyzer.analyze(root: root, options: options)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      generation == self.analysisGeneration,
                      self.rootNode === root else { return }
                self.worktreeRecords = records
                self.isAnalyzingWorktrees = false
                let unused = records.filter {
                    $0.isUnusedCandidate(staleThreshold: WorktreeSettings.staleThreshold)
                }
                AppLog.worktree.notice("Worktree analysis finished: \(records.count) record(s), \(unused.count) unused candidate(s), \(records.filter(\.isPrunable).count) prunable")
            }
        }
    }

    /// Records matching the current filter, ordered so the deletable ones come
    /// first.
    var visibleWorktreeRecords: [WorktreeRecord] {
        let threshold = WorktreeSettings.staleThreshold
        let matching: [WorktreeRecord]
        switch worktreeFilter {
        case .all:
            matching = worktreeRecords
        case .unused:
            matching = worktreeRecords.filter { $0.isUnusedCandidate(staleThreshold: threshold) }
        case .dirty:
            matching = worktreeRecords.filter(\.needsAttention)
        }
        return matching.sorted { lhs, rhs in
            let lhsRank = lhs.isPrunable ? 0 : (lhs.isUnusedCandidate(staleThreshold: threshold) ? 1 : 2)
            let rhsRank = rhs.isPrunable ? 0 : (rhs.isUnusedCandidate(staleThreshold: threshold) ? 1 : 2)
            return lhsRank == rhsRank ? lhs.path < rhs.path : lhsRank < rhsRank
        }
    }

    /// Starts a scan requested by Finder once the window can host it.
    func startPendingScan() {
        guard let path = pendingScanPath, let scanRequester else { return }
        pendingScanPath = nil
        scanRequester(path)
    }

    /// Waits for the background git cross-check so callers (and tests) observe
    /// final records rather than the filesystem-only snapshot.
    func waitForWorktreeAnalysis() async {
        while isAnalyzingWorktrees {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }
        let size = node.size(for: sizeMetric)
        AppLog.ui.info("Drill down: \(node.path) size=\(AppLog.bytes(size))")
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateTo(breadcrumb node: FileNode) {
        AppLog.ui.info("Breadcrumb navigation: \(node.path)")
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateUp() {
        guard let current = treemapRoot, let parent = current.parent else { return }
        AppLog.ui.info("Navigate up: \(current.path) -> \(parent.path)")
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = parent
            selectedNode = parent
            rebuildBreadcrumbs()
        }
    }

    func setScanCompleted(root: FileNode) {
        // The scan captured the option when it started; re-sync in case the user
        // toggled it while the scan was running.
        if detectGitWorktrees {
            GitWorktreeDetector.markWorktrees(in: root)
        } else {
            GitWorktreeDetector.clearWorktreeMarks(in: root)
        }
        rootNode = root
        treemapRoot = root
        selectedNode = root
        scanStatus = .completed
        scanUnreadableFolderCount = root.unscannedDirectoryCount
        scanHadFullDiskAccess = FullDiskAccess.isGranted
        AppLog.state.notice("Published scan root \(root.path): files=\(root.fileCount) directories=\(root.directoryCount) fileSize=\(AppLog.bytes(root.totalSize)) allocated=\(AppLog.bytes(root.totalAllocatedSize)) topChildren=\(root.children.count) unreadableFolders=\(root.unscannedDirectoryCount) fullDiskAccess=\(scanHadFullDiskAccess)")
        if root.unscannedDirectoryCount > 0 {
            // Without these folders worktrees inside them are invisible, so the
            // count is surfaced in the UI rather than only in the log.
            AppLog.scan.notice("\(root.unscannedDirectoryCount) folder(s) unreadable; worktrees inside them may be missed (fullDiskAccess=\(scanHadFullDiskAccess))")
        }
        refreshDetectedWorktrees()
        rebuildBreadcrumbs()
    }

    /// Why a delete should be refused, or `nil` when it is verified safe.
    /// Fails closed: a worktree with no verified git state is not deletable
    /// until `deleteWorktree` checks it, so a pending analysis can't let
    /// uncommitted work be trashed. `skipTrash` only chooses how the folder is
    /// removed, never whether it is safe to remove.
    func deleteBlockReason(for path: String) -> String? {
        guard let record = worktreeRecords.first(where: { $0.path == path }) else {
            return "Checking for uncommitted changes…"
        }
        if record.isPrunable { return nil }
        switch record.uncommittedChanges {
        case 0: return nil
        case 1: return "This worktree has uncommitted changes. Commit, stash or discard them first."
        default: return "Uncommitted changes could not be verified. Reveal the worktree to check before deleting."
        }
    }

    /// Re-checks a worktree with git right before deleting it, so a stale or
    /// missing analysis record can't be mistaken for "clean".
    private func verifyCleanliness(of path: String) async -> String? {
        if let record = worktreeRecords.first(where: { $0.path == path }) {
            if record.isPrunable { return nil }
            if let changes = record.uncommittedChanges {
                return changes == 0 ? nil : deleteBlockReason(for: path)
            }
        }
        guard let runner = GitRunner.shared, DirectoryProbe.isDirectory(path) else {
            return "This worktree could not be verified with git, so it was not deleted."
        }
        let reason = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let snapshot = try? GitStatusReader.snapshot(of: path, runner: runner) else {
                return "Git could not report the state of this worktree, so it was not deleted."
            }
            guard !snapshot.isDirty else {
                return "This worktree has uncommitted changes. Commit, stash or discard them first."
            }
            return nil
        }.value
        if reason == nil, let index = worktreeRecords.firstIndex(where: { $0.path == path }) {
            worktreeRecords[index].uncommittedChanges = 0
        }
        return reason
    }

    /// Moves a worktree root to the Trash, or deletes it outright when the user
    /// asks for that, then removes it from the scanned tree so the worktree
    /// total updates without a rescan.
    func deleteWorktree(_ node: FileNode, skipTrash: Bool = false) {
        guard node.isGitWorktree, node.parent != nil else { return }
        let path = node.path
        // Deleting a large worktree can take a while, so keep the UI responsive
        // and only drop the node once the filesystem operation succeeded.
        Task {
            if let reason = await verifyCleanliness(of: path) {
                AppLog.worktree.notice("Refused to delete worktree \(path): \(reason)")
                self.worktreeAlert = reason
                return
            }
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    let url = URL(fileURLWithPath: path)
                    if skipTrash {
                        try FileManager.default.removeItem(at: url)
                    } else {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                AppLog.worktree.error("Could not delete worktree \(path): \(failure)")
                return
            }
            AppLog.worktree.notice("Deleted worktree \(path) (trash=\(!skipTrash)); total now \(AppLog.bytes(self.worktreeTotalSize))")
            removeFromTree(node)
        }
    }

    func removeFromTree(_ node: FileNode) {
        guard let parent = node.parent else {
            AppLog.state.error("Ignoring removal of \(node.path): node has no parent")
            return
        }
        parent.children.removeAll { $0 === node }
        node.parent = nil
        guard let root = rootNode else { return }
        root.computeAggregates()
        detectedWorktrees.removeAll { $0 === node || self.isDescendant($0, of: node) }
        worktreeRecords.removeAll { $0.path == node.path || $0.path.hasPrefix(node.path + "/") }
        let remainingWorktrees = detectedWorktrees.count
        AppLog.state.notice("Removed \(node.path) from tree: rootFiles=\(root.fileCount) rootAllocated=\(AppLog.bytes(root.totalAllocatedSize)) worktrees=\(remainingWorktrees)")
        worktreeRevision &+= 1
        worktreeShrinkRevision &+= 1

        if treemapRoot === node {
            treemapRoot = parent
        }
        if let selected = selectedNode, isDescendant(selected, of: node) {
            selectedNode = parent
        }
        rebuildBreadcrumbs()
    }

    /// Prunes git registrations for worktrees whose folder is gone.
    func pruneOrphanedWorktrees() {
        guard let runner = GitRunner.shared else { return }
        let prunable = worktreeRecords.filter(\.isPrunable)
        guard !prunable.isEmpty else { return }
        let targets = Set(prunable.compactMap(\.mainRepository))
            .filter { DirectoryProbe.isDirectory($0) }
        Task { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) {
                var failures: [String] = []
                for repository in targets {
                    do {
                        let output = try WorktreeAnalyzer.prune(in: repository, runner: runner)
                        AppLog.worktree.notice("Pruned worktrees in \(repository): \(output)")
                    } catch {
                        failures.append("\(repository): \(error)")
                    }
                }
                return failures
            }.value
            for failure in failures {
                AppLog.worktree.error("Worktree prune failed for \(failure)")
            }
            guard let self else { return }
            self.worktreeRecords.removeAll(where: \.isPrunable)
            self.worktreeRevision &+= 1
            self.worktreeShrinkRevision &+= 1
            AppLog.worktree.notice("Removed \(prunable.count) prunable worktree record(s) from the list")
        }
    }

    /// Drops worktrees deleted outside MacDirStat. Only paths already known to
    /// be worktree roots are checked, so this is cheap enough to poll.
    func reconcileWorktrees() {
        guard detectGitWorktrees, let root = rootNode, !detectedWorktrees.isEmpty else { return }
        var vanished = false
        let snapshot = detectedWorktrees
        for node in snapshot {
            var metadata = Darwin.stat()
            guard lstat(node.path, &metadata) != 0 || metadata.st_mode & S_IFMT != S_IFDIR,
                  node.parent != nil else { continue }
            AppLog.worktree.notice("Worktree disappeared from disk: \(node.path)")
            removeFromTree(node)
            vanished = true
        }
        guard vanished else { return }
        worktreeRevision &+= 1
        if let selected = selectedNode, !isDescendant(selected, of: root) {
            selectedNode = treemapRoot
        }
    }

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        AppLog.state.notice("Resetting scan state")
        scanStatus = .idle
        rootNode = nil
        treemapRoot = nil
        selectedNode = nil
        breadcrumbs = []
        detectedWorktrees = []
        worktreeRecords = []
        isAnalyzingWorktrees = false
        scanUnreadableFolderCount = 0
        worktreeRevision &+= 1
        worktreeShrinkRevision &+= 1
    }

    private func isDescendant(_ node: FileNode?, of ancestor: FileNode) -> Bool {
        var current = node
        while let candidate = current {
            if candidate === ancestor { return true }
            current = candidate.parent
        }
        return false
    }

    private func rebuildBreadcrumbs() {
        var crumbs: [FileNode] = []
        var node = treemapRoot
        while let current = node {
            crumbs.insert(current, at: 0)
            node = current.parent
        }
        breadcrumbs = crumbs
    }
}
