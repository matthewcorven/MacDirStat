import Foundation
import Testing
@testable import MacDirStat

/// Creates a real repository plus worktrees; used by the git-backed tests.
private struct WorktreeFixture {
    let root: URL
    let mainRepo: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        mainRepo = root.appendingPathComponent("main-repo")
        try FileManager.default.createDirectory(at: mainRepo, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], in: mainRepo)
        try Self.git(["-c", "user.name=T", "-c", "user.email=t@example.com",
                      "commit", "-q", "--allow-empty", "-m", "init"], in: mainRepo)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func worktree(_ name: String, branch: String? = nil) throws -> URL {
        let path = root.appendingPathComponent(name)
        var arguments = ["worktree", "add", "-q", path.path]
        if let branch { arguments.append(contentsOf: ["-b", branch]) }
        try Self.git(arguments, in: mainRepo)
        return path
    }

    func scan(worktrees: Bool = true) async throws -> FileNode {
        var scanned: FileNode?
        for await event in FileScanner(rootPath: root.path, detectGitWorktrees: worktrees).scan() {
            switch event {
            case .completed(let node): scanned = node
            case let .error(message): Issue.record("Scan error: \(message)")
            case .progress: break
            }
        }
        return try #require(scanned)
    }

    static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }
}

private let gitAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")

// MARK: - Path normalization

@Test func filePathNormalizationMatchesPOSIXCanonicalForm() {
    // `/tmp` is a symlink to `/private/tmp`; POSIX resolves it, so must we.
    #expect(FilePath.normalizePath("/tmp/../tmp/./x/") == "/private/tmp/x")
    #expect(FilePath.normalizePath("/tmp/missing/../..") == "/")
    #expect(FilePath.normalizePath("/") == "/")
    if !FileManager.default.fileExists(atPath: "/definitely/missing/path") {
        #expect(FilePath.normalizePath("/definitely/missing/path/") == "/definitely/missing/path")
    }
}

@Test func filePathJoinAndParent() {
    #expect(FilePath.join("/", "Users") == "/Users")
    #expect(FilePath.join("/Users", "core") == "/Users/core")
    #expect(FilePath.parent(of: "/Users/core") == "/Users")
    #expect(FilePath.parent(of: "/Users") == "/")
    #expect(FilePath.parent(of: "/") == nil)
}

/// The bug this fixes: the root logged as `/tmp/x` while children logged as
/// `/private/tmp/x/...`, which broke matching against git's paths.
@Test func scannedRootAndChildrenShareOneCanonicalPath() async throws {
    let fixture = try WorktreeFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent("nested/child"),
        withIntermediateDirectories: true)

    var scanned: FileNode?
    for await event in FileScanner(rootPath: fixture.root.path).scan() {
        if case .completed(let node) = event { scanned = node }
    }
    let root = try #require(scanned)
    #expect(root.path == FilePath.normalizePath(fixture.root.path))
    let nested = try #require(root.children.first { $0.name == "nested" })
    #expect(nested.path.hasPrefix(root.path + "/"))
    #expect(!nested.path.hasPrefix("/var/"))
    let child = try #require(nested.children.first { $0.name == "child" })
    #expect(child.path == FilePath.join(nested.path, "child"))
}

@Test func trailingSeparatorRootIsCanonicalized() async throws {
    let fixture = try WorktreeFixture()
    defer { fixture.remove() }
    var scanned: FileNode?
    for await event in FileScanner(rootPath: fixture.root.path + "/").scan() {
        if case .completed(let node) = event { scanned = node }
    }
    #expect(try #require(scanned).path == FilePath.normalizePath(fixture.root.path))
}

// MARK: - Pointer parsing

@Test func submodulesAndRelativePointersAreClassified() {
    let relative = GitWorktreeDetector.parsePointer(
        contents: "gitdir: ../main/.git/worktrees/feature\n", inDirectory: "/scans/feature")
    #expect(relative?.isLinkedWorktree == true)
    #expect(relative?.mainRepo == "/scans/main")
    #expect(relative?.worktreeName == "feature")

    let submodule = GitWorktreeDetector.parsePointer(
        contents: "gitdir: ../main/.git/modules/vendor/lib\n", inDirectory: "/scans/repo/vendor/lib")
    #expect(submodule?.isLinkedWorktree == false)
}

@Test func gitPointerParsingReadsOnlyTheFirstLine() {
    let pointer = GitWorktreeDetector.parsePointer(
        contents: "gitdir: /repo/.git/worktrees/name\r\nextra: ignored\n", inDirectory: "/x")
    #expect(pointer?.worktreeName == "name")
    #expect(GitWorktreeDetector.parsePointer(contents: "no pointer here", inDirectory: "/x") == nil)
    #expect(GitWorktreeDetector.parsePointer(contents: "gitdir:   ", inDirectory: "/x") == nil)
}

