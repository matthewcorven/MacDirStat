import SwiftUI

/// Settings window (⌘,) with the opt-in diagnostics switch and the Full Disk
/// Access state, which previously only appeared on the welcome screen.
struct SettingsView: View {
    @State private var loggingEnabled = LoggingSettings.isEnabled
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    @State private var staleThresholdDays = WorktreeSettings.staleThresholdDays

    var body: some View {
        TabView {
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            scanningTab
                .tabItem { Label("Scanning", systemImage: "internaldrive") }
            worktreesTab
                .tabItem { Label(GitWorktreeStyle.legendTitle, systemImage: GitWorktreeStyle.sfSymbol) }
        }
        .frame(width: 520, height: 320)
        .onAppear {
            loggingEnabled = LoggingSettings.isEnabled
            hasFullDiskAccess = FullDiskAccess.isGranted
            staleThresholdDays = WorktreeSettings.staleThresholdDays
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }

    private var diagnosticsTab: some View {
        Form {
            Section {
                Toggle("Write diagnostics to the system log", isOn: $loggingEnabled)
                    .onChange(of: loggingEnabled) { _, enabled in
                        AppLog.setEnabled(enabled)
                    }
                Text("Applies immediately. Turning this on does not add anything from the current session's earlier startup or scans; only events after you change the switch are recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Logging")
            }

            Section {
                Text("View live logs in Terminal:")
                    .font(.caption)
                Text("log stream --level debug --predicate 'subsystem == \"\(AppLog.resolvedSubsystem)\"'")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("App and UI details are in the scan, worktree, layout, ui and state categories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Where to look")
            }
        }
        .formStyle(.grouped)
    }

    private var scanningTab: some View {
        Form {
            Section {
                LabeledContent("Full Disk Access") {
                    HStack(spacing: 6) {
                        Image(systemName: hasFullDiskAccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(hasFullDiskAccess ? .green : .orange)
                        Text(hasFullDiskAccess ? "Granted" : "Not granted")
                    }
                }
                Text("Without Full Disk Access, protected folders such as Mail and other apps' data are skipped, sizes are under-reported, and worktrees inside those folders are invisible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { FullDiskAccess.openSystemSettings() }
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
    }

    private var worktreesTab: some View {
        Form {
            Section {
                Stepper(value: $staleThresholdDays, in: 1...365) {
                    LabeledContent("Flag as stale after") {
                        Text("\(staleThresholdDays) day\(staleThresholdDays == 1 ? "" : "s")")
                            .monospacedDigit()
                    }
                }
                .onChange(of: staleThresholdDays) { _, days in
                    WorktreeSettings.staleThresholdDays = days
                }
                Text("A worktree is \"stale and clean\" when it has no uncommitted changes and no file has changed within this window. Detached worktrees are always listed as unused candidates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Unused worktrees")
            }
        }
        .formStyle(.grouped)
    }
}
