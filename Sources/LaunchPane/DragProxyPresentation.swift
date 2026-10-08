import AppKit
import QuartzCore

@MainActor enum DragProxyPresentation {
    static func makeDragProxy(for entry: LaunchpadPageEntry, scale: CGFloat) -> CALayer {
        // Split the moving proxy into an icon-only backing store plus a live
        // label child. The label can then fade without ever replacing the moving
        // layer's contents, so there is no transition snapshot left behind at
        // the old pointer position.
        let previousSelectionOpacity = entry.selectionLayer.opacity
        let previousLabelOpacity = entry.labelLayer.opacity
        let modelIconOpacity = entry.iconLayer.opacity
        let modelIconTransform = entry.iconLayer.affineTransform()

        let visibleIconOpacity = entry.iconLayer.presentation()?.opacity ?? modelIconOpacity
        let visibleIconTransform = entry.iconLayer.presentation()?.affineTransform() ?? modelIconTransform
        let visibleLabelOpacity = entry.labelLayer.presentation()?.opacity ?? previousLabelOpacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.selectionLayer.opacity = 0
        entry.labelLayer.opacity = 0
        entry.iconLayer.opacity = visibleIconOpacity
        entry.iconLayer.setAffineTransform(visibleIconTransform)
        entry.tileLayer.layoutIfNeeded()
        let iconSnapshot = snapshotImage(of: entry.tileLayer, scale: scale)
        entry.selectionLayer.opacity = previousSelectionOpacity
        entry.labelLayer.opacity = previousLabelOpacity
        entry.iconLayer.opacity = modelIconOpacity
        entry.iconLayer.setAffineTransform(modelIconTransform)
        CATransaction.commit()

        let proxy = CALayer()
        proxy.bounds = CGRect(origin: .zero, size: entry.frames.cell.size)
        proxy.position = entry.frames.cell.center
        proxy.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        proxy.contents = iconSnapshot
        proxy.contentsGravity = .resize
        proxy.contentsScale = scale
        proxy.minificationFilter = .linear
        proxy.magnificationFilter = .linear
        proxy.opacity = 1
        proxy.zPosition = 10_000
        proxy.shadowOpacity = 0
        proxy.shadowRadius = 0
        proxy.shadowOffset = .zero

        let proxyLabelLayer = makeDragProxyLabel(for: entry, scale: scale, opacity: visibleLabelOpacity)
        proxy.addSublayer(proxyLabelLayer)

        return proxy
    }

    static func makeDragProxyLabel(for entry: LaunchpadPageEntry, scale: CGFloat, opacity: Float) -> CATextLayer {
        let proxyLabelLayer = CATextLayer()
        proxyLabelLayer.name = DragProxyMetrics.labelLayerName
        proxyLabelLayer.frame = entry.labelLayer.frame
        proxyLabelLayer.string = entry.labelLayer.string
        proxyLabelLayer.alignmentMode = entry.labelLayer.alignmentMode
        proxyLabelLayer.truncationMode = entry.labelLayer.truncationMode
        proxyLabelLayer.fontSize = entry.labelLayer.fontSize
        proxyLabelLayer.foregroundColor = entry.labelLayer.foregroundColor
        proxyLabelLayer.shadowColor = entry.labelLayer.shadowColor
        proxyLabelLayer.shadowOpacity = entry.labelLayer.shadowOpacity
        proxyLabelLayer.shadowOffset = entry.labelLayer.shadowOffset
        proxyLabelLayer.shadowRadius = entry.labelLayer.shadowRadius
        proxyLabelLayer.contentsScale = scale
        proxyLabelLayer.opacity = opacity
        return proxyLabelLayer
    }

    static func dragProxyLabelLayer(_ proxy: CALayer) -> CATextLayer? {
        proxy.sublayers?.first { $0.name == DragProxyMetrics.labelLayerName } as? CATextLayer
    }

