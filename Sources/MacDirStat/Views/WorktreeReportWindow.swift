import SwiftUI

/// Hosts the worktree list in its own window so the list can scroll and be
/// resized. A sheet is fixed-size at presentation, which made a long list
/// clipped and unreadable.
struct WorktreeInspectorWindowContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        WorktreeInspectorView(state: appState)
            .environment(appState)
    }
}

enum WorktreeReportWindow {
    static let id = "worktree-report"
}
