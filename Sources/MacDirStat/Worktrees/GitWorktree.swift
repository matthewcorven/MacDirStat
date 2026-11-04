import Foundation
import SwiftUI

/// Shared appearance for linked git worktrees so the same color is used in the
/// treemap, the inspector, and the legend on every scan and in every session.
enum GitWorktreeStyle {
    static let color = Color(red: 0.10, green: 0.84, blue: 0.92)
    static let sfSymbol = "arrow.triangle.branch"
    static let legendTitle = "Git Worktrees"
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
            guard hasGitFile(node) else { return }
            let gitFilePath = join(path, ".git")
            guard let contents = readGitFile(at: gitFilePath),
                  isLinkedWorktree(gitFileContents: contents, inDirectory: path) else { return }
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
    static func isLinkedWorktree(gitFileContents: String, inDirectory directory: String) -> Bool {
        guard let firstLine = gitFileContents.split(whereSeparator: \.isNewline).first else { return false }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("gitdir:") else { return false }
        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return false }

        let resolved = URL(
            fileURLWithPath: rawPath,
            relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
        ).standardizedFileURL
        let components = resolved.pathComponents
        for index in components.indices.dropLast() where components[index] == ".git" {
            if components[index + 1] == "worktrees" { return true }
        }
        return false
    }

    private static func walk(_ node: FileNode, path: String, visit: (FileNode, String) -> Void) {
        guard node.isDirectory else { return }
        visit(node, path)
        for child in node.children where child.isDirectory {
            walk(child, path: join(path, child.name), visit: visit)
        }
    }

    private static func hasGitFile(_ node: FileNode) -> Bool {
        node.children.contains { $0.name == ".git" && !$0.isDirectory }
    }

    /// Reads at most one metadata page; `.git` files contain only a short path.
    /// `O_NOFOLLOW` avoids reading through a symlink planted in place of the file.
    private static func readGitFile(at path: String) -> String? {
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

    private static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}
