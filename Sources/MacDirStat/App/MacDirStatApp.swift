import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // `MacDirStat --scan <folder>` mirrors dropping a folder on the Dock
        // icon. Record it before the window is built so the first scan starts
        // as soon as the window can host it.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--scan"), arguments.indices.contains(flag + 1) {
            AppStateHolder.shared.pendingScanPath = arguments[flag + 1]
        }
        // Set before the Dock tile appears so it never flashes the generic executable icon.
        if let icon = Self.appIcon() {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        // Logging is off by default. Read the persisted choice once so every
        // later message can check a cached value; this launch itself is only
        // recorded when the switch was already on.
        AppLog.isEnabled = LoggingSettings.isEnabled
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let identifier = bundle.bundleIdentifier ?? "no bundle id"
        AppLog.state.notice("Launched MacDirStat \(version) (\(identifier)) pid=\(ProcessInfo.processInfo.processIdentifier) fullDiskAccess=\(FullDiskAccess.isGranted) bundle=\(bundle.bundlePath)")

    }

    // Same lookup as SPM's Bundle.module, which calls fatalError when the resource bundle
    // isn't beside the binary (e.g. the binary was copied elsewhere). A missing icon shouldn't crash.
    private static func appIcon() -> NSImage? {
        [Bundle.main.resourceURL, Bundle.main.bundleURL]
            .lazy
            .compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent("MacDirStat_MacDirStat.bundle")) } }
            .first?
            .image(forResource: "AppIcon")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Lets Finder's Open With and a folder dropped on the Dock icon scan it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let folder = urls.first(where: { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }) else { return }
        Task { @MainActor in
            AppStateHolder.shared.pendingScanPath = folder.path(percentEncoded: false)
            AppStateHolder.shared.startPendingScan()
        }
    }
}

/// A single `AppState` per process, so the app delegate and the SwiftUI scene
/// agree on where an opened folder should be scanned.
@MainActor
enum AppStateHolder {
    static let shared = AppState()

    static func startPendingScanIfNeeded(with requester: @escaping (String) -> Void) {
        shared.scanRequester = requester
        shared.startPendingScan()
    }
}

@main
struct MacDirStatApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var appState = AppStateHolder.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            OpenFolderCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Menu commands read focused values from the key window, so ⌘O acts on the window in front.
struct OpenFolderCommands: Commands {
    @FocusedValue(\.openFolderAction) private var openFolder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder...") {
                openFolder?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openFolder == nil)
        }
    }
}
