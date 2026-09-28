import Foundation

/// The three warm-up lifetimes are independent: paging must not cancel the
/// presentation-wide warm, and dismissal must not cancel pinned idle work.
@MainActor final class IconPrewarmTasks {
    var visiblePage: Task<Void, Never>?
    var idleFirstPage: Task<Void, Never>?
    var presentation: Task<Void, Never>?

    func cancelVisiblePage() {
        visiblePage?.cancel()
        visiblePage = nil
    }

    func cancelIdleFirstPage() {
        idleFirstPage?.cancel()
        idleFirstPage = nil
    }

    func cancelPresentation() {
        presentation?.cancel()
        presentation = nil
    }
}