@Test func gitFileSymlinkIsNotFollowed() throws {
    let fixture = try WorktreeFixture()
    defer { fixture.remove() }
    let real = fixture.root.appendingPathComponent("real.git")
    try Data("gitdir: /tmp/x/.git/worktrees/y\n".utf8).write(to: real)
    let worktree = fixture.root.appendingPathComponent("linked")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    #expect(symlink(real.path, worktree.appendingPathComponent(".git").path) == 0)
    // O_NOFOLLOW refuses the symlink so a planted pointer can't mark the folder.
    #expect(GitWorktreeDetector.parsePointer(inDirectory: worktree.path) == nil)
}

@Test func nestedWorktreesAreCountedOnce() {
    let root = FileNode(inode: 1, name: "/", isDirectory: true)
    let outer = FileNode(inode: 2, name: "outer", isDirectory: true)
    let inner = FileNode(inode: 3, name: "inner", isDirectory: true)
    outer.isGitWorktree = true
    inner.isGitWorktree = true
    outer.addChild(inner)
    root.addChild(outer)
    root.computeAggregates()
    #expect(GitWorktreeDetector.worktreeRoots(in: root).map(\.name) == ["outer"])
}

@Test func porcelainParsingHandlesSpacesBranchesAndPrunableEntries() {
    let output = """
    worktree /Users/me/Code/my repo
    HEAD abc123
    branch refs/heads/feature/one

    worktree /Users/me/Code/gone
    HEAD abc123
    branch refs/heads/drop.me
    prunable gitdir file points to non-existent location

    worktree /Users/me/Code/linked
    HEAD abc123
    detached
    """
    let entries = GitWorktreeEntry.parsePorcelain(output)
    #expect(entries.count == 3)
    #expect(entries[0].path == "/Users/me/Code/my repo")
    #expect(entries[0].branchName == "feature/one")
    #expect(!entries[0].isPrunable)
    #expect(entries[1].branchName == "drop.me")
    #expect(entries[1].isPrunable)
    #expect(entries[1].pruneReason != nil)
    #expect(entries[2].branch == .detached)
}

// MARK: - Unused and safe-delete decisions

@Test func unusedCandidateRequiresCleanAndStaleOrDetached() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var record = WorktreeRecord(path: "/x/clean-old")
    record.uncommittedChanges = 0
    record.latestChange = now.addingTimeInterval(-20 * 24 * 3600)
    #expect(record.isUnusedCandidate(staleThreshold: 14 * 24 * 3600, now: now))
    #expect(record.isSafeToDelete)

    record.latestChange = now.addingTimeInterval(-3600)
    #expect(!record.isUnusedCandidate(staleThreshold: 14 * 24 * 3600, now: now))

    record.isDetached = true
    #expect(record.isUnusedCandidate(staleThreshold: 14 * 24 * 3600, now: now))

    record.uncommittedChanges = 1
    #expect(!record.isUnusedCandidate(staleThreshold: 14 * 24 * 3600, now: now))
    #expect(!record.isSafeToDelete)

    var prunable = WorktreeRecord(path: "/x/gone")
    prunable.isPrunable = true
    #expect(prunable.isSafeToDelete)
    #expect(!prunable.isUnusedCandidate(staleThreshold: 0, now: now))
}

@Test @MainActor func deleteIsBlockedWhileChangesAreUncommitted() async throws {
    let fixture = try WorktreeFixture()
    defer { fixture.remove() }
    let dirty = try fixture.worktree("dirty", branch: "dirty")
    try Data("uncommitted\n".utf8).write(to: dirty.appendingPathComponent("notes.txt"))

    let scanned = try await fixture.scan()
    let appState = AppState()
    appState.detectGitWorktrees = true
    appState.setScanCompleted(root: scanned)
    try await appState.waitForWorktreeAnalysis()

    let record = try #require(appState.worktreeRecords.first { $0.path.hasSuffix("dirty") })
    #expect(record.uncommittedChanges == 1)
    #expect(appState.deleteBlockReason(for: record.path, skipTrash: false) != nil)
    #expect(appState.deleteBlockReason(for: record.path, skipTrash: true) == nil)

    // The guard must actually protect the folder.
    let node = try #require(appState.worktreeNode(for: record.path))
    appState.deleteWorktree(node)
    #expect(FileManager.default.fileExists(atPath: dirty.path))
}


// MARK: - Git-backed scans

/// Marks every file in a tree as modified long ago, so the stale window applies.
private func ageTree(at directory: URL, to date: Date) throws {
    let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in true })
    while let url = enumerator?.nextObject() as? URL {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
}

