import Foundation
import os

/// Structured diagnostics for Unified Logging. View them live with:
///
///     log stream --level debug --style compact \
///       --predicate 'subsystem == "io.github.phalladar.MacDirStat"'
///
/// or after the fact with `log show --info --debug --last 10m ...`.
///
/// `.notice` records lifecycle and totals, `.info` records per-folder results
/// and UI events, and `.debug` records high-volume detail (progress, layout).
enum AppLog {
    static let subsystem = "io.github.phalladar.MacDirStat"

    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let worktree = Logger(subsystem: subsystem, category: "worktree")
    static let layout = Logger(subsystem: subsystem, category: "layout")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let state = Logger(subsystem: subsystem, category: "state")

    static func bytes(_ value: Int64) -> String {
        "\(value) B (\(ByteFormatter.string(from: value)))"
    }

    static func duration(_ value: Duration) -> String {
        let components = value.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.3fs", seconds)
    }
}
