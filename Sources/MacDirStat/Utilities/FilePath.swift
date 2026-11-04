import Foundation

/// Path helpers shared by the scanner and the git integration.
enum FilePath {
    /// Canonical form used everywhere a path is stored, logged, compared or
    /// handed back to the UI.
    ///
    /// POSIX resolves symlinks before returning entries, so a scan started at
    /// `/tmp/x` enumerates `/private/tmp/x/...`; git reports the same physical
    /// form. Normalizing the root once keeps the whole tree, Copy Path and git's
    /// output in agreement. Returns the input (minus trailing separators) when
    /// the path does not exist.
    static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// Normalizes without requiring the path to exist. Resolves symlinks per
    /// component (POSIX style) and collapses `.`/`..`, so `/tmp/../tmp/x` and
    /// `/private/tmp/x` agree even when the final component is missing.
    static func normalizePath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        // `standardizedFileURL` doesn't resolve symlinks; walk up to the deepest
        // existing ancestor, canonicalize that, and re-append the remainder.
        var existing = standardized
        var remainder: [String] = []
        while existing != "/", !FileManager.default.fileExists(atPath: existing) {
            let name = (existing as NSString).lastPathComponent
            remainder.insert(name, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = normalized(existing)
        return remainder.reduce(resolved) { join($0, $1) }
    }

    /// Appends a single name without doubling the separator at `/`.
    static func join(_ directory: String, _ name: String) -> String {
        if name.isEmpty { return directory }
        if directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// The parent directory, or `nil` at the filesystem root.
    static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let index = trimmed.lastIndex(of: "/") else { return nil }
        let parent = String(trimmed[..<index])
        return parent.isEmpty ? "/" : parent
    }
}
