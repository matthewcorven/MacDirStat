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
            AppLog.state.notice("Worktree detection toggled: enabled=\(enabled) worktrees=\(count) total=\(AppLog.bytes(total), privacy: .public)")
        }
    }
    /// Bumped whenever worktree marks change or a worktree is removed so
    /// computed worktree totals invalidate even though `FileNode` is not observable.
    private(set) var worktreeRevision = 0
    private(set) var worktreeShrinkRevision = 0
    private var detectedWorktrees: [FileNode] = []

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

    var worktreeTotalSize: Int64 {
        _ = worktreeShrinkRevision
        return worktrees.reduce(0) { $0 + $1.size(for: sizeMetric) }
    }

    private func refreshDetectedWorktrees() {
        guard detectGitWorktrees, let root = rootNode else {
            detectedWorktrees = []
            worktreeRevision &+= 1
            return
        }
        detectedWorktrees = GitWorktreeDetector.worktreeRoots(in: root)
        worktreeRevision &+= 1
        worktreeShrinkRevision &+= 1
    }

    func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }
        let size = node.size(for: sizeMetric)
        AppLog.ui.info("Drill down: \(node.path, privacy: .public) size=\(AppLog.bytes(size), privacy: .public)")
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateTo(breadcrumb node: FileNode) {
        AppLog.ui.info("Breadcrumb navigation: \(node.path, privacy: .public)")
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateUp() {
        guard let current = treemapRoot, let parent = current.parent else { return }
        AppLog.ui.info("Navigate up: \(current.path, privacy: .public) -> \(parent.path, privacy: .public)")
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
        AppLog.state.notice("Published scan root \(root.path, privacy: .public): files=\(root.fileCount) directories=\(root.directoryCount) fileSize=\(AppLog.bytes(root.totalSize), privacy: .public) allocated=\(AppLog.bytes(root.totalAllocatedSize), privacy: .public) topChildren=\(root.children.count)")
        refreshDetectedWorktrees()
        rebuildBreadcrumbs()
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
                AppLog.worktree.error("Could not delete worktree \(path, privacy: .public): \(failure, privacy: .public)")
                return
            }
            AppLog.worktree.notice("Deleted worktree \(path, privacy: .public) (trash=\(!skipTrash)); total now \(AppLog.bytes(self.worktreeTotalSize), privacy: .public)")
            removeFromTree(node)
        }
    }

    func removeFromTree(_ node: FileNode) {
        guard let parent = node.parent else {
            AppLog.state.error("Ignoring removal of \(node.path, privacy: .public): node has no parent")
            return
        }
        parent.children.removeAll { $0 === node }
        node.parent = nil
        guard let root = rootNode else { return }
        root.computeAggregates()
        detectedWorktrees.removeAll { $0 === node || self.isDescendant($0, of: node) }
        let remainingWorktrees = detectedWorktrees.count
        AppLog.state.notice("Removed \(node.path, privacy: .public) from tree: rootFiles=\(root.fileCount) rootAllocated=\(AppLog.bytes(root.totalAllocatedSize), privacy: .public) worktrees=\(remainingWorktrees)")
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
            AppLog.worktree.notice("Worktree disappeared from disk: \(node.path, privacy: .public)")
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
        AppLog.state.notice("Resetting scan state")
        scanStatus = .idle
        rootNode = nil
        treemapRoot = nil
        selectedNode = nil
        breadcrumbs = []
        detectedWorktrees = []
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
