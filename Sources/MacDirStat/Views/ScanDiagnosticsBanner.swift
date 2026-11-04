import SwiftUI

/// Explains what a partial scan means: unreadable folders hide files, sizes and
/// any worktrees inside them. Shown in the main window so this isn't only a log
/// message, with a shortcut to grant Full Disk Access when that's the cause.
struct ScanDiagnosticsBanner: View {
    let unreadableFolders: Int
    let unreadableEntries: Int
    let hasFullDiskAccess: Bool
    let detectsWorktrees: Bool

    @State private var isDismissed = false

    var body: some View {
        if !isDismissed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hasFullDiskAccess ? "exclamationmark.triangle" : "lock.shield")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if !hasFullDiskAccess {
                    Button("Open Settings") { FullDiskAccess.openSystemSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button {
                    isDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Dismiss scan warning")
            }
            .padding(8)
            .background(Color.orange.opacity(0.10))
        }
    }

    private var title: String {
        var parts: [String] = []
        if unreadableFolders > 0 {
            let count = unreadableFolders.formatted()
            let noun = unreadableFolders == 1 ? "folder" : "folders"
            parts.append("\(count) \(noun) unreadable")
        }
        if unreadableEntries > 0 {
            let count = unreadableEntries.formatted()
            let noun = unreadableEntries == 1 ? "entry" : "entries"
            parts.append("\(count) \(noun) skipped")
        }
        return "Incomplete scan: " + parts.joined(separator: ", ")
    }

    private var detail: String {
        var text = "Sizes are under-reported"
        if detectsWorktrees {
            text += ", and worktrees inside those folders may be missed"
        }
        text += "."
        if !hasFullDiskAccess {
            text += " Full Disk Access is off; grant it in System Settings to include protected folders."
        }
        return text
    }
}
