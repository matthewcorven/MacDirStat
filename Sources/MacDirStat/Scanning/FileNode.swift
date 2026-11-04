import Foundation

final class FileNode: Identifiable, @unchecked Sendable {
    let id: UInt64 // inode
    let name: String
    let isDirectory: Bool
    let ownSize: Int64
    let allocatedSize: Int64
    let category: FileCategory
    let modificationDate: Date?
    let isDataless: Bool
    /// Set by the scanner (or by toggling the option after a scan) when this
    /// directory is the root of a linked git worktree.
    var isGitWorktree = false
    var scanIssue: String?
    /// Set when `scanIssue` counts toward the incomplete-scan warning.
    /// Folders left out for a permanent reason still show their own note. Folders
    /// that are permanently unreadable by design stay out of the total.
    var scanIssueCountsAsIncomplete = true
    /// Set when the folder's contents are deliberately not scanned because they
    /// are a synthetic duplicate of a path scanned elsewhere.
    var scanSkippedAsDuplicate = false
    var unavailableEntryCount = 0
    /// Per-category totals computed once in `computeAggregates`. The inspector
    /// reads these instead of walking the tree: a full-disk root holds millions
    /// of nodes, and walking them on every view update stalled the whole app.
    private(set) var categorySizes: [FileCategory: Int64] = [:]
    private(set) var categorySizesByFileSize: [FileCategory: Int64] = [:]
    private(set) var unscannedDirectoryCount = 0
    /// Folders that were not read for a permanent reason, kept separate so the
    /// UI can say "not included" without calling the scan incomplete.
    private(set) var expectedUnreadableDirectoryCount = 0
    /// Subfolders skipped because a volume is scanned from its real path.
    private(set) var duplicateMirrorDirectoryCount = 0
    private(set) var totalUnavailableEntryCount = 0
    private(set) var cloudOnlyFileCount = 0

    weak var parent: FileNode?
    var children: [FileNode] = []
    private(set) var totalSize: Int64 = 0
    private(set) var totalAllocatedSize: Int64 = 0
    private(set) var fileCount: Int = 0
    private(set) var directoryCount: Int = 0

    /// Distance from the scan root, used to bound recursive post-processing.
    var depth: Int {
        var depth = 0
        var node = parent
        while let current = node {
            depth += 1
            node = current.parent
        }
        return depth
    }

    var path: String {
        var components: [String] = []
        var node: FileNode? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        let parts = components.reversed()
        guard let root = parts.first else { return "" }
        return parts.dropFirst().reduce(root) { FilePath.join($0, $1) }
    }

    init(
        inode: UInt64,
        name: String,
        isDirectory: Bool,
        ownSize: Int64 = 0,
        allocatedSize: Int64 = 0,
        category: FileCategory = .other,
        modificationDate: Date? = nil,
        isDataless: Bool = false
    ) {
        self.id = inode
        self.name = name
        self.isDirectory = isDirectory
        self.ownSize = ownSize
        self.allocatedSize = allocatedSize
        self.category = category
        self.modificationDate = modificationDate
        self.isDataless = isDataless
        self.cloudOnlyFileCount = !isDirectory && isDataless ? 1 : 0
        if !isDirectory {
            // Files are the leaves the category totals are built from.
            self.categorySizes = [category: allocatedSize]
            self.categorySizesByFileSize = [category: ownSize]
        }
        self.totalSize = ownSize
        self.totalAllocatedSize = allocatedSize
        self.fileCount = isDirectory ? 0 : 1
        self.directoryCount = isDirectory ? 1 : 0
    }

    convenience init(name: String, metadata: Darwin.stat) {
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        let ext = name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]) } ?? ""
        self.init(
            inode: UInt64(metadata.st_ino),
            name: name,
            isDirectory: isDirectory,
            ownSize: Int64(metadata.st_size),
            allocatedSize: Int64(metadata.st_blocks) * 512,
            category: isDirectory ? .other : FileExtensionMap.category(for: ext),
            modificationDate: Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)),
            isDataless: metadata.st_flags & UInt32(SF_DATALESS) != 0
        )
    }

    func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    func computeAggregates() {
        guard isDirectory else { return }
        var size: Int64 = ownSize
        var allocated: Int64 = allocatedSize
        var files = 0
        var dirs = 1 // count self
        // Only a node that actually carries an issue counts, matching the
        // previous semantics for hand-built test trees.
        var unscanned = scanIssue != nil && scanIssueCountsAsIncomplete ? 1 : 0
        var expectedUnreadable = scanIssue != nil && !scanIssueCountsAsIncomplete && !scanSkippedAsDuplicate ? 1 : 0
        var duplicates = scanSkippedAsDuplicate ? 1 : 0
        var unavailable = unavailableEntryCount
        var cloudFiles = 0
        var allocatedByCategory: [FileCategory: Int64] = [:]
        var logicalByCategory: [FileCategory: Int64] = [:]

        for child in children {
            child.computeAggregates()
            size += child.totalSize
            allocated += child.totalAllocatedSize
            files += child.fileCount
            dirs += child.directoryCount
            unscanned += child.unscannedDirectoryCount
            expectedUnreadable += child.expectedUnreadableDirectoryCount
            duplicates += child.duplicateMirrorDirectoryCount
            unavailable += child.totalUnavailableEntryCount
            cloudFiles += child.cloudOnlyFileCount
            for (category, size) in child.categorySizes {
                allocatedByCategory[category, default: 0] += size
            }
            for (category, size) in child.categorySizesByFileSize {
                logicalByCategory[category, default: 0] += size
            }
        }

        totalSize = size
        totalAllocatedSize = allocated
        fileCount = files
        directoryCount = dirs
        unscannedDirectoryCount = unscanned
        expectedUnreadableDirectoryCount = expectedUnreadable
        duplicateMirrorDirectoryCount = duplicates
        totalUnavailableEntryCount = unavailable
        cloudOnlyFileCount = cloudFiles
        categorySizes = allocatedByCategory
        categorySizesByFileSize = logicalByCategory
    }

    func sortChildrenBySize(metric: SizeMetric = .allocatedSize) {
        children.sort { $0.size(for: metric) > $1.size(for: metric) }
        for child in children where child.isDirectory {
            child.sortChildrenBySize(metric: metric)
        }
    }

    /// Category totals for this subtree, already computed by
    /// `computeAggregates`, so this is a dictionary lookup rather than a walk.
    func categoryBreakdown(metric: SizeMetric = .allocatedSize) -> [(category: FileCategory, size: Int64)] {
        let breakdown = metric == .fileSize ? categorySizesByFileSize : categorySizes
        return breakdown
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, size: $0.value) }
    }

    func size(for metric: SizeMetric) -> Int64 {
        switch metric {
        case .fileSize: totalSize
        case .allocatedSize: totalAllocatedSize
        }
    }

    var directoryChildren: [FileNode] {
        children.filter(\.isDirectory)
    }
}