    static func refreshDragProxyForRelease(
        _ proxy: CALayer, sourceEntry entry: LaunchpadPageEntry, scale: CGFloat, hidesLabel: Bool = false
    ) {
        let previousSelectionOpacity = entry.selectionLayer.opacity
        let previousLabelOpacity = entry.labelLayer.opacity
        let previousTileOpacity = entry.tileLayer.opacity
        let previousTileHidden = entry.tileLayer.isHidden

        entry.iconLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Snapshot generation must be independent of render ownership. A source
        // tile may be detached/hidden by its owning drag state, but the backing
        // image used by the moving proxy must always be rendered fully visible.
        entry.tileLayer.opacity = 1
        entry.tileLayer.isHidden = false
        entry.selectionLayer.opacity = 0
        entry.labelLayer.opacity = 0
        entry.iconLayer.opacity = 1
        entry.iconLayer.setAffineTransform(.identity)
        entry.tileLayer.layoutIfNeeded()
        let releaseSnapshot = snapshotImage(of: entry.tileLayer, scale: scale)
        entry.selectionLayer.opacity = previousSelectionOpacity
        entry.labelLayer.opacity = previousLabelOpacity
        entry.tileLayer.opacity = previousTileOpacity
        entry.tileLayer.isHidden = previousTileHidden

        if let releaseSnapshot {
            proxy.contents = releaseSnapshot
            proxy.contentsScale = scale
        }
        if let proxyLabelLayer = dragProxyLabelLayer(proxy) {
            proxyLabelLayer.removeAnimation(forKey: DragProxyMetrics.labelAnimationKey)
            proxyLabelLayer.opacity = hidesLabel ? 0 : 1
        }
        CATransaction.commit()
    }

    static func snapshotImage(of layer: CALayer, scale: CGFloat) -> CGImage? {
        let size = layer.bounds.size

        guard size.width > 0, size.height > 0 else { return nil }

        let pixelWidth = max(1, Int(ceil(size.width * scale)))

        let pixelHeight = max(1, Int(ceil(size.height * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard
            let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                space: colorSpace, bitmapInfo: bitmapInfo)
        else { return nil }

        // CALayer 使用 point，
        // bitmap 使用 Retina pixel。
        context.scaleBy(x: scale, y: scale)

        layer.render(in: context)

        return context.makeImage()
    }

    static func animateDragLift(_ layer: CALayer, from _: CGPoint, to point: CGPoint, offset: CGVector) {
        let destination = CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)

        // Do not create a separate "lifted" drag appearance.
        //
        // The App should look exactly the same from:
        //
        // mouseDown -> dragging
        //
        // Only its position changes.
        layer.removeAnimation(forKey: "dragLiftPosition")

        layer.removeAnimation(forKey: "dragLiftScale")

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.position = destination

        // Outer proxy must not introduce another scale.
        // The snapshot already contains the exact pressed/hover state.
        layer.setAffineTransform(.identity)

        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero

        CATransaction.commit()
    }

    static func animateMergeProxyIntoFolder(
        _ proxy: CALayer, destination: CGPoint, destinationScale: CGFloat, duration: CFTimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        let startPosition = proxy.presentation()?.position ?? proxy.position
        let startOpacity = proxy.presentation()?.opacity ?? proxy.opacity

        // Commit the final model state without implicit animations. Explicit
        // animations below keep the icon visible during most of the trip; only
        // the last fraction fades, after the shrink is already obvious.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        proxy.position = destination
        proxy.setAffineTransform(.init(scaleX: destinationScale, y: destinationScale))
        proxy.opacity = 0
        CATransaction.commit()

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: startPosition)
        move.toValue = NSValue(point: destination)
        move.duration = duration
        move.timingFunction = timingFunction
        proxy.add(move, forKey: "folderMergeLandingPosition")

        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0
        shrink.toValue = destinationScale
        shrink.duration = duration
        shrink.timingFunction = timingFunction
        proxy.add(shrink, forKey: "folderMergeLandingScale")

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [NSNumber(value: startOpacity), NSNumber(value: startOpacity), NSNumber(value: 0)]
        let fadeStartProgress =
            destinationScale <= FolderMergeVisualMetrics.fullFolderAbsorbScale
            ? FolderMergeVisualMetrics.fullFolderFadeStartProgress : FolderMergeVisualMetrics.mergeFadeStartProgress

        opacity.keyTimes = [NSNumber(value: 0), NSNumber(value: fadeStartProgress), NSNumber(value: 1)]
        opacity.duration = duration
        opacity.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
        proxy.add(opacity, forKey: "folderMergeLandingOpacity")
    }
}
