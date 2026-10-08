import AppKit
import QuartzCore

/// Owns delayed proxy handoffs. Replaced, rolled-back, or dismissed animations
/// cannot later mutate the current page's visual ownership.
@MainActor final class DragVisualCoordinator {
    private struct Pending {
        let proxy: CALayer
        let token: UUID
        let task: Task<Void, Never>
        let completion: @MainActor () -> Void
    }
    private var pending: [ObjectIdentifier: Pending] = [:]

    @discardableResult func schedule(
        for proxy: CALayer, after duration: CFTimeInterval, completion: @escaping @MainActor () -> Void
    ) -> UUID {
        cancel(for: proxy)
        let token = UUID()
        let task = Task { @MainActor [weak self, weak proxy] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, let proxy else { return }
            _ = complete(proxy, token: token)
        }
        pending[ObjectIdentifier(proxy)] = Pending(proxy: proxy, token: token, task: task, completion: completion)
        return token
    }

    @discardableResult func complete(_ proxy: CALayer, token: UUID) -> Bool {
        let key = ObjectIdentifier(proxy)
        guard let current = pending[key], current.token == token else { return false }
        pending.removeValue(forKey: key)
        current.task.cancel()
        current.completion()
        return true
    }

    func cancel(for proxy: CALayer) {
        pending.removeValue(forKey: ObjectIdentifier(proxy))?.task.cancel()
    }

    func discard() {
        let retired = pending.values
        pending.removeAll()
        for item in retired {
            item.task.cancel()
            Self.retire(item.proxy)
        }
    }

    static func retire(_ proxy: CALayer?, revealing source: CALayer? = nil, in parent: CALayer? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        proxy?.removeAllAnimations()
        proxy?.removeFromSuperlayer()
        if let source, source.superlayer == nil, let parent { parent.addSublayer(source) }
        source?.opacity = 1
        CATransaction.commit()
    }
}
