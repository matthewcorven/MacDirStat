import Foundation

@MainActor
final class ScanCoordinator {
    private let appState: AppState
    private var scanTask: Task<Void, Never>?
    private var worktreeWatchTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
    }

    func startScan(path: String, detectGitWorktrees: Bool) {
        cancel()
        appState.reset()
        appState.detectGitWorktrees = detectGitWorktrees
        appState.scanStatus = .scanning(fileCount: 0, byteCount: 0, currentPath: path)
        AppLog.state.notice("Scan requested: path=\(path, privacy: .public) detectWorktrees=\(detectGitWorktrees)")

        let scanner = FileScanner(rootPath: path, detectGitWorktrees: detectGitWorktrees)
        scanTask = Task {
            var lastUpdate = ContinuousClock.now
            let throttleInterval = Duration.milliseconds(50) // 20 updates/sec

            for await event in scanner.scan() {
                if Task.isCancelled { break }

                switch event {
                case let .progress(fileCount, byteCount, currentPath):
                    let now = ContinuousClock.now
                    if now - lastUpdate >= throttleInterval {
                        AppLog.scan.debug("Progress: files=\(fileCount) allocated=\(AppLog.bytes(byteCount), privacy: .public) current=\(currentPath, privacy: .public)")
                        appState.scanStatus = .scanning(
                            fileCount: fileCount,
                            byteCount: byteCount,
                            currentPath: currentPath
                        )
                        lastUpdate = now
                    }

                case let .completed(root):
                    AppLog.state.notice("Scan completed; publishing tree")
                    appState.setScanCompleted(root: root)
                    let worktreeCount = appState.worktreeCount
                    let worktreeTotal = appState.worktreeTotalSize
                    AppLog.state.notice("Published tree: worktrees=\(worktreeCount) worktreeTotal=\(AppLog.bytes(worktreeTotal), privacy: .public)")
                    updateWorktreeWatch()

                case let .error(message):
                    AppLog.state.error("Scan error surfaced to UI: \(message, privacy: .public)")
                    appState.scanStatus = .error(message)
                }
            }
        }
    }

    /// Watches the scanned tree for worktrees deleted outside MacDirStat. The
    /// check only stats already-detected roots, so it can run without rescanning.
    func updateWorktreeWatch() {
        worktreeWatchTask?.cancel()
        worktreeWatchTask = nil
        guard appState.detectGitWorktrees, appState.rootNode != nil else { return }
        worktreeWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard self.appState.detectGitWorktrees,
                      self.appState.rootNode != nil else { return }
                self.appState.reconcileWorktrees()
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        worktreeWatchTask?.cancel()
        worktreeWatchTask = nil
    }
}
