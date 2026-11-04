import SwiftUI

/// Explains what a scan left out, keeping two situations apart because only one
/// of them is actionable:
///
/// - Access blocked by macOS protection (or a missing Full Disk Access grant):
///   real data is missing and the user can often fix it.
/// - Folders whose own permissions exclude this account: never readable, so the
///   scan is not incomplete in a way anyone can resolve. Shown quietly.
struct ScanDiagnosticsBanner: View {
    /// Folders that were skipped for an actionable reason.
    let incompleteFolders: Int
    let unavailableEntries: Int
    /// Folders only their owner (or root) can open.
    let ownerOnlyFolders: Int
    let hasFullDiskAccess: Bool
    let detectsWorktrees: Bool

    @State private var isDismissed = false

    private var hasIssue: Bool { incompleteFolders > 0 || unavailableEntries > 0 }

    var body: some View {
        if (hasIssue || ownerOnlyFolders > 0) && !isDismissed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hasIssue ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(hasIssue ? .orange : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(hasIssue ? issueTitle : informationalTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .help(detail ?? "")

                Spacer(minLength: 8)

                if hasIssue, !hasFullDiskAccess {
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
                .accessibilityLabel("Dismiss scan notice")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // The banner must not influence the window's size limits. Intrinsic,
            // wrapping text here feeds back into AppKit's constraints on the
            // macOS 26+ SDK and the entire split view grows past the window (the
            // same trap documented in WelcomeView). Fixed line limits plus a
            // height bound keep it from proposing a larger ideal size; the full
            // text stays available as a tooltip and in the inspector.
            .frame(height: 44, alignment: .leading)
            .background(hasIssue ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08))
        }
    }

    private var issueTitle: String {
        var parts: [String] = []
        if incompleteFolders > 0 {
            let noun = incompleteFolders == 1 ? "folder" : "folders"
            parts.append("\(incompleteFolders.formatted()) \(noun) blocked by macOS")
        }
        if unavailableEntries > 0 {
            let noun = unavailableEntries == 1 ? "entry" : "entries"
            parts.append("\(unavailableEntries.formatted()) \(noun) skipped")
        }
        return "Contents not included: " + parts.joined(separator: ", ")
    }

    private var informationalTitle: String {
        let noun = ownerOnlyFolders == 1 ? "folder is" : "folders are"
        return "\(ownerOnlyFolders.formatted()) \(noun) readable only by their owner"
    }

    private var detail: String? {
        var text: [String] = []
        if hasIssue {
            var issue = "Sizes under-report these folders"
            if detectsWorktrees {
                issue += ", and worktrees inside them may be missed"
            }
            issue += "."
            if !hasFullDiskAccess {
                issue += " Full Disk Access is off."
            }
            text.append(issue)
        }
        if ownerOnlyFolders > 0 {
            // Only worth a mention when there is also a real gap to explain.
            if hasIssue {
                text.append("A further \(ownerOnlyFolders.formatted()) folder\(ownerOnlyFolders == 1 ? " is" : "s are") readable only by their owner, which is normal for daemon-private system folders.")
            } else {
                text.append("Only their owner or root can open them, which is normal for daemon-private system folders and is not a Full Disk Access problem.")
            }
        }
        return text.isEmpty ? nil : text.joined(separator: " ")
    }
}
