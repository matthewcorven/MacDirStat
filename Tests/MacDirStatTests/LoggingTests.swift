import Foundation
import Testing
@testable import MacDirStat

/// Restores the persisted logging switch after a test mutates it.
private struct LoggingPreferenceScope {
    private let original: Bool

    init() {
        original = UserDefaults.standard.bool(forKey: LoggingSettings.enabledKey)
    }

    func restore() {
        UserDefaults.standard.set(original, forKey: LoggingSettings.enabledKey)
        AppLog.isEnabled = original
    }
}

@Test func loggingIsOffByDefault() {
    let scope = LoggingPreferenceScope()
    defer { scope.restore() }
    UserDefaults.standard.removeObject(forKey: LoggingSettings.enabledKey)

    #expect(!LoggingSettings.isEnabled)
    AppLog.isEnabled = AppLog.isEnabled // re-apply the persisted value
    #expect(!AppLog.isEnabled)
}

@Test func enablingLoggingPersistsAndTakesEffectImmediately() {
    let scope = LoggingPreferenceScope()
    defer { scope.restore() }

    AppLog.setEnabled(true)
    #expect(LoggingSettings.isEnabled)
    #expect(AppLog.isEnabled)
    #expect(UserDefaults.standard.bool(forKey: AppLog.enabledDefaultsKey))

    AppLog.setEnabled(false)
    #expect(!LoggingSettings.isEnabled)
    #expect(!AppLog.isEnabled)
}

/// Test traffic must not land in the app's subsystem, or `log show` for the app
/// fills with fixture paths.
@Test func testsLogToTheirOwnSubsystem() {
    #expect(AppLog.isTestProcess)
    #expect(AppLog.resolvedSubsystem == AppLog.subsystem + AppLog.testSubsystemSuffix)
    #expect(AppLog.resolvedSubsystem != AppLog.subsystem)
}

@Test func worktreeStaleThresholdDefaultsToFourteenDays() {
    let key = WorktreeSettings.staleThresholdDaysKey
    let original = UserDefaults.standard.object(forKey: key)
    defer {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    UserDefaults.standard.removeObject(forKey: key)
    #expect(WorktreeSettings.staleThresholdDays == 14)
    #expect(WorktreeSettings.staleThreshold == 14 * 24 * 60 * 60)

    WorktreeSettings.staleThresholdDays = 3
    #expect(WorktreeSettings.staleThresholdDays == 3)
}
