import Foundation

/// One entry of `git worktree list --porcelain`.
struct GitWorktreeEntry: Sendable, Equatable, Identifiable {
    enum BranchRef: Sendable, Equatable {
        case branch(String)
        case detached
    }

    let path: String
    let head: String?
    var branch: BranchRef = .detached
    var isBare = false
    var isPrunable = false
    var pruneReason: String?

    var id: String { path }
    var branchName: String? {
        if case let .branch(name) = branch { return name }
        return nil
    }

    /// Parses porcelain blocks separated by blank lines. Values are always
    /// space-prefixed relative to their key, and paths may contain spaces, so
    /// each line is split on its first space only.
    static func parsePorcelain(_ output: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        for block in output.components(separatedBy: "\n\n") {
            var path: String?
            var head: String?
            var branch: BranchRef = .detached
            var isBare = false
            var isPrunable = false
            var pruneReason: String?
            for line in block.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    // Show the short name; `refs/heads/foo` reads as `foo`.
                    for prefix in ["refs/heads/", "refs/"] where ref.hasPrefix(prefix) {
                        branch = .branch(String(ref.dropFirst(prefix.count)))
                        break
                    }
                    if case .detached = branch { branch = .branch(ref) }
                } else if line == "detached" {
                    branch = .detached
                } else if line == "bare" {
                    isBare = true
                } else if line == "prunable" || line.hasPrefix("prunable ") {
                    isPrunable = true
                    let reason = String(line.dropFirst("prunable".count))
                        .trimmingCharacters(in: .whitespaces)
                    pruneReason = reason.isEmpty ? nil : reason
                }
            }
            guard let path else { continue }
            entries.append(GitWorktreeEntry(
                path: path,
                head: head,
                branch: branch,
                isBare: isBare,
                isPrunable: isPrunable,
                pruneReason: pruneReason
            ))
        }
        return entries
    }
}

enum GitStatusReader {
    /// Branch/HEAD summary and whether the worktree has uncommitted work.
    /// `--untracked-files=normal` also counts brand-new files, which would be
    /// destroyed by a delete, so they must block it.
    struct Snapshot: Sendable, Equatable {
        var branch: GitWorktreeEntry.BranchRef
        var isDirty: Bool
    }

    static func snapshot(of directory: String, runner: GitRunner) throws -> Snapshot {
        let output = try runner.run([
            "status", "--porcelain=v1", "--branch", "--untracked-files=normal", "--no-renames",
        ], in: directory)
        var branch: GitWorktreeEntry.BranchRef = .detached
        var isDirty = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("## ") {
                let header = line.dropFirst(3)
                if header.hasPrefix("HEAD (no branch)") {
                    branch = .detached
                } else {
                    // `main...origin/main [ahead 1]` -> `main`; dots are legal in
                    // branch names, so split on the three-dot upstream separator.
                    var name = header.components(separatedBy: "...").first ?? String(header)
                    if name.hasPrefix("No commits yet on ") {
                        name = String(name.dropFirst("No commits yet on ".count))
                    }
                    branch = .branch(name)
                }
                continue
            }
            if !line.isEmpty { isDirty = true }
        }
        return Snapshot(branch: branch, isDirty: isDirty)
    }
}
