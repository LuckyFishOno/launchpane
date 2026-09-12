import Foundation

public enum LauncherLayoutItemIdentifier: Equatable, Hashable, Sendable {
    case application(ApplicationIdentity)
    case folder(UUID)
}

public enum LauncherDropTarget: Equatable, Sendable {
    case insertion(destination: LauncherLayoutItemIdentifier)
    case pageInsertion(page: Int, index: Int)
    case application(ApplicationIdentity)
    case folder(UUID)
    case outside

    public var isInsertion: Bool {
        switch self {
        case .insertion, .pageInsertion: true
        default: false
        }
    }
}

public enum LauncherDragState: Equatable, Sendable {
    case idle
    case pressed(LauncherLayoutItemIdentifier)
    case dragging(LauncherLayoutItemIdentifier, target: LauncherDropTarget)
    case committing(LauncherLayoutItemIdentifier)
    case rollingBack(LauncherLayoutItemIdentifier)
}

public struct LauncherDragStateMachine: Equatable, Sendable {
    public private(set) var state: LauncherDragState = .idle

    public init() {}

    @discardableResult
    public mutating func pointerDown(on item: LauncherLayoutItemIdentifier) -> Bool {
        guard state == .idle else { return false }
        state = .pressed(item)
        return true
    }

    @discardableResult
    public mutating func beginDragging() -> Bool {
        guard case let .pressed(item) = state else { return false }
        state = .dragging(item, target: .outside)
        return true
    }

    @discardableResult
    public mutating func update(target: LauncherDropTarget) -> Bool {
        guard case let .dragging(item, _) = state else { return false }
        state = .dragging(item, target: target)
        return true
    }

    @discardableResult
    public mutating func beginCommit() -> Bool {
        guard case let .dragging(item, target) = state, target != .outside else { return false }
        state = .committing(item)
        return true
    }

    @discardableResult
    public mutating func beginRollback() -> Bool {
        switch state {
        case let .pressed(item), let .dragging(item, _), let .committing(item):
            state = .rollingBack(item)
            return true
        case .idle, .rollingBack:
            return false
        }
    }

    public mutating func finish() {
        state = .idle
    }
}
