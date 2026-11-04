import Foundation

/// A reportable row for one worktree, combining what the filesystem scan saw
/// with what git reported.
struct WorktreeRecord: Identifiable, Sendable, Equatable {
    enum GitSource: String, Sendable {
        case worktreeList
        case statusCommand
        case unverified
    }

    let path: String
    var branch: String?
    /// Root of the repository this worktree belongs to, when known.
    var mainRepository: String?
    var isDetached = false
    var isPrunable = false
    var pruneReason: String?
    var isBare = false
    /// `nil` until git (or an explicit check) tells us.
    var uncommittedChanges: Int?
    var latestChange: Date?
    var source: GitSource = .unverified
    /// Set when the record came from git but the scan didn't reach the folder.
    var scanMissedReason: String?
    /// Set when the `.git` file points somewhere that doesn't resolve.
    var gitLinkIssue: String?
    /// The worktree is fine, but the repository it belongs to is gone.
    var isOrphaned = false

    var id: String { path }
    var name: String {
        path == "/" ? path : (path as NSString).lastPathComponent
    }
    var isClean: Bool? { uncommittedChanges.map { $0 == 0 } }
    /// Needs a human decision rather than a delete: uncommitted work, a missing
    /// repository, or a broken link.
    var needsAttention: Bool {
        isPrunable || isOrphaned || isClean == false || gitLinkIssue != nil
    }
    var isMissingFromDisk: Bool { scanMissedReason != nil }

    /// A stale-and-clean worktree, or a detached one with no changes, is the
    /// set a user can usually delete without losing work.
    func isUnusedCandidate(staleThreshold: TimeInterval, now: Date = Date()) -> Bool {
        guard isClean == true, !isPrunable else { return false }
        if isDetached { return true }
        guard let latestChange else { return false }
        return now.timeIntervalSince(latestChange) >= staleThreshold
    }

    /// Removing a prunable entry only prunes git's bookkeeping: its directory is
    /// already gone. Anything else needs a clean working tree.
    var isSafeToDelete: Bool {
        isPrunable || isClean == true
    }
}

/// Cross-checks the filesystem scan against `git worktree list --porcelain` and
/// `git status`, and flags the entries the user can delete.
enum WorktreeAnalyzer {
    struct Options: Sendable {
        var staleThreshold: TimeInterval = WorktreeSettings.staleThreshold
        var now: Date = Date()
        /// git worktrees rarely live outside the scan root, but bound the work
        /// anyway so a giant tree can't turn reconciliation into a hang.
        var maximumRepositories = 256
        var maximumStatusChecks = 128
    }

    static func analyze(
        root: FileNode,
        runner: GitRunner? = GitRunner.shared,
        options: Options = Options()
    ) -> [WorktreeRecord] {
        var records: [String: WorktreeRecord] = [:]
        var order: [String] = []

        // 1. Filesystem pass: every marked worktree root, with its size and the
        //    newest file in it. This is what the scan can see without git.
        let fileSystemEntries = GitWorktreeDetector.worktreeRoots(in: root)
        for node in fileSystemEntries where node.isGitWorktree {
            let path = node.path
            var record = WorktreeRecord(path: path)
            record.source = .unverified
            record.latestChange = newestModification(in: node)
            if let pointer = GitWorktreeDetector.parsePointer(inDirectory: path) {
                record.mainRepository = pointer.mainRepo
                if !pointer.isLinkedWorktree {
                    record.gitLinkIssue = "The .git file does not point at a repository worktrees folder."
                } else if !FileManager.default.fileExists(atPath: pointer.gitDir) {
                    record.gitLinkIssue = "The .git file points at a worktrees folder that no longer exists."
                }
                if let mainRepo = pointer.mainRepo, !DirectoryProbe.isDirectory(mainRepo) {
                    // The commit history lives in the main repo; without it this
                    // worktree can't be used or safely inspected with git.
                    record.isOrphaned = true
                }
            }
            records[path] = record
            order.append(path)
        }

        // 2. Ask git about every main repository those worktrees belong to. That
        //    adds branch names and finds prunable entries whose folder is gone.
        guard let runner else { return ordered(records, order: order) }
        var repositories = Set<String>()
        for node in fileSystemEntries {
            guard let pointer = GitWorktreeDetector.parsePointer(inDirectory: node.path) else { continue }
            if let mainRepo = pointer.mainRepo { repositories.insert(mainRepo) }
        }
        // A main repo can also be in the tree without any of its worktrees:
        // that's where prunable entries live, so look for `.git` folders too.
        collectRepositories(in: root, into: &repositories)
        if repositories.count > options.maximumRepositories {
            repositories = Set(repositories.sorted().prefix(options.maximumRepositories))
        }

        for repository in repositories.sorted() {
            guard DirectoryProbe.isDirectory(repository) else { continue }
            guard let entries = try? listWorktrees(in: repository, runner: runner) else { continue }
            for entry in entries where !entry.isBare {
                let path = FilePath.normalized(entry.path)
                // `git worktree list` includes the main working tree. It is the
                // repository, not a linked worktree, so leave it out of the report
                // (a prunable main entry is kept because it is actionable).
                if path == repository && !entry.isPrunable { continue }
                var record = records[path] ?? WorktreeRecord(path: path)
                record.mainRepository = record.mainRepository ?? repository
                if records[path] == nil { order.append(path) }
                record.source = .worktreeList
                record.branch = entry.branchName
                record.isDetached = entry.branch == .detached
                record.isPrunable = entry.isPrunable
                record.pruneReason = entry.pruneReason
                record.isBare = entry.isBare
                if record.isPrunable {
                    record.scanMissedReason = entry.pruneReason
                        ?? "Registered worktree whose folder is gone"
                } else if records[path] == nil {
                    // git knows it but the scan didn't see it: outside the scanned
                    // folders, or inside a folder the scan couldn't read.
                    record.scanMissedReason = "Outside the scanned folders or unreadable during the scan"
                }
                records[path] = record
            }
        }

        // 3. Work out dirty/clean (and the real branch when git can tell us).
        //    Real worktrees go first: they are what the user acts on, and a long
        //    list of prunable registrations shouldn't consume the check budget.
        var checked = 0
        let statusTargets = order
            .filter { records[$0]?.isPrunable != true }
            .sorted { records[$0]?.mainRepository ?? "" < records[$1]?.mainRepository ?? "" }
        for path in statusTargets {
            guard checked < options.maximumStatusChecks,
                  var record = records[path],
                  DirectoryProbe.isDirectory(path) else { continue }
            // git worktree list can be stale, so let the worktree itself decide
            // whether it is dirty and what it has checked out.
            checked += 1
            guard let snapshot = try? GitStatusReader.snapshot(of: path, runner: runner) else {
                continue
            }
            record.uncommittedChanges = snapshot.isDirty ? 1 : 0
            switch snapshot.branch {
            case let .branch(name):
                record.branch = name
                record.isDetached = false
            case .detached:
                record.branch = nil
                record.isDetached = true
            }
            record.source = .statusCommand
            records[path] = record
        }

        return ordered(records, order: order)
    }

