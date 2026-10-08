import AppKit

@main struct DragVisualCoordinatorCheck {
    @MainActor static func main() {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            assertions += 1
        }
        let owner = DragVisualCoordinator()
        let proxy = CALayer()
        let host = CALayer()
        host.addSublayer(proxy)
        var calls = 0
        let old = owner.schedule(for: proxy, after: 60) { calls += 1 }
        let current = owner.schedule(for: proxy, after: 60) { calls += 10 }
        check(!owner.complete(proxy, token: old), "Replaced animation cannot finish the current handoff")
        check(calls == 0, "Stale completion cannot touch live layers")
        check(owner.complete(proxy, token: current), "Current animation completes")
        check(calls == 10, "Only current handoff runs")
        check(!owner.complete(proxy, token: current), "Handoff completes exactly once")
        let cancelled = owner.schedule(for: proxy, after: 60) { calls += 100 }
        owner.cancel(for: proxy)
        check(!owner.complete(proxy, token: cancelled) && calls == 10, "Rollback rejects late landing completion")
        let discarded = owner.schedule(for: proxy, after: 60) { calls += 100 }
        owner.discard()
        check(proxy.superlayer == nil, "Idle cleanup removes pending proxy")
        check(!owner.complete(proxy, token: discarded), "Dismissal invalidates delayed callbacks")
        owner.discard()
        check(calls == 10, "Repeated discard is safe")
        let source = CALayer()
        DragVisualCoordinator.retire(proxy, revealing: source, in: host)
        check(source.superlayer === host && source.opacity == 1, "Live source owns the scene after proxy retirement")
        check(proxy.superlayer == nil && proxy.animationKeys()?.isEmpty != false, "Proxy releases its visual ownership")
        print("DRAG VISUAL COORDINATOR: \(assertions) assertions passed")
    }
}
