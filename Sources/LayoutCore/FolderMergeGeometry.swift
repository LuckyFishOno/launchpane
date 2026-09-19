import CoreGraphics

/// Resolves folder intent against the icon frames visible at the current drag event.
/// Callers exclude the dragged item and supply presentation frames during animation;
/// this helper deliberately retains no historical cell or icon geometry.
public enum FolderMergeGeometry {
    public struct Target<ID: Hashable> {
        public let id: ID
        public let iconFrame: CGRect

        public init(id: ID, iconFrame: CGRect) {
            self.id = id
            self.iconFrame = iconFrame
        }
    }

    public struct Tokens: Equatable, Sendable {
        /// Radii are fractions of the target icon's width and height, so a diagonal
        /// approach has the same central acquisition distance as a cardinal one.
        public let acquisitionRadius: CGFloat
        public let retentionRadius: CGFloat
        public let acquisitionOverlapFraction: CGFloat
        public let retentionOverlapFraction: CGFloat

        public init(
            acquisitionRadius: CGFloat = 0.44,
            retentionRadius: CGFloat = 0.54,
            acquisitionOverlapFraction: CGFloat = 0.34,
            retentionOverlapFraction: CGFloat = 0.22
        ) {
            self.acquisitionRadius = acquisitionRadius
            self.retentionRadius = retentionRadius
            self.acquisitionOverlapFraction = acquisitionOverlapFraction
            self.retentionOverlapFraction = retentionOverlapFraction
        }

        public static let standard = Tokens()

        fileprivate var isValid: Bool {
            acquisitionRadius.isFinite && acquisitionRadius > 0
                && retentionRadius.isFinite && retentionRadius >= acquisitionRadius
                && acquisitionOverlapFraction.isFinite
                && (0 ... 1).contains(acquisitionOverlapFraction)
                && retentionOverlapFraction.isFinite
                && (0 ... acquisitionOverlapFraction).contains(retentionOverlapFraction)
        }
    }

    /// The closest central acquisition wins. A previous target can survive small
    /// pointer movements in the wider retention radius only when there is no new
    /// central acquisition. Retaining an ID never resurrects an absent target.
    public static func target<ID: Hashable>(
        draggedIcon: CGRect,
        targets: [Target<ID>],
        retaining retainedID: ID?,
        tokens: Tokens = .standard
    ) -> ID? {
        guard tokens.isValid, validIcon(draggedIcon) else { return nil }

        var acquired: (id: ID, distance: CGFloat)?
        var retained: ID?
        for candidate in targets {
            guard let distance = normalizedDistance(draggedIcon: draggedIcon, targetIcon: candidate.iconFrame),
                  let overlap = overlapFraction(draggedIcon, candidate.iconFrame)
            else { continue }

            if distance <= tokens.acquisitionRadius,
               overlap >= tokens.acquisitionOverlapFraction,
               acquired == nil || distance < acquired!.distance {
                acquired = (candidate.id, distance)
            }
            if candidate.id == retainedID,
               distance <= tokens.retentionRadius,
               overlap >= tokens.retentionOverlapFraction {
                retained = candidate.id
            }
        }
        return acquired?.id ?? retained
    }

    public static func isApproachingTarget<ID: Hashable>(
        draggedIcon: CGRect,
        targets: [Target<ID>],
        tokens: Tokens = .standard
    ) -> Bool {
        guard tokens.isValid, validIcon(draggedIcon) else { return false }
        let approachRadius = max(tokens.retentionRadius, tokens.acquisitionRadius + 0.18)
        let approachOverlap = max(0.12, tokens.acquisitionOverlapFraction * 0.5)
        return targets.contains { candidate in
            guard let distance = normalizedDistance(draggedIcon: draggedIcon, targetIcon: candidate.iconFrame),
                  let overlap = overlapFraction(draggedIcon, candidate.iconFrame)
            else { return false }
            return distance <= approachRadius && overlap >= approachOverlap
        }
    }

    /// Center distance in target-icon units, independent of screen origin, scale,
    /// and cursor grab offset. Invalid or degenerate rectangles return nil.
    public static func normalizedDistance(draggedIcon: CGRect, targetIcon: CGRect) -> CGFloat? {
        guard validIcon(draggedIcon), validIcon(targetIcon) else { return nil }
        let dx = (draggedIcon.midX - targetIcon.midX) / targetIcon.width
        let dy = (draggedIcon.midY - targetIcon.midY) / targetIcon.height
        let squaredDistance = dx * dx + dy * dy
        guard squaredDistance.isFinite else { return nil }
        return squaredDistance.squareRoot()
    }

    private static func validIcon(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
            && (frame.size.width * frame.size.height).isFinite
            && frame.size.width * frame.size.height > 0
    }

    private static func overlapFraction(_ first: CGRect, _ second: CGRect) -> CGFloat? {
        let intersection = first.intersection(second)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
        let smallerArea = min(first.width * first.height, second.width * second.height)
        return intersection.width * intersection.height / smallerArea
    }
}
