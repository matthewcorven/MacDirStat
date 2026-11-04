import Foundation
import os

/// Structured diagnostics for Unified Logging. View them live with:
///
///     log stream --level debug --style compact \
///       --predicate 'subsystem == "io.github.phalladar.MacDirStat"'
///
/// or after the fact with `log show --info --debug --last 10m ...`.
///
/// Logging is opt-in: it stays silent until the user enables it in Settings.
/// The switch applies to calls made after it changes, so a session that starts
/// with logging off has no record of its own startup.
///
/// `.notice` records lifecycle and totals, `.info` records per-folder results
/// and UI events, and `.debug` records high-volume detail (progress, layout).
enum AppLog {
    static let subsystem = "io.github.phalladar.MacDirStat"
    /// Tests run in-process with the app code, so give them their own subsystem.
    static let testSubsystemSuffix = ".tests"

    static let isTestProcess: Bool = {
        let process = ProcessInfo.processInfo
        // swift-testing runs through swiftpm-testing-helper; XCTest runs inside
        // an .xctest bundle. Either way, don't write to the app's subsystem.
        return process.processName == "swiftpm-testing-helper"
            || process.arguments.contains { $0.contains(".xctest") }
            || NSClassFromString("XCTestCase") != nil
            || process.environment["XCTestConfigurationFilePath"] != nil
    }()

    static var resolvedSubsystem: String {
        isTestProcess ? subsystem + testSubsystemSuffix : subsystem
    }

    /// Persisted switch shared with the Settings dialog.
    static let enabledDefaultsKey = "enableLogging"

    /// Holds the value once the app reports it, so log calls don't touch
    /// `UserDefaults` on every message. `nil` means "read the persisted value".
    private static let gate = LogGate()

    static var isEnabled: Bool {
        get { gate.value ?? LoggingSettings.isEnabled }
        set { gate.value = newValue }
    }

    /// Re-reads the persisted setting, discarding any cached value.
    static func reloadPreference() {
        gate.value = nil
    }

    /// Persists the setting and applies it to every later log call.
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: LoggingSettings.enabledKey)
        isEnabled = enabled
    }

    static let scan = Category(name: "scan")
    static let worktree = Category(name: "worktree")
    static let layout = Category(name: "layout")
    static let ui = Category(name: "ui")
    static let state = Category(name: "state")

    static func bytes(_ value: Int64) -> String {
        "\(value) B (\(ByteFormatter.string(from: value)))"
    }

    static func duration(_ value: Duration) -> String {
        let components = value.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.3fs", seconds)
    }

    /// One Unified Logging category.
    ///
    /// Messages are autoclosures, so interpolation is skipped entirely while
    /// logging is off. Interpolated values are recorded as public: paths and
    /// sizes are exactly what these diagnostics exist to show.
    struct Category: Sendable {
        let name: String

        func notice(_ message: @autoclosure () -> String) { emit(level: .notice, message) }
        func info(_ message: @autoclosure () -> String) { emit(level: .info, message) }
        func debug(_ message: @autoclosure () -> String) { emit(level: .debug, message) }
        func error(_ message: @autoclosure () -> String) { emit(level: .error, message) }

        private enum Level { case notice, info, debug, error }

        private func emit(level: Level, _ message: () -> String) {
            guard AppLog.isEnabled else { return }
            let logger = Logger(subsystem: AppLog.resolvedSubsystem, category: name)
            let text = message()
            switch level {
            case .notice: logger.notice("\(text, privacy: .public)")
            case .info: logger.info("\(text, privacy: .public)")
            case .debug: logger.debug("\(text, privacy: .public)")
            case .error: logger.error("\(text, privacy: .public)")
            }
        }
    }
}

private final class LogGate: @unchecked Sendable {
    private let valueLock = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    var value: Bool? {
        get { valueLock.withLock { $0 } }
        set { valueLock.withLock { $0 = newValue } }
    }
}

/// The persisted logging preference, shared by the Settings dialog and `AppLog`.
enum LoggingSettings {
    static let enabledKey = AppLog.enabledDefaultsKey

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}
