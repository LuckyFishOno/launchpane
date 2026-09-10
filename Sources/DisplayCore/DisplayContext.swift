import CoreGraphics

public struct DisplayContext: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScaleFactor: CGFloat
    public let safeInsets: DisplayInsets
    public let hasNotch: Bool

    public init(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: CGFloat,
        safeInsets: DisplayInsets = .zero,
        hasNotch: Bool = false
    ) {
        self.displayID = displayID
        self.frame = frame.standardized
        self.visibleFrame = visibleFrame.standardized
        self.backingScaleFactor = max(1, backingScaleFactor)
        self.safeInsets = safeInsets
        self.hasNotch = hasNotch
    }

    public var logicalWidth: CGFloat {
        visibleFrame.width
    }

    public var logicalHeight: CGFloat {
        visibleFrame.height
    }

    public var aspectRatio: CGFloat {
        guard logicalHeight > 0 else { return 1 }
        return logicalWidth / logicalHeight
    }

    public var isRetina: Bool {
        backingScaleFactor > 1
    }

    public var isUltrawide: Bool {
        aspectRatio >= 2.2
    }

    /// The complete display frame expressed in window-local coordinates.
    public var localFrameBounds: CGRect {
        CGRect(origin: .zero, size: frame.size)
    }

    /// The visible frame expressed in window-local coordinates.
    public var localVisibleBounds: CGRect {
        CGRect(
            x: visibleFrame.minX - frame.minX,
            y: visibleFrame.minY - frame.minY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    public var safeBounds: CGRect {
        let safeFrameBounds = CGRect(
            x: localFrameBounds.minX + safeInsets.leading,
            y: localFrameBounds.minY + safeInsets.bottom,
            width: max(0, localFrameBounds.width - safeInsets.leading - safeInsets.trailing),
            height: max(0, localFrameBounds.height - safeInsets.top - safeInsets.bottom)
        )
        let intersection = localVisibleBounds.intersection(safeFrameBounds)
        return intersection.isNull ? .zero : intersection
    }
}
