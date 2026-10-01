import Foundation

@main struct DragCommitCoordinatorCheck {
    @MainActor static func main() {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        checkCompletionOrders(check)
        checkStaleCallbacks(check)
        print("DRAG COMMIT COORDINATOR: \(assertions) assertions passed")
    }

    @MainActor private static func checkCompletionOrders(_ check: (Bool, String) -> Void) {
        for visualsFirst in [false, true] {
            let coordinator = DragCommitCoordinator<NSObject>()
            let context = NSObject()
            coordinator.begin(context)
            check(!coordinator.consumeIfReady(context), "A new transaction remains locked")
            if visualsFirst { coordinator.markVisualsFinished(context) } else {
                coordinator.markPersistenceFinished(context)
            }
            check(!coordinator.consumeIfReady(context), "One completion cannot unlock the interaction")
            if visualsFirst { coordinator.markPersistenceFinished(context) } else {
                coordinator.markVisualsFinished(context)
            }
            check(coordinator.consumeIfReady(context), "Both completion orders finalize successfully")
            check(!coordinator.consumeIfReady(context), "Finalization is consumed exactly once")
            coordinator.markVisualsFinished(context)
            coordinator.markPersistenceFinished(context)
            check(!coordinator.consumeIfReady(context), "Repeated callbacks cannot finalize twice")
        }
    }

    @MainActor private static func checkStaleCallbacks(_ check: (Bool, String) -> Void) {
        let coordinator = DragCommitCoordinator<NSObject>()
        let old = NSObject()
        let current = NSObject()
        coordinator.begin(old)
        coordinator.begin(current)
        coordinator.markVisualsFinished(old)
        coordinator.markPersistenceFinished(old)
        coordinator.finishImmediately(old)
        check(!coordinator.consumeIfReady(old), "The old transaction cannot finalize")
        check(!coordinator.consumeIfReady(current), "Old callbacks cannot unlock the current transaction")
        coordinator.markPersistenceFinished(current)
        check(!coordinator.consumeIfReady(current), "Persistence still waits for the current visuals")
        coordinator.finishImmediately(current)
        check(coordinator.consumeIfReady(current), "Failure recovery can terminate a stale visual landing")
        coordinator.begin(current)
        coordinator.discard()
        coordinator.markVisualsFinished(current)
        coordinator.markPersistenceFinished(current)
        check(!coordinator.consumeIfReady(current), "Dismissed transactions ignore late completions")
        coordinator.discard()
        check(!coordinator.consumeIfReady(current), "Discard is repeatable")
        weak var retained: NSObject?
        do {
            let temporary = NSObject()
            retained = temporary
            coordinator.begin(temporary)
        }
        check(retained != nil, "The coordinator owns an active transaction")
        coordinator.discard()
        check(retained == nil, "Discard releases the transaction and its resources")
    }
}
