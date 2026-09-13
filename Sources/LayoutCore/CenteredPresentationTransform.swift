import CoreGraphics

/// Layer transforms operate relative to their anchor, which AppKit may place
/// at a corner. Compensate without changing AppKit-owned position/anchorPoint.
public enum CenteredPresentationTransform {
    public static func make(bounds: CGRect, anchorPoint: CGPoint, scale: CGFloat) -> CGAffineTransform {
        let centerFromAnchor = CGPoint(
            x: bounds.width * (0.5 - anchorPoint.x),
            y: bounds.height * (0.5 - anchorPoint.y)
        )
        return CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: centerFromAnchor.x * (1 - scale),
            ty: centerFromAnchor.y * (1 - scale)
        )
    }
}