@Test(.enabled(if: gitAvailable))
func analyzerReportsBranchChangesAndUnusedWorktrees() async throws {
    let fixture = try WorktreeFixture()
    defer { fixture.remove() }
    let cleanOld = try fixture.worktree("clean-old", branch: "clean-old")
    _ = try fixture.worktree("fresh", branch: "fresh")
    let dirty = try fixture.worktree("dirty", branch: "dirty")
    try Data("x\n".utf8).write(to: dirty.appendingPathComponent("notes.txt"))
    let detached = try fixture.worktree("detached", branch: "detached")
    try WorktreeFixture.git(["checkout", "-q", "--detach"], in: detached)
    try ageTree(at: cleanOld, to: Date().addingTimeInterval(-40 * 24 * 3600))
    try ageTree(at: fixture.mainRepo, to: Date().addingTimeInterval(-40 * 24 * 3600))

    let scanned = try await fixture.scan()
    var options = WorktreeAnalyzer.Options()
    options.staleThreshold = 14 * 24 * 3600
    let records = WorktreeAnalyzer.analyze(root: scanned, options: options)
    let byName = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })

    #expect(Set(byName.keys) == ["clean-old", "fresh", "dirty", "detached"])
    #expect(byName["fresh"]?.branch == "fresh")
    #expect(byName["fresh"]?.uncommittedChanges == 0)
    #expect(byName["fresh"]?.isUnusedCandidate(staleThreshold: options.staleThreshold) == false)
    #expect(byName["clean-old"]?.uncommittedChanges == 0)
    #expect(byName["clean-old"]?.isUnusedCandidate(staleThreshold: options.staleThreshold) == true)
    #expect(byName["dirty"]?.uncommittedChanges == 1)
    #expect(byName["dirty"]?.isSafeToDelete == false)
    #expect(byName["dirty"]?.isUnusedCandidate(staleThreshold: options.staleThreshold) == false)
    #expect(byName["detached"]?.isDetached == true)
    #expect(byName["detached"]?.isUnusedCandidate(staleThreshold: options.staleThreshold) == true)
    // The main working tree is a repository, not a linked worktree.
    #expect(byName["main-repo"] == nil)
}

@Test(.enabled(if: gitAvailable))
func prunableEntriesAreReportedEvenThoughTheScanCannotSeeThem() async throws {
    let fixture = try WorktreeFixture()
    defer { fixture.remove() }
    let gone = try fixture.worktree("gone", branch: "gone")
    try FileManager.default.removeItem(at: gone)

    let scanned = try await fixture.scan()
    let records = WorktreeAnalyzer.analyze(root: scanned)
    let prunable = try #require(records.first { $0.name == "gone" })
    #expect(prunable.isPrunable)
    #expect(prunable.pruneReason != nil)
    #expect(prunable.isSafeToDelete)
    #expect(prunable.mainRepository != nil)

    // Pruning removes the registration from git.
    let runner = try #require(GitRunner.shared)
    try WorktreeAnalyzer.prune(in: fixture.mainRepo.path, runner: runner)
    let remaining = try WorktreeAnalyzer.listWorktrees(in: fixture.mainRepo.path, runner: runner)
    #expect(!remaining.contains { $0.isPrunable })
}

@Test(.enabled(if: gitAvailable))
func wrongGitDirPointerIsReportedAsALinkIssue() async throws {
    let fixture = try WorktreeFixture()
    defer { fixture.remove() }
    let worktree = try fixture.worktree("linked", branch: "linked")
    // Point the worktree at a gitdir that doesn't exist, as a relocation would.
    try Data("gitdir: \(fixture.root.path)/moved-away/.git/worktrees/linked\n".utf8)
        .write(to: worktree.appendingPathComponent(".git"))

    let scanned = try await fixture.scan()
    let records = WorktreeAnalyzer.analyze(root: scanned)
    let record = try #require(records.first { $0.name == "linked" })
    #expect(record.gitLinkIssue != nil)
}

@Test(.enabled(if: gitAvailable))
func worktreeOnAnotherVolumeIsReportedWhenTheScanDoesNotDescend() async throws {
    // Model a second volume with a mount point: the scanner lists the mount
    // folder but never descends into it, so a worktree living there is invisible
    // to the scan. git still knows about it, so it must appear in the report.
    let fixture = try WorktreeFixture()
    defer {
        try? FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent("mounted"))
        fixture.remove()
    }
    let mountPoint = fixture.root.appendingPathComponent("mounted")
    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    let worktreePath = mountPoint.appendingPathComponent("linked")
    try WorktreeFixture.git(["worktree", "add", "-q", worktreePath.path, "-b", "away"],
                            in: fixture.mainRepo)

    var scanned: FileNode?
    let table = MountTable(mountPoints: [
        FilePath.normalizePath(fixture.root.path),
        FilePath.normalizePath(mountPoint.path),
    ])
    for await event in FileScanner(
        rootPath: fixture.root.path,
        detectGitWorktrees: true,
        mounts: table
    ).scan() {
        if case .completed(let node) = event { scanned = node }
    }
    let root = try #require(scanned)
    let mounted = try #require(root.children.first { $0.name == "mounted" })
    #expect(mounted.children.isEmpty, "the scan must not descend into another volume")

    let records = WorktreeAnalyzer.analyze(root: root)
    let away = try #require(records.first { $0.path.hasSuffix("/mounted/linked") },
                            "git reports the worktree the scan could not see: \(records.map(\.path))")
    #expect(away.isClean == true)
    #expect(away.scanMissedReason != nil)
    #expect(records.filter { $0.path.hasSuffix("/mounted/linked") }.count == 1)
}
