import Foundation
import Testing
@testable import MacDirStat

/// A scan that reports every root-only folder as "incomplete" produces a
/// permanent warning no action can clear, which is what happened on a full-disk
/// scan that flagged 241 folders.
@Test func rootOnlyFoldersDoNotCountAsIncomplete() {
    // /usr/sbin/authserver is drwx------ root:wheel on a stock install.
    let block = ScanBlock.forOpenFailure(errno: EACCES, path: "/usr/sbin/authserver")
    #expect(block.kind == .permissions)
    #expect(!block.countsAsIncomplete)
    #expect(block.shortLabel != nil)
}

/// macOS reports EPERM for TCC/SIP-protected paths whose mode bits allow
/// reading. Those are exactly the folders Full Disk Access addresses.
@Test func systemProtectedEPERMIsReportable() {
    let block = ScanBlock.forOpenFailure(errno: EPERM, path: "/private/var/db/DumpPanic")
    #expect(block.kind == .systemProtected)
    #expect(block.countsAsIncomplete)
    #expect(block.message.contains("Full Disk Access"))
}

@Test func cloudAndMirrorFoldersAreExpected() {
    #expect(!ScanBlock.cloudOnly.countsAsIncomplete)
    #expect(!ScanBlock.forFailure(errno: EDEADLK).countsAsIncomplete)
    let mirror = ScanBlock(kind: .syntheticDuplicate, message: "mirror")
    #expect(!mirror.countsAsIncomplete)
}

@Test func unexpectedFailuresRemainReportable() {
    #expect(ScanBlock.forFailure(errno: EIO).countsAsIncomplete)
    #expect(ScanBlock.changedMidScan.countsAsIncomplete)
    #expect(ScanBlock.forFailure(errno: ENOENT).countsAsIncomplete)
}

@Test func aggregateCountsSeparateExpectedFromActionable() {
    let root = FileNode(inode: 1, name: "/", isDirectory: true)
    let actionable = FileNode(inode: 2, name: "protected", isDirectory: true)
    actionable.scanIssue = ScanBlock.forOpenFailure(errno: EPERM, path: "/x").message
    let expected = FileNode(inode: 3, name: "authserver", isDirectory: true)
    expected.scanIssue = ScanBlock.permissions.message
    expected.scanIssueCountsAsIncomplete = false
    let mirror = FileNode(inode: 4, name: "Data", isDirectory: true)
    mirror.scanIssue = "mirror"
    mirror.scanIssueCountsAsIncomplete = false
    mirror.scanSkippedAsDuplicate = true
    root.addChild(actionable)
    root.addChild(expected)
    root.addChild(mirror)
    root.computeAggregates()

    #expect(root.unscannedDirectoryCount == 1)
    #expect(root.expectedUnreadableDirectoryCount == 1)
    #expect(root.duplicateMirrorDirectoryCount == 1)
}

/// The writable data volume is visible twice on a sealed boot volume; walking
/// both doubles every protected folder and cannot be fixed by the user.
@Test func dataVolumeMirrorIsSkippedOnlyWhenPresent() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }

    // The mirror rule only fires for the exact synthetic path.
    let scanner = FileScanner(
        rootPath: root.path,
        detectGitWorktrees: false,
        mounts: MountTable(mountPoints: [FilePath.normalizePath(root.path)])
    )
    var scanned: FileNode?
    for await event in scanner.scan() {
        if case .completed(let node) = event { scanned = node }
    }
    #expect(try #require(scanned).duplicateMirrorDirectoryCount == 0)
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scan-incomplete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
