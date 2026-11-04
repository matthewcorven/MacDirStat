import SwiftUI

/// Explains a refused worktree delete. Without this the guard is silent: the
/// user clicks Move to Trash, nothing happens, and no reason is shown.
private struct WorktreeDeletionAlert: ViewModifier {
    @Bindable var state: AppState

    func body(content: Content) -> some View {
        content.alert(
            "Worktree not deleted",
            isPresented: Binding(
                get: { state.worktreeAlert != nil },
                set: { if !$0 { state.worktreeAlert = nil } }
            ),
            presenting: state.worktreeAlert
        ) { _ in
            Button("OK", role: .cancel) { state.worktreeAlert = nil }
        } message: { reason in
            Text(reason)
        }
    }
}

extension View {
    func worktreeDeletionAlert(state: AppState) -> some View {
        modifier(WorktreeDeletionAlert(state: state))
    }
}
