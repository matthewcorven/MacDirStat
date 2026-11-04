import CoreGraphics
import Foundation
import Testing
@testable import MacDirStat

/// Builds a small tree: one worktree with real content plus an ordinary folder.
private func makeTree() -> (root: FileNode, worktree: FileNode, plain: FileNode) {
    let root = FileNode(inode: 1, name: "/scan", isDirectory: true)
    let worktree = FileNode(inode: 2, name: "feature-wt", isDirectory: true, allocatedSize: 4096)
    let plain = FileNode(inode: 3, name: "plain", isDirectory: true, allocatedSize: 4096)
    // Give the worktree most of the area so it survives the minimum-area cutoff.
    let big = FileNode(inode: 4, name: "build.bin", isDirectory: false,
                       allocatedSize: 8_000_000, category: .applications)
    let nested = FileNode(inode: 5, name: "Sources", isDirectory: true, allocatedSize: 4096)
    let source = FileNode(inode: 6, name: "main.swift", isDirectory: false,
                          allocatedSize: 1_000_000, category: .code)
    let plainFile = FileNode(inode: 7, name: "notes.txt", isDirectory: false,
                             allocatedSize: 500_000, category: .documents)
    worktree.addChild(big)
    worktree.addChild(nested)
    nested.addChild(source)
    plain.addChild(plainFile)
    root.addChild(worktree)
    root.addChild(plain)
    root.computeAggregates()
    worktree.isGitWorktree = true
    return (root, worktree, plain)
}

private func color(_ node: FileNode, in items: [TreemapItem]) -> CGColor? {
    items.first { $0.node === node }?.color
}

private func isWorktreeColor(_ cgColor: CGColor) -> Bool {
    let base = GitWorktreeStyle.color.resolve(in: .init())
    guard let components = cgColor.components, components.count >= 3 else { return false }
    let r = components[0], g = components[1], b = components[2]
    // The renderer darkens by depth, so compare ratios within the color.
    let ratioG = Double(g / max(r, 0.0001))
    let ratioB = Double(b / max(r, 0.0001))
    let baseRatioG = Double(base.green / max(base.red, 0.0001))
    let baseRatioB = Double(base.blue / max(base.red, 0.0001))
    return abs(ratioG - baseRatioG) < 0.5 && abs(ratioB - baseRatioB) < 0.5 && g > r
}

private func layout(_ root: FileNode, highlight: Bool = true) -> [TreemapItem] {
    TreemapLayoutEngine(minPixelArea: 1).layout(
        root: root,
        in: TreemapRect(x: 0, y: 0, width: 800, height: 600),
        sizeMetric: .allocatedSize,
        highlightWorktrees: highlight)
}

/// The whole worktree should read as one block. Previously only the worktree's
/// own directory cell was tinted (a few KB), while its gigabytes of content kept
/// their file-type colors, so users could not find worktrees in the treemap.
@Test func worktreeContentsInheritTheWorktreeColor() {
    let (root, worktree, plain) = makeTree()
    let items = layout(root)

    let worktreeItems = items.filter { $0.node === worktree || isDescendant($0.node, of: worktree) }
    #expect(worktreeItems.count >= 4)
    for item in worktreeItems {
        #expect(isWorktreeColor(item.color), "\(item.node.name) should be tinted as worktree")
    }

    // A sibling folder and its file keep their category colors.
    #expect(!isWorktreeColor(try! #require(color(plain, in: items))))
    let plainFile = try! #require(plain.children.first)
    #expect(!isWorktreeColor(try! #require(color(plainFile, in: items))))
}

@Test func worktreeTintIsRemovedWhenHighlightingIsOff() {
    let (root, worktree, _) = makeTree()
    let items = layout(root, highlight: false)
    for item in items where item.node === worktree || isDescendant(item.node, of: worktree) {
        #expect(!isWorktreeColor(item.color))
    }
}

