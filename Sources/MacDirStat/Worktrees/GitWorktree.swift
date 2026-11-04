import Foundation
import SwiftUI

/// Shared appearance for linked git worktrees so the same color is used in the
/// treemap, the inspector, and the legend on every scan and in every session.
enum GitWorktreeStyle {
    static let color = Color(red: 0.10, green: 0.84, blue: 0.92)
    static let sfSymbol = "arrow.triangle.branch"
    static let legendTitle = "Git Worktrees"
}

/// What a worktree's `.git` file points at.
struct GitPointer: Sendable, Equatable {
    /// Absolute path after resolving a relative `gitdir:` against the worktree.
    let gitDir: String
    /// The main repository, or `nil` when the pointer isn't a linked worktree
    /// (`.../.git/worktrees/<name>`).
    let mainRepo: String?
    let worktreeName: String?

    var isLinkedWorktree: Bool { mainRepo != nil }
}

enum GitWorktreeDetector {
    /// Marks every directory that is the root of a linked git worktree.
    ///
    /// A linked worktree (and a submodule) has a `.git` *file* instead of a
    /// directory. Worktrees point it at `<main-repo>/.git/worktrees/<name>`,
    /// while submodules point at `<main-repo>/.git/modules/<name>`.
    @discardableResult
    static func markWorktrees(in root: FileNode) -> [FileNode] {
        var found: [FileNode] = []
        walk(root, path: root.path) { node, path in
            if node.isGitWorktree {
                found.append(node)
                return
            }
            guard hasGitFile(node),
                  let pointer = parsePointer(inDirectory: path),
                  pointer.isLinkedWorktree else { return }
            node.isGitWorktree = true
            found.append(node)
        }
        return found
    }

    static func clearWorktreeMarks(in root: FileNode) {
        walk(root, path: root.path) { node, _ in
            node.isGitWorktree = false
        }
    }

    /// Topmost worktrees, so nested worktrees are counted once in the total.
    static func worktreeRoots(in root: FileNode) -> [FileNode] {
        var roots: [FileNode] = []
        func visit(_ node: FileNode) {
            if node.isGitWorktree {
                roots.append(node)
                return
            }
            for child in node.children where child.isDirectory {
                visit(child)
            }
        }
        visit(root)
        return roots
    }

    /// Parses the small `.git` file format: a single `gitdir: <path>` line.
    static func parsePointer(inDirectory directory: String) -> GitPointer? {
        guard let contents = readGitFile(at: FilePath.join(directory, ".git")) else { return nil }
        return parsePointer(contents: contents, inDirectory: directory)
    }

    /// `gitdir:` may be absolute or relative to the worktree directory, and the
    /// stored path is not guaranteed to be normalized.
    static func parsePointer(contents: String, inDirectory directory: String) -> GitPointer? {
        guard let firstLine = contents.split(whereSeparator: \.isNewline).first else { return nil }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("gitdir:") else { return nil }
        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return nil }

        let resolved = URL(
            fileURLWithPath: rawPath,
            relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
        ).standardizedFileURL
        let gitDir = FilePath.normalized(resolved.path)

        // `<main>/.git/worktrees/<name>` identifies a linked worktree. Submodules
        // live under `.git/modules` and are not worktrees.
        let components = (gitDir as NSString).pathComponents
        for index in components.indices.dropLast(2) where components[index] == ".git" {
            guard components[index + 1] == "worktrees" else { continue }
            // Everything before `.git` is the repository root.
            let mainRepoPath = NSString.path(withComponents: Array(components[1..<index]))
            return GitPointer(
                gitDir: gitDir,
                mainRepo: FilePath.normalized("/" + mainRepoPath),
                worktreeName: components[index + 2]
            )
        }
        return GitPointer(gitDir: gitDir, mainRepo: nil, worktreeName: nil)
    }

    /// Backwards-compatible predicate kept for the parsing tests.
    static func isLinkedWorktree(gitFileContents: String, inDirectory directory: String) -> Bool {
        parsePointer(contents: gitFileContents, inDirectory: directory)?.isLinkedWorktree ?? false
    }

    static func hasGitFile(_ node: FileNode) -> Bool {
        node.children.contains { $0.name == ".git" && !$0.isDirectory }
    }

    static func hasGitDirectory(_ node: FileNode) -> Bool {
        node.children.contains { $0.name == ".git" && $0.isDirectory }
    }

    /// Reads at most one metadata page; `.git` files contain only a short path.
    /// `O_NOFOLLOW` avoids reading through a symlink planted in place of the file.
    static func readGitFile(at path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var metadata = Darwin.stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    static func walk(_ node: FileNode, path: String, visit: (FileNode, String) -> Void) {
        guard node.isDirectory else { return }
        visit(node, path)
        for child in node.children where child.isDirectory {
            walk(child, path: FilePath.join(path, child.name), visit: visit)
        }
    }
}
