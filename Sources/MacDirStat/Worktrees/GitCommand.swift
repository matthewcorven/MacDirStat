import Foundation

enum GitCommandError: Error, Equatable {
    case unavailable
    case failed(status: Int32, message: String)
    case timedOut([String])
}

/// Runs the system `git` binary without a shell.
///
/// Everything here is local-only: prompts are disabled, optional locks are off
/// so a background `git status` can't block the user's own git commands, and a
/// timeout keeps a stuck network filesystem from hanging the app.
struct GitRunner: Sendable {
    let executablePath: String
    var timeout: Duration = .seconds(20)

    /// Finds git once per process. `git` may not be on the app's PATH when
    /// launched from Finder, so known install locations are probed too.
    static let shared: GitRunner? = {
        let candidates = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return GitRunner(executablePath: path)
        }
        // Last resort: ask the login shell's PATH, which is what `git` resolves to.
        if let path = searchPATH() { return GitRunner(executablePath: path) }
        return nil
    }()

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: shared?.executablePath ?? "/usr/bin/git")
    }

    /// Standard output of a successful command, trimmed of trailing newlines.
    /// Non-zero exits throw so callers can distinguish "not a repository" from
    /// "no output".
    func run(_ arguments: [String], in directory: String?) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw GitCommandError.unavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitCommandError.failed(status: -1, message: error.localizedDescription)
        }

        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            process.terminate()
            throw GitCommandError.timedOut(arguments)
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitCommandError.failed(status: process.terminationStatus, message: message)
        }
        return String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    private static func searchPATH() -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            + ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]
        return directories
            .map { $0 + "/git" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