/// A nested worktree must not leak its tint to the surrounding repository.
@Test func nestedWorktreeTintDoesNotEscape() {
    let root = FileNode(inode: 1, name: "/scan", isDirectory: true)
    let repo = FileNode(inode: 2, name: "repo", isDirectory: true, allocatedSize: 4096)
    let inner = FileNode(inode: 3, name: "wt", isDirectory: true, allocatedSize: 4096)
    let outerFile = FileNode(inode: 4, name: "repo.txt", isDirectory: false,
                             allocatedSize: 900_000, category: .documents)
    let innerFile = FileNode(inode: 5, name: "wt.txt", isDirectory: false,
                             allocatedSize: 400_000, category: .documents)
    inner.addChild(innerFile)
    repo.addChild(inner)
    repo.addChild(outerFile)
    root.addChild(repo)
    root.computeAggregates()
    inner.isGitWorktree = true

    let items = layout(root)
    #expect(isWorktreeColor(try! #require(color(inner, in: items))))
    #expect(isWorktreeColor(try! #require(color(innerFile, in: items))))
    #expect(!isWorktreeColor(try! #require(color(repo, in: items))))
    #expect(!isWorktreeColor(try! #require(color(outerFile, in: items))))
}

private func isDescendant(_ node: FileNode, of ancestor: FileNode) -> Bool {
    var current = node.parent
    while let candidate = current {
        if candidate === ancestor { return true }
        current = candidate.parent
    }
    return false
}

/// The inspector asks for a category breakdown on every view update, including
/// window activation. Walking millions of nodes there froze the UI for ~280ms
/// per redraw, so the totals are precomputed with the other aggregates.
@Test func categoryBreakdownUsesPrecomputedTotals() {
    let root = FileNode(inode: 1, name: "/scan", isDirectory: true)
    let nested = FileNode(inode: 2, name: "sub", isDirectory: true, allocatedSize: 4096)
    root.addChild(FileNode(inode: 3, name: "a.pdf", isDirectory: false,
                           ownSize: 1000, allocatedSize: 4096, category: .documents))
    root.addChild(nested)
    nested.addChild(FileNode(inode: 4, name: "c.pdf", isDirectory: false,
                             ownSize: 500, allocatedSize: 4096, category: .documents))
    nested.addChild(FileNode(inode: 5, name: "b.mp4", isDirectory: false,
                             ownSize: 200, allocatedSize: 8192, category: .video))
    root.computeAggregates()

    // Totals roll up through nesting, for both metrics.
    #expect(root.categorySizes[.documents] == 8192)
    #expect(root.categorySizes[.video] == 8192)
    #expect(root.categorySizesByFileSize[.documents] == 1500)
    #expect(nested.categorySizes[.documents] == 4096)

    // The API keeps returning what the inspector renders.
    #expect(root.categoryBreakdown().contains { $0.category == .documents })
    #expect(root.categoryBreakdown(metric: .fileSize).contains { $0.category == .video })
}

/// The inspector's Category Breakdown should account for worktrees as their own
/// row, and the rows must still add up to the folder's total.
@Test func categoryBreakdownReportsWorktreesAsTheirOwnCategory() {
    let root = FileNode(inode: 1, name: "/scan", isDirectory: true)
    let tree = FileNode(inode: 2, name: "feature-wt", isDirectory: true, allocatedSize: 4096)
    let inside = FileNode(inode: 3, name: "main.swift", isDirectory: false,
                          ownSize: 900_000, allocatedSize: 1_000_000, category: .code)
    let outside = FileNode(inode: 4, name: "notes.txt", isDirectory: false,
                           ownSize: 400_000, allocatedSize: 500_000, category: .documents)
    tree.addChild(inside)
    root.addChild(tree)
    root.addChild(outside)
    root.computeAggregates()
    tree.isGitWorktree = true
    root.computeAggregates()

    let breakdown = root.categoryBreakdown()
    #expect(breakdown.first?.category == .gitWorktrees)
    #expect(breakdown.first?.size == tree.totalAllocatedSize)
    // The worktree's files moved out of Code and into the worktree row.
    #expect(breakdown.contains { $0.category == .code } == false)
    #expect(breakdown.contains { $0.category == .documents && $0.size == 500_000 })

    // Nothing is double-counted.
    #expect(breakdown.reduce(0) { $0 + $1.size } == root.totalAllocatedSize)

    // Selecting the worktree itself reads as 100% worktree.
    #expect(tree.categoryBreakdown().map(\.category) == [.gitWorktrees])
    #expect(tree.categoryBreakdown().first?.size == tree.totalAllocatedSize)

    // Logical sizes follow the same rule.
    #expect(root.categoryBreakdown(metric: .fileSize).first?.category == .gitWorktrees)
}
