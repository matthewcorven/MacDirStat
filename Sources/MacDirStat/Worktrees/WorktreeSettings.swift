import Foundation

/// Persisted preferences for worktree analysis, shared by the Settings dialog
/// and the detector.
enum WorktreeSettings {
    static let staleThresholdDaysKey = "worktreeStaleThresholdDays"
    static let defaultStaleThresholdDays = 14

    static var staleThresholdDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: staleThresholdDaysKey)
            return stored > 0 ? stored : defaultStaleThresholdDays
        }
        set { UserDefaults.standard.set(newValue, forKey: staleThresholdDaysKey) }
    }

    static var staleThreshold: TimeInterval {
        TimeInterval(staleThresholdDays) * 24 * 60 * 60
    }
}
