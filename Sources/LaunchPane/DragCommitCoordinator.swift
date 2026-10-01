import AppCore

/// Finalizes the active transaction once both persistence and visual ownership
/// are ready. A completion from an older interaction cannot unlock a newer one.
@MainActor final class DragCommitCoordinator<Context: AnyObject> {
    private var active: Context?
    private var completion = LauncherDragCommitState()

    func begin(_ context: Context) {
        active = context
        completion = LauncherDragCommitState()
    }

    func markVisualsFinished(_ context: Context) {
        guard active === context else { return }
        completion.markVisualsFinished()
    }

    func markPersistenceFinished(_ context: Context) {
        guard active === context else { return }
        completion.markPersistenceFinished()
    }

    func finishImmediately(_ context: Context) {
        guard active === context else { return }
        completion.finishImmediately()
    }

    func consumeIfReady(_ context: Context) -> Bool {
        guard active === context, completion.isReadyToFinalize else { return false }
        active = nil
        return true
    }

    func discard() {
        active = nil
        completion = LauncherDragCommitState()
    }
}