    /// `git worktree list` run at the main repository root.
    static func listWorktrees(in repository: String, runner: GitRunner) throws -> [GitWorktreeEntry] {
        let output = try runner.run(["worktree", "list", "--porcelain"], in: repository)
        return GitWorktreeEntry.parsePorcelain(output)
    }

    /// Removes git's registrations for worktrees whose folder is gone.
    @discardableResult
    static func prune(in repository: String, runner: GitRunner) throws -> String {
        try runner.run(["worktree", "prune", "-v"], in: repository)
    }

    /// True when the main repository for `record` can still be found. The
    /// pointer stored in the worktree names it, so no extra git call is needed.
    static func mainRepository(for path: String) -> String? {
        GitWorktreeDetector.parsePointer(inDirectory: path)?.mainRepo
    }

    private static func collectRepositories(in node: FileNode, into repositories: inout Set<String>) {
        guard node.isDirectory else { return }
        if GitWorktreeDetector.hasGitDirectory(node) {
            repositories.insert(node.path)
        }
        // Depth is bounded because post-scan collection runs on the UI's tree;
        // a scan already marks worktrees it reached, so this only adds repos that
        // have no visible worktree of their own.
        if node.depth > 12 { return }
        for child in node.children where child.isDirectory {
            collectRepositories(in: child, into: &repositories)
        }
    }

    private static func newestModification(in node: FileNode) -> Date? {
        if !node.isDirectory { return node.modificationDate }
        var newest = node.modificationDate
        for child in node.children {
            guard let candidate = newestModification(in: child) else { continue }
            if newest == nil || candidate > newest! { newest = candidate }
        }
        return newest
    }

    private static func ordered(_ records: [String: WorktreeRecord], order: [String]) -> [WorktreeRecord] {
        order.compactMap { records[$0] }
    }
}

/// Directories that are large and never contain worktrees. Skipping them is
/// what keeps post-scan detection from walking `.build` or `node_modules`.
enum WorktreeScanFilter {
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".build", ".swiftpm", "Library", ".venv", "venv",
        "Pods", "DerivedData", ".git",
    ]

    /// Worktrees can legitimately live anywhere, so only skip a directory when
    /// it is one of the known noise folders *and* it has no `.git` file of its
    /// own (a worktree checked out under `Library` must still be reported).
    static func shouldSkip(_ name: String) -> Bool {
        skippedDirectoryNames.contains(name)
    }
}

/// Cheap existence checks that don't fault in file contents or cloud data.
enum DirectoryProbe {
    static func isDirectory(_ path: String) -> Bool {
        var metadata = Darwin.stat()
        guard lstat(path, &metadata) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFDIR
    }
}
