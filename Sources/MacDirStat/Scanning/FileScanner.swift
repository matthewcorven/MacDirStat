import Foundation
import os

enum ScanEvent: Sendable {
    case progress(fileCount: Int, byteCount: Int64, currentPath: String)
    case completed(root: FileNode)
    case error(String)
}

struct FileScanner: Sendable {
    let rootPath: String
    var maximumConcurrentDirectories: Int = 4
    var enumerationMode: DirectoryEnumerationMode = .automatic
    /// Detect linked git worktree roots while scanning so their size is known
    /// before the finished tree is published.
    var detectGitWorktrees = false
    /// Overrides the live mount table; tests use this to model mounted volumes.
    var mounts: MountTable?

    func scan() -> AsyncStream<ScanEvent> {
        let path = rootPath
        let limit = max(1, maximumConcurrentDirectories)
        let mode = enumerationMode
        let detectWorktrees = detectGitWorktrees
        let mounts = mounts ?? MountTable()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            // The app cannot show its treemap until this requested scan finishes.
            // Keep directory concurrency bounded while prioritizing its results.
            let task = Task.detached(priority: .userInitiated) {
                await performScan(
                    rootPath: path,
                    limit: limit,
                    mode: mode,
                    detectWorktrees: detectWorktrees,
                    mounts: mounts,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// The policy is thread-local. The body must be synchronous so Swift cannot resume
// it on another thread. Restore the previous policy before returning to the pool.
// Apple TN3150: even stat can materialize intermediate directories in a path.
func withoutDatalessMaterialization<T>(_ body: () throws -> T) throws -> T {
    let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    let scope = IOPOL_SCOPE_THREAD
    let previous = getiopolicy_np(type, scope)
    guard previous >= 0,
          setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
        throw ScanFailure(message: "Cannot disable cloud downloads; scan stopped for safety.")
    }
    defer { setiopolicy_np(type, scope, previous) }
    return try body()
}

private struct ScanFailure: Error {
    let message: String
}

/// Mount points other than the scan root are volume boundaries. Paths are used
/// rather than `st_dev` because a sealed system snapshot reports a different
/// device for its files than for the directory that contains them.
struct MountTable: Sendable {
    private let mountPoints: Set<String>

    init() {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        var points = Set<String>()
        if count > 0, let buffer {
            for index in 0..<Int(count) {
                points.insert(Self.normalize(Self.name(of: buffer[index])))
            }
        }
        mountPoints = points
    }

    init(mountPoints: Set<String>) {
        // Canonicalize test-supplied points the same way the scan root is
        // canonicalized, so `/var/x` and `/private/var/x` compare equal.
        self.mountPoints = Set(mountPoints.map { FilePath.normalized(Self.normalize($0)) })
    }

    var count: Int { mountPoints.count }

    func isMountPoint(_ path: String) -> Bool {
        mountPoints.contains(Self.normalize(path))
    }

    private static func name(of entry: statfs) -> String {
        withUnsafePointer(to: entry.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

private final class ScanState: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    let rootDevice: dev_t
    let mounts: MountTable

    /// Hard links and firmlinks share a device and inode. Keying on both avoids
    /// treating equal inode numbers on different volumes as the same entry.
    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: UInt64
    }

    private struct State {
        var fileCount = 0
        var byteCount: Int64 = 0
        var seenEntries = Set<FileIdentity>()
        var lastProgress = ContinuousClock.now
    }

    init(rootDevice: dev_t, mounts: MountTable = MountTable()) {
        self.rootDevice = rootDevice
        self.mounts = mounts
    }

    func record(_ metadata: Darwin.stat) -> Bool {
        let identity = FileIdentity(device: metadata.st_dev, inode: UInt64(metadata.st_ino))
        return lock.withLock { state in
            guard state.seenEntries.insert(identity).inserted else { return false }
            if metadata.st_mode & S_IFMT == S_IFREG { state.fileCount += 1 }
            state.byteCount += Int64(metadata.st_blocks) * 512
            return true
        }
    }

    func progress(path: String, force: Bool = false) -> ScanEvent? {
        lock.withLock { state in
            let now = ContinuousClock.now
            guard force || now - state.lastProgress >= .milliseconds(100) else { return nil }
            state.lastProgress = now
            return .progress(fileCount: state.fileCount, byteCount: state.byteCount, currentPath: path)
        }
    }
}

private struct DirectoryJob: Sendable {
    let path: String
    let node: FileNode
    var skipsWorktreeMarking = false
}

private struct DirectoryResult: Sendable {
    let job: DirectoryJob
    var children: [FileNode] = []
    var subdirectories: [DirectoryJob] = []
    var block: ScanBlock?
    var unavailableEntries = 0

    var issue: String? { block?.message }
}

private func performScan(
    rootPath: String,
    limit: Int,
    mode: DirectoryEnumerationMode,
    detectWorktrees: Bool,
    mounts: MountTable,
    continuation: AsyncStream<ScanEvent>.Continuation
) async {
    defer { continuation.finish() }
    let started = ContinuousClock.now
    AppLog.scan.notice("Scan starting: path=\(rootPath) concurrency=\(limit) mode=\(String(describing: mode)) detectWorktrees=\(detectWorktrees)")
    var scannedDirectories = 0
    do {
        try Task.checkCancellation()
        var rootStat = try withoutDatalessMaterialization {
            var metadata = Darwin.stat()
            // A trailing separator makes lstat follow a symlink, which would let
            // a symlinked root through; trim it before the check.
            var checkedPath = rootPath
            while checkedPath.count > 1, checkedPath.hasSuffix("/") { checkedPath.removeLast() }
            guard lstat(checkedPath, &metadata) == 0 else {
                throw ScanFailure(message: "Cannot inspect the scan folder: \(String(cString: strerror(errno))). Cloud-only parent folders are not downloaded.")
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw ScanFailure(message: "The scan path must be a directory, not a file or symbolic link.")
            }
            return metadata
        }
        // Normalize after rejecting a symlink root so the root, its children and
        // anything git reports later share one canonical form: `/tmp/x` and its
        // children must not disagree about `/private/tmp/x`.
        let path = FilePath.normalized(rootPath)
        // Re-read the metadata under the canonical path; a symlinked parent is
        // resolved now, and this stat is what the tree reports for the root.
        if path != rootPath {
            var canonical = Darwin.stat()
            if lstat(path, &canonical) == 0 { rootStat = canonical }
        }
        let state = ScanState(rootDevice: rootStat.st_dev, mounts: mounts)
        _ = state.record(rootStat)
        AppLog.scan.info("Scan root: normalized=\(path) device=\(rootStat.st_dev) inode=\(rootStat.st_ino) blocks=\(rootStat.st_blocks) isDataless=\(rootStat.st_flags & UInt32(SF_DATALESS) != 0) mounts=\(mounts.count)")
        let root = FileNode(name: path, metadata: rootStat)
        var pending = [DirectoryJob(path: path, node: root)]

        try await withThrowingTaskGroup(of: DirectoryResult.self) { group in
            var active = 0
            while !pending.isEmpty || active > 0 {
                try Task.checkCancellation()
                while active < limit, let job = pending.popLast() {
                    group.addTask {
                        try scanDirectory(job, mode: mode, state: state,
                                          detectWorktrees: detectWorktrees,
                                          continuation: continuation)
                    }
                    active += 1
                }
                if let result = try await group.next() {
                    active -= 1
                    scannedDirectories += 1
                    if let block = result.block {
                        let reported = block.countsAsIncomplete ? "reported" : "expected"
                        AppLog.scan.info("Folder not fully read (\(reported)): \(result.job.path) kind=\(String(describing: block.kind)) message=\(block.message)")
                    }
                    result.job.node.scanIssue = result.block?.message
                    result.job.node.scanIssueCountsAsIncomplete = result.block?.countsAsIncomplete ?? false
                    result.job.node.scanSkippedAsDuplicate = result.block?.kind == .syntheticDuplicate
                    result.job.node.unavailableEntryCount = result.unavailableEntries
                    for child in result.children { result.job.node.addChild(child) }
                    pending.append(contentsOf: result.subdirectories)
                }
            }
        }
        try Task.checkCancellation()
        // Worktree roots were marked while each directory was open, so there is
        // no second tree walk here; the summary is already in hand.
        if detectWorktrees {
            let worktrees = GitWorktreeDetector.worktreeRoots(in: root)
            AppLog.scan.notice("Detected \(worktrees.count) worktrees during the scan: \(worktrees.map(\.path).joined(separator: ", "))")
        }
        root.computeAggregates()
        root.sortChildrenBySize(metric: .allocatedSize)
        try Task.checkCancellation()
        AppLog.scan.notice("Scan finished in \(AppLog.duration(ContinuousClock.now - started)): files=\(root.fileCount) directories=\(root.directoryCount) totalSize=\(AppLog.bytes(root.totalSize)) allocated=\(AppLog.bytes(root.totalAllocatedSize)) cloudOnlyFiles=\(root.cloudOnlyFileCount) incompleteFolders=\(root.unscannedDirectoryCount) unavailableEntries=\(root.totalUnavailableEntryCount) scannedDirectories=\(scannedDirectories)")
        if let progress = state.progress(path: path, force: true) { continuation.yield(progress) }
        continuation.yield(.completed(root: root))
    } catch is CancellationError {
        // Cancellation is terminal: never publish a partial tree as completed.
        AppLog.scan.notice("Scan cancelled after \(AppLog.duration(ContinuousClock.now - started)): scannedDirectories=\(scannedDirectories)")
    } catch let error as ScanFailure {
        AppLog.scan.error("Scan failed: \(error.message)")
        continuation.yield(.error(error.message))
    } catch {
        AppLog.scan.error("Scan failed: \(error.localizedDescription)")
        continuation.yield(.error(error.localizedDescription))
    }
}

private func scanDirectory(
    _ job: DirectoryJob,
    mode: DirectoryEnumerationMode,
    state: ScanState,
    detectWorktrees: Bool,
    continuation: AsyncStream<ScanEvent>.Continuation
) throws -> DirectoryResult {
    try withoutDatalessMaterialization {
        try Task.checkCancellation()
        var result = DirectoryResult(job: job)
        if let progress = state.progress(path: job.path) { continuation.yield(progress) }

        // The sealed system volume exposes the writable data volume a second
        // time under this path, so every protected folder there appears twice.
        // It duplicates `/System/Volumes/Data`, which is scanned on its own, so
        // walking it only doubles the noise and the time.
        if isSyntheticDataDuplicate(job.path, mounts: state.mounts) {
            result.block = ScanBlock(
                kind: .syntheticDuplicate,
                message: "mirror of /System/Volumes/Data; contents are measured from the real volume"
            )
            AppLog.scan.info("Not descending into the data-volume mirror: \(job.path)")
            return result
        }
        // Cloud-only directories have no locally enumerated children. Opening
        // them could fetch a remote listing, so retain a visible placeholder.
        guard !job.node.isDataless else {
            result.block = .cloudOnly
            AppLog.scan.debug("Skipping cloud-only folder: \(job.path)")
            return result
        }
        // Do not follow a directory replaced with a symlink after enumeration.
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            result.block = ScanBlock.forOpenFailure(errno: code, path: job.path)
            AppLog.scan.debug("Cannot open folder: \(job.path) errno=\(code) kind=\(String(describing: result.block?.kind)) reportable=\(result.block?.countsAsIncomplete ?? true)")
            return result
        }
        defer { close(fd) }
        var currentStat = Darwin.stat()
        guard fstat(fd, &currentStat) == 0,
              UInt64(currentStat.st_ino) == job.node.id else {
            result.block = .changedMidScan
            AppLog.scan.info("Folder identity changed during scan: \(job.path) expectedInode=\(job.node.id) actualInode=\(currentStat.st_ino) expectedDevice=\(state.rootDevice) actualDevice=\(currentStat.st_dev)")
            return result
        }
        // Sealed system snapshots report a different device for the same mount,
        // so note the drift without rejecting an otherwise unchanged directory.
        if currentStat.st_dev != state.rootDevice {
            AppLog.scan.debug("Folder device differs from scan root: \(job.path) rootDevice=\(state.rootDevice) actualDevice=\(currentStat.st_dev)")
        }

        func append(name: String, metadata: Darwin.stat) {
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG, state.record(metadata) else { return }
            let child = FileNode(name: name, metadata: metadata)
            // A `.git` file means this folder may be a linked worktree. Checking
            // it here costs one small read while the directory is already open,
            // instead of walking the whole tree again after the scan.
            if detectWorktrees, !job.skipsWorktreeMarking, name == ".git" {
                markWorktreeOwnerIfNeeded(job)
            }
            if child.isDirectory {
                let childPath = FilePath.join(job.path, name)
                // A sealed system snapshot reports a different device for files
                // than the mount they appear under, so identify nested volumes by
                // mount point instead of by device number. Keep the mount point
                // visible but do not descend into another volume.
                if state.mounts.isMountPoint(childPath) {
                    AppLog.scan.debug("Not descending into mounted volume: \(childPath)")
                } else if detectWorktrees,
                          job.skipsWorktreeMarking || WorktreeScanFilter.shouldSkip(name) {
                    // Dependencies and build output are large and never where
                    // the user keeps worktrees, so don't look for `.git` files
                    // under them. Sizes are still measured exactly.
                    result.subdirectories.append(DirectoryJob(
                        path: childPath, node: child, skipsWorktreeMarking: true))
                } else {
                    result.subdirectories.append(DirectoryJob(path: childPath, node: child))
                }
            }
            result.children.append(child)
        }

        if mode == .automatic {
            var reader = BulkDirectoryReader()
            bulk: while true {
                try Task.checkCancellation()
                switch try reader.next(fd: fd) {
                case .entries(let entries, let unavailable):
                    result.unavailableEntries += unavailable
                    for entry in entries { append(name: entry.name, metadata: entry.metadata) }
                    if let progress = state.progress(path: job.path) { continuation.yield(progress) }
                case .end: return result
                case .failure(let code):
                    result.block = ScanBlock.forFailure(errno: code)
                    return result
                case .unsupported:
                    AppLog.scan.debug("Bulk enumeration unsupported, falling back to readdir: \(job.path)")
                    break bulk
                }
            }
        }
        // Never mix getattrlistbulk and readdir on one open file description.
        // A fresh descriptor also lets unsupported filesystems use POSIX safely.
        let enumerationFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard enumerationFD >= 0 else {
            result.block = ScanBlock.forFailure(errno: errno)
            return result
        }
        guard let dir = fdopendir(enumerationFD) else {
            let error = errno
            close(enumerationFD)
            result.block = ScanBlock.forFailure(errno: error)
            return result
        }
        defer { closedir(dir) }
        var entries = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { result.block = ScanBlock.forFailure(errno: errno) }
                break
            }
            entries += 1
            if entries % 256 == 0, let progress = state.progress(path: job.path) {
                continuation.yield(progress)
            }
            if entry.pointee.d_name.0 == 0x2E {
                let second = entry.pointee.d_name.1
                if second == 0 || (second == 0x2E && entry.pointee.d_name.2 == 0) { continue }
            }
            let type = entry.pointee.d_type
            if type != DT_DIR && type != DT_REG && type != DT_UNKNOWN { continue }

            var metadata = Darwin.stat()
            var nameBytes = entry.pointee.d_name
            let statOK = withUnsafeBytes(of: &nameBytes) { bytes in
                fstatat(fd, bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                        &metadata, AT_SYMLINK_NOFOLLOW) == 0
            }
            guard statOK else {
                result.unavailableEntries += 1
                continue
            }
            let name = withUnsafeBytes(of: &nameBytes) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            append(name: name, metadata: metadata)
        }
        return result
    }
}

/// Reads the `.git` pointer the scanner just enumerated and marks the folder as
/// a worktree root when it points at `<repo>/.git/worktrees/<name>`.
private func markWorktreeOwnerIfNeeded(_ job: DirectoryJob) {
    guard !job.node.isGitWorktree,
          let pointer = GitWorktreeDetector.parsePointer(inDirectory: job.path),
          pointer.isLinkedWorktree else { return }
    job.node.isGitWorktree = true
    AppLog.worktree.info("Worktree root found during scan: \(job.path) -> \(pointer.gitDir)")
}

/// The sealed system volume presents the writable data volume again under
/// `/System/Library/Templates/Data`, which mirrors `/System/Volumes/Data`.
/// Scanning both would double every protected folder in the warning.
private func isSyntheticDataDuplicate(_ path: String, mounts: MountTable) -> Bool {
    guard path == "/System/Library/Templates/Data" else { return false }
    return mounts.isMountPoint("/System/Volumes/Data")
}
