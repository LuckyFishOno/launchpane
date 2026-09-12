import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

// This controller owns the AppKit event surface and its tightly coupled Core Animation presentation state.
// swiftlint:disable file_length type_body_length
@MainActor
private final class LaunchpadCanvasView: NSView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class LaunchpadRootView: NSView {
    private let solver = LayoutConstraintSolver()
    private let catalog = AppCatalogActor()
    private let layoutStore = LauncherLayoutStore(fileURL: LaunchpadRuntimePaths.layoutFileURL)
    private let iconCache = AppIconCache()
    private let wallpaperView = NSImageView()
    private let canvasView = LaunchpadCanvasView()
    private let rootLayer = CALayer()
    private let fixedBackgroundLayer = CALayer()
    private let fixedOverlayLayer = CALayer()
    private let pageIndicatorLayer = CATextLayer()
    private let folderOverlayLayer = CALayer()
    private let dragOverlayLayer = CALayer()
    private var pageContentLayer = CALayer()
    private let pageTransitionAnimator = PageTransitionAnimator()
    private let searchField = LaunchpadSearchField(frame: .zero)
    private var displayContext: DisplayContext

    private var applications: [ApplicationRecord] = []
    private var layoutDocument = LauncherLayoutDocument()
    private var pageSurfaces: [Int: LaunchpadPageSurface] = [:]
    private var activeSurface: LaunchpadPageSurface?
    private var renderedConfiguration: PageSurfaceConfiguration?
    private var contentRevision = 0
    private var currentPage = 0
    private var selectedIndex = -1
    private var currentMetrics: GridMetrics?
    private var pendingPageDirection = 0
    private var pageScrollGesture = PageScrollGesture()
    private var pageSwipeInputGate = PageSwipeInputGate()
    private var interactivePageSwipe: InteractivePageSwipe?
    private var interactivePageGeneration = 0
    private var iconPrewarmTask: Task<Void, Never>?
    private var pagingDisplayLink: CADisplayLink?

    private var isPageTransitionActive: Bool {
        pageTransitionAnimator.isAnimating || interactivePageSwipe != nil
    }

    private var dragStateMachine = LauncherDragStateMachine()
    private var pendingPress: PendingTilePress?
    private var dragSession: LaunchpadDragSession?
    private var dragCommitContext: LaunchpadDragCommitContext?
    private var isCommittingLayout = false
    private var isFinishingDragVisuals = false
    private var isResettingLayout = false

    private var openFolderID: UUID?
    private var folderPage = 0
    private var folderSelectedIndex = -1
    private var folderPageScrollGesture = PageScrollGesture()
    private var folderPanelFrame = CGRect.zero
    private var folderPresentations: [AppTilePresentation] = []
    private var folderIconTask: Task<Void, Never>?
    private var folderAnimationSourceFrame: CGRect?
    private var folderContentAnimationLayer: CALayer?
    private var folderDimAnimationLayer: CALayer?
    private var folderAnimationGeneration = 0

    private var hasLoadedApplications = false
    private var isLoadingApplications = true

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    // Both window levels display this exact, already-composited desktop image.
    // Independent visual-effect backdrops cannot agree at their shared edge.
    var desktopBackdropImage: NSImage? { wallpaperView.image }
    private(set) var desktopImage: NSImage?

    func resetForNewPresentation() {
        searchField.resetForPresentation()
        window?.makeFirstResponder(self)
        searchDidChange()
    }

    func prepareForPresentation(displayContext: DisplayContext) {
        if self.displayContext != displayContext {
            update(displayContext: displayContext)
        } else {
            updateWallpaper()
        }
        layoutSubtreeIfNeeded()
    }

    init(frame frameRect: NSRect, displayContext: DisplayContext) {
        self.displayContext = displayContext
        super.init(frame: frameRect)
        wantsLayer = true
        configureCanvas()
        setAccessibilityRole(.group)
        setAccessibilityLabel("OpenLaunchpad")
        searchField.onTextChanged = { [weak self] in
            self?.searchDidChange()
        }
        searchField.onCancel = { [weak self] in
            self?.requestClose()
        }
        searchField.onResetRequested = { [weak self] in
            self?.confirmResetLaunchpad()
        }
        addSubview(searchField)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            pagingDisplayLink?.invalidate()
            pagingDisplayLink = nil
        } else if pagingDisplayLink == nil {
            configurePagingDisplayLink()
        }

        guard window != nil, !hasLoadedApplications else { return }
        hasLoadedApplications = true
        window?.makeFirstResponder(self)

        Task { [weak self] in
            guard let self else { return }
            let discovery = await catalog.refreshOutcome()
            applications = discovery.applications
            do {
                let reconciliation = try await layoutStore.reconcileAndCommit(
                    applications: discovery.applications,
                    completeness: discovery.completeness
                )
                layoutDocument = reconciliation.document
            } catch {
                layoutDocument = LauncherLayoutReconciler.reconcile(
                    LauncherLayoutDocument(),
                    with: discovery.applications,
                    completeness: discovery.completeness
                ).document
            }
            isLoadingApplications = false
            selectedIndex = -1
            resetPageTransition()
            invalidatePageSurfaceCache()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        render()
    }

    func update(displayContext: DisplayContext) {
        cancelDragInteraction(animated: false)
        closeFolder(animated: false)
        resetPageTransition()
        pageScrollGesture = PageScrollGesture()
        self.displayContext = displayContext
        frame = CGRect(origin: .zero, size: displayContext.frame.size)
        updateWallpaper()
        invalidatePageSurfaceCache()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        guard
            !isPageTransitionActive,
            dragSession == nil,
            !isFinishingDragVisuals,
            !isResettingLayout
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        if openFolderID != nil {
            if !folderPanelFrame.contains(point) {
                closeFolder()
            }
            return
        }
        requestClose()
    }

    override func keyDown(with event: NSEvent) {
        guard !isFinishingDragVisuals, !isResettingLayout else { return }

        if event.keyCode == 53, dragStateMachine.state != .idle {
            cancelDragInteraction()
            return
        }
        if openFolderID != nil {
            switch event.keyCode {
            case 53:
                closeFolder()
            case 123:
                moveFolderSelection(.left)
            case 124:
                moveFolderSelection(.right)
            case 125:
                moveFolderSelection(.down)
            case 126:
                moveFolderSelection(.up)
            case 36, 76:
                activateSelectedFolderItem()
            case 116:
                changeFolderPage(by: -1)
            case 121:
                changeFolderPage(by: 1)
            default:
                break
            }
            return
        }

        switch event.keyCode {
        case 53:
            requestClose()
        case 123:
            moveSelection(.left)
        case 124:
            moveSelection(.right)
        case 125:
            moveSelection(.down)
        case 126:
            moveSelection(.up)
        case 36, 76:
            activateSelectedItem()
        default:
            focusSearch(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard
            dragStateMachine.state == .idle,
            !isCommittingLayout,
            !isFinishingDragVisuals,
            !isResettingLayout
        else { return }

        if openFolderID != nil {
            if let direction = folderPageScrollGesture.consume(event) {
                changeFolderPage(by: direction)
            }
            return
        }

        // Finish the current transition without snapping back on a new gesture.
        // Keep rejecting that gesture's remainder even if settling ends midway.
        // Phase-less wheels must still update the discrete gesture's idle clock,
        // otherwise a long burst could be mistaken for a second page turn.
        if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            if pageSwipeInputGate.consumes(
                phase: PageScrollPhase(event.phase),
                momentum: PageScrollMomentum(event.momentumPhase),
                isAnimating: pageTransitionAnimator.isAnimating
                    || interactivePageSwipe?.phase == .settling
            ) {
                return
            }
        }

        // Precise trackpad gestures use direct manipulation:
        // the page follows the fingers, then settles after release.
        if handleInteractivePageSwipe(event) {
            return
        }

        // Mouse wheels / phase-less events keep the discrete fallback.
        if let direction = pageScrollGesture.consume(event) {
            changePage(
                by: direction,
                queuesDuringTransition: false
            )
        }
    }
}

private extension LaunchpadRootView {
    var layoutPreferences: UserLayoutPreferences {
        UserLayoutPreferences(isRightToLeft: userInterfaceLayoutDirection == .rightToLeft)
    }

    var resolvedItems: [ResolvedLaunchpadItem] {
        ResolvedLaunchpadItemFactory.makeItems(
            document: layoutDocument,
            applications: applications,
            query: searchField.stringValue
        )
    }

    var isSearchActive: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func configureCanvas() {
        wallpaperView.imageFrameStyle = .none
        wallpaperView.imageAlignment = .alignCenter
        // Provider has already applied the desktop's placement on a full-screen
        // canvas. Do not fit/crop the wallpaper a second time inside this view.
        wallpaperView.imageScaling = .scaleAxesIndependently
        wallpaperView.wantsLayer = true
        wallpaperView.layer?.masksToBounds = true
        wallpaperView.setAccessibilityHidden(true)
        addSubview(wallpaperView)
        updateWallpaper()

        canvasView.wantsLayer = true
        canvasView.layer = rootLayer
        addSubview(canvasView)

        rootLayer.masksToBounds = true
        rootLayer.addSublayer(fixedBackgroundLayer)
        rootLayer.addSublayer(pageContentLayer)
        rootLayer.addSublayer(fixedOverlayLayer)

        pageIndicatorLayer.alignmentMode = .center
        pageIndicatorLayer.fontSize = 15.5
        pageIndicatorLayer.foregroundColor = NSColor.white.withAlphaComponent(0.86).cgColor
        fixedOverlayLayer.addSublayer(pageIndicatorLayer)
        fixedOverlayLayer.addSublayer(folderOverlayLayer)
        fixedOverlayLayer.addSublayer(dragOverlayLayer)
        folderOverlayLayer.isHidden = true
    }

    func updateWallpaper() {
        let images = DesktopWallpaperProvider.images(for: displayContext.displayID)
        desktopImage = images?.desktop
        wallpaperView.image = images?.frosted
        wallpaperView.layer?.backgroundColor = DesktopWallpaperProvider.fallbackColor.cgColor
    }

    func pageProjection(metrics: GridMetrics, document: LauncherLayoutDocument? = nil) -> ResolvedLaunchpadPages {
        ResolvedLaunchpadItemFactory.makePages(
            document: document ?? layoutDocument,
            applications: applications,
            query: searchField.stringValue,
            pageCapacity: metrics.itemsPerPage
        )
    }

    func render() {
        guard
            !isPageTransitionActive,
            dragSession == nil,
            !isCommittingLayout,
            !isFinishingDragVisuals,
            !isResettingLayout
        else { return }

        let scale =
            window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 1

        updateCanvasGeometry(scale: scale)

        let items = resolvedItems
        let metrics = solver.solve(
            display: displayContext,
            requested: layoutPreferences,
            itemCount: items.count
        )
        currentMetrics = metrics
        positionSearchField(in: metrics.searchReservedFrame)

        let configuration = PageSurfaceConfiguration(
            bounds: bounds,
            scale: scale,
            contentRevision: contentRevision,
            metrics: metrics
        )
        if configuration != renderedConfiguration {
            rebuildPageSurfaces(
                items: items,
                metrics: metrics,
                scale: scale,
                configuration: configuration
            )
        }

        let pageCount = pageProjection(metrics: metrics).pageCount
        currentPage = min(currentPage, max(0, pageCount - 1))
        let direction = pendingPageDirection
        pendingPageDirection = 0

        activatePageSurface(
            at: currentPage,
            direction: direction,
            scale: scale
        )
        updatePageIndicator(
            pageCount: pageCount,
            metrics: metrics,
            scale: scale
        )
        updateSelectionAppearance()

        if !isPageTransitionActive {
            stageAdjacentPageSurfaces(scale: scale)
            scheduleIconPrewarming(metrics: metrics, scale: scale)
        }
    }

    func updateCanvasGeometry(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperView.frame = bounds
        canvasView.frame = bounds
        rootLayer.frame = bounds
        rootLayer.contentsScale = scale
        fixedBackgroundLayer.frame = bounds
        fixedOverlayLayer.frame = bounds
        folderOverlayLayer.frame = bounds
        dragOverlayLayer.frame = bounds
        pageIndicatorLayer.contentsScale = scale
        CATransaction.commit()
    }

    func rebuildPageSurfaces(
        items: [ResolvedLaunchpadItem],
        metrics: GridMetrics,
        scale: CGFloat,
        configuration: PageSurfaceConfiguration
    ) {
        cancelIconPrewarming()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var retired = Set<ObjectIdentifier>()

        if let activeSurface {
            retired.insert(ObjectIdentifier(activeSurface))
            detachButtons(from: activeSurface)
            activeSurface.layer.removeAllAnimations()
            activeSurface.layer.opacity = 0
            activeSurface.layer.isHidden = true
            activeSurface.layer.removeFromSuperlayer()
        }

        for surface in pageSurfaces.values {
            guard retired.insert(ObjectIdentifier(surface)).inserted else {
                continue
            }
            detachButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.opacity = 0
            surface.layer.isHidden = true
            surface.layer.removeFromSuperlayer()
        }

        CATransaction.commit()

        pageSurfaces.removeAll(keepingCapacity: true)
        activeSurface = nil

        let pageCount = pageProjection(metrics: metrics).pageCount
        for pageIndex in 0 ..< pageCount {
            pageSurfaces[pageIndex] = makePageSurface(
                pageIndex: pageIndex,
                items: items,
                metrics: metrics,
                scale: scale
            )
        }
        renderedConfiguration = configuration
    }

    func makePageSurface(
        pageIndex: Int,
        items: [ResolvedLaunchpadItem],
        metrics: GridMetrics,
        scale: CGFloat,
        projection: ResolvedLaunchpadPages? = nil
    ) -> LaunchpadPageSurface {
        let layer = CALayer()
        layer.frame = bounds
        layer.contentsScale = scale
        let surface = LaunchpadPageSurface(pageIndex: pageIndex, layer: layer)

        guard !items.isEmpty else {
            addStatusText(
                isLoadingApplications ? "Loading applications…" : "No matching applications",
                to: layer,
                scale: scale
            )
            return surface
        }

        let projection = projection ?? pageProjection(metrics: metrics)
        let range = projection.range(forPage: pageIndex)
        let startIndex = range.lowerBound
        let endIndex = range.upperBound
        guard startIndex < endIndex else { return surface }
        let visibleCount = endIndex - startIndex
        let centersSearchResults = isSearchActive

        for (localIndex, item) in items[startIndex ..< endIndex].enumerated() {
            let frames = centersSearchResults
                ? metrics.centeredItemFrames(forItemAt: localIndex, visibleItemCount: visibleCount)
                : metrics.itemFrames(forItemAt: localIndex)
            guard let frames else { continue }
            let entry = makePageEntry(
                item: item,
                absoluteIndex: startIndex + localIndex,
                frames: frames,
                metrics: metrics,
                scale: scale
            )
            layer.addSublayer(entry.tileLayer)
            surface.entries.append(entry)
        }
        return surface
    }

    func makePageEntry(
        item: ResolvedLaunchpadItem,
        absoluteIndex: Int,
        frames: GridItemFrames,
        metrics: GridMetrics,
        scale: CGFloat
    ) -> LaunchpadPageEntry {
        let presentation: LaunchpadTilePresentation
        switch item {
        case let .application(application):
            presentation = .application(AppTilePresentationFactory.make(AppTileRenderInput(
                application: application,
                cellFrame: frames.cell,
                iconFrame: frames.icon,
                labelFrame: frames.label,
                scale: scale,
                selected: absoluteIndex == selectedIndex,
                icon: iconCache.cgImage(for: application, pointSize: metrics.iconSize, scale: scale)
            )))
        case let .folder(folder):
            let childIcons = folder.applications.compactMap {
                iconCache.cgImage(for: $0, pointSize: metrics.iconSize, scale: scale)
            }
            presentation = .folder(AppTilePresentationFactory.make(FolderTileRenderInput(
                folderID: folder.id,
                title: folder.title,
                cellFrame: frames.cell,
                iconFrame: frames.icon,
                labelFrame: frames.label,
                scale: scale,
                selected: absoluteIndex == selectedIndex,
                childIcons: childIcons,
                layoutDirection: userInterfaceLayoutDirection
            )))
        }

        let entry = LaunchpadPageEntry(
            item: item,
            absoluteIndex: absoluteIndex,
            frames: frames,
            presentation: presentation
        )
        configurePageEntry(entry)
        return entry
    }

    func configurePageEntry(_ entry: LaunchpadPageEntry) {
        let button = entry.button
        button.frame = entry.frames.icon
        button.target = self
        if button is AppTileButton {
            button.action = #selector(applicationButtonPressed(_:))
        } else {
            button.action = #selector(folderButtonPressed(_:))
        }

        button.onHoverChanged = { [weak self, weak iconLayer = entry.iconLayer] isHovering in
            self?.animateHover(on: iconLayer, isHovering: isHovering)
        }
        button.onPointerDown = { [weak self, weak entry] event in
            self?.tilePointerDown(entry: entry, event: event)
        }
        button.onPointerDragged = { [weak self] update in
            self?.tilePointerDragged(update)
        }
        button.onPointerUp = { [weak self] release in
            self?.tilePointerUp(release)
        }
        button.onPointerCancelled = { [weak self] in
            self?.tilePointerCancelled()
        }
    }

    func activatePageSurface(
        at pageIndex: Int,
        direction: Int,
        scale: CGFloat
    ) {
        guard let incomingSurface = pageSurfaces[pageIndex] else { return }
        let outgoingSurface = activeSurface

        if outgoingSurface === incomingSurface {
            attachButtons(to: incomingSurface, hidden: false)
            return
        }

        if let outgoingSurface {
            attachButtons(to: outgoingSurface, hidden: true)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingSurface.layer.frame = bounds
        incomingSurface.layer.contentsScale = scale
        incomingSurface.layer.opacity = 1
        incomingSurface.layer.isHidden = false
        if incomingSurface.layer.superlayer == nil {
            rootLayer.insertSublayer(
                incomingSurface.layer,
                below: fixedOverlayLayer
            )
        }
        CATransaction.commit()

        pageContentLayer = incomingSurface.layer
        activeSurface = incomingSurface

        let transition = outgoingSurface.flatMap { _ in
            LaunchpadVisualStyle.pageTransition(
                direction: direction,
                displayWidth: bounds.width
            )
        }

        guard let outgoingSurface, let transition else {
            attachButtons(to: incomingSurface, hidden: false)
            setPageHitTargetsEnabled(true)
            return
        }

        beginPageTransition(
            from: outgoingSurface.layer,
            to: incomingSurface.layer,
            direction: direction,
            style: transition
        )
    }


    // OPENLAUNCHPAD_ULTRA_SMOOTH_PAGING_V1
    //
    // Keep currentPage and the immediate neighbours already attached one viewport
    // off-screen. A trackpad gesture then starts by changing only two CALayer
    // positions; it does not construct a page tree or churn the NSView hierarchy.
    func stageAdjacentPageSurfaces(scale: CGFloat) {
        // OPENLAUNCHPAD_PAGING_LONG_SESSION_PERF_V1
        //
        // Paging visuals and pointer hit-targets have different lifetimes:
        //
        // - CALayers: keep current +/- 1 staged for instant interactive paging.
        // - NSButtons/NSTrackingAreas: keep ONLY the current page attached.
        //
        // Previously every visited adjacent page's hidden buttons stayed in the
        // NSView hierarchy. Because each tile owns an NSTrackingArea, repeated
        // paging steadily increased AppKit hit-testing / tracking bookkeeping.
        guard
            interactivePageSwipe == nil,
            !pageTransitionAnimator.isAnimating
        else { return }

        let restingPosition = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        let width = max(1, bounds.width)

        // First update compositor topology only. Do not mix NSView hierarchy
        // mutation into the Core Animation transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (pageIndex, surface) in pageSurfaces {
            let pageDistance = pageIndex - currentPage

            if abs(pageDistance) <= 1 {
                surface.layer.removeAllAnimations()
                surface.layer.frame = bounds
                surface.layer.contentsScale = scale
                surface.layer.position = CGPoint(
                    x: restingPosition.x
                        + CGFloat(pageDistance) * width,
                    y: restingPosition.y
                )
                surface.layer.opacity = 1
                surface.layer.isHidden = false

                if surface.layer.superlayer == nil {
                    rootLayer.insertSublayer(
                        surface.layer,
                        below: fixedOverlayLayer
                    )
                }
            } else {
                surface.layer.removeAllAnimations()
                surface.layer.removeFromSuperlayer()
            }
        }

        CATransaction.commit()

        // AppKit input topology is deliberately much smaller than the visual
        // topology. Incoming pages do not need buttons while they are sliding;
        // their icon/label CALayers are sufficient for rendering.
        for (pageIndex, surface) in pageSurfaces {
            if pageIndex == currentPage {
                attachButtons(
                    to: surface,
                    hidden: false
                )
            } else {
                detachButtons(from: surface)
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment[
            "OPENLAUNCHPAD_PAGING_DIAGNOSTICS"
        ] == "1" {
            let attachedTileButtons = pageSurfaces.values.reduce(into: 0) {
                total, surface in
                total += surface.entries.reduce(into: 0) {
                    pageTotal, entry in
                    if entry.button.superview != nil {
                        pageTotal += 1
                    }
                }
            }

            let stagedPageLayers = pageSurfaces.values.reduce(into: 0) {
                total, surface in
                if surface.layer.superlayer != nil {
                    total += 1
                }
            }

            // Count from the actual compositor tree as well as the cache. A
            // dropped cache entry must not hide an attached, retired page tree.
            let trackedPageLayers = Set(pageSurfaces.values.map {
                ObjectIdentifier($0.layer)
            })
            let orphanPageTrees = (rootLayer.sublayers ?? []).filter {
                $0 !== fixedBackgroundLayer
                    && $0 !== fixedOverlayLayer
                    && !trackedPageLayers.contains(ObjectIdentifier($0))
                    && !($0.sublayers?.isEmpty ?? true)
            }.count

            print(
                "[PagingPerf] current=\(currentPage) "
                    + "buttons=\(attachedTileButtons) "
                    + "stagedLayers=\(stagedPageLayers) "
                    + "orphanPageTrees=\(orphanPageTrees) "
                    + "pages=\(pageSurfaces.count)"
            )
        }
        #endif
    }

    func attachButtons(to surface: LaunchpadPageSurface, hidden: Bool) {
        for entry in surface.entries {
            let button = entry.button
            if button.superview == nil {
                addSubview(button, positioned: .below, relativeTo: searchField)
            }
            button.frame = entry.frames.icon
            button.isEnabled = !hidden
            button.isHidden = hidden || openFolderID != nil
        }
    }

    func detachButtons(from surface: LaunchpadPageSurface) {
        for entry in surface.entries {
            entry.button.removeFromSuperview()
        }
    }

    func updatePageIndicator(pageCount: Int, metrics: GridMetrics, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageIndicatorLayer.frame = metrics.pageIndicatorReservedFrame
        pageIndicatorLayer.string = (0 ..< pageCount)
            .map { $0 == currentPage ? "●" : "○" }
            .joined(separator: "  ")
        pageIndicatorLayer.contentsScale = scale
        CATransaction.commit()
    }

    func addStatusText(_ text: String, to layer: CALayer, scale: CGFloat) {
        let statusLayer = CATextLayer()
        statusLayer.frame = CGRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
        statusLayer.string = text
        statusLayer.alignmentMode = .center
        statusLayer.fontSize = 16
        statusLayer.foregroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        statusLayer.contentsScale = scale
        layer.addSublayer(statusLayer)
    }

    func positionSearchField(in reservedFrame: CGRect) {
        let size = LaunchpadVisualStyle.searchFieldSize(forDisplayWidth: bounds.width)
        searchField.frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: reservedFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    func animatePressed(
        on iconLayer: CALayer?,
        isPressed: Bool
    ) {
        guard let iconLayer else { return }

        let targetOpacity: Float =
            isPressed ? 0.78 : 1.0

        let currentOpacity =
            iconLayer.presentation()?.opacity
            ?? iconLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.opacity = targetOpacity
        CATransaction.commit()

        let animation =
            CABasicAnimation(keyPath: "opacity")

        animation.fromValue = currentOpacity
        animation.toValue = targetOpacity

        animation.duration =
            isPressed ? 0.07 : 0.10

        animation.timingFunction =
            CAMediaTimingFunction(name: .easeOut)

        iconLayer.add(
            animation,
            forKey: "iconPressedOpacity"
        )
    }

    func animateHover(on iconLayer: CALayer?, isHovering: Bool) {
        guard let iconLayer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        iconLayer.setAffineTransform(isHovering ? .init(scaleX: 1.045, y: 1.045) : .identity)
        CATransaction.commit()
    }

    func invalidatePageSurfaceCache() {
        cancelIconPrewarming()
        contentRevision &+= 1
        renderedConfiguration = nil
        // Keep ownership until rebuildPageSurfaces retires every attached tree.
        // Clearing this cache here would abandon the staged adjacent pages in
        // rootLayer, accumulating stale layers after search or layout changes.
    }
}

private extension LaunchpadRootView {
    func moveSelection(_ movement: GridNavigationMovement) {
        guard !isPageTransitionActive, let metrics = currentMetrics else { return }
        let items = resolvedItems
        let currentSelection = items.indices.contains(selectedIndex) ? selectedIndex : pageProjection(metrics: metrics).range(forPage: currentPage).first
        guard let index = GridSelectionNavigator.nextIndex(
            from: currentSelection,
            movement: movement,
            currentPage: currentPage,
            itemsPerPage: metrics.itemsPerPage,
            columns: metrics.columns,
            itemCount: items.count,
            isRightToLeft: metrics.isRightToLeft
        ) else { return }
        select(index: index, itemsPerPage: metrics.itemsPerPage)
    }

    func select(index: Int, itemsPerPage: Int) {
        let items = resolvedItems
        guard !items.isEmpty else { return }
        let previousPage = currentPage
        selectedIndex = min(max(index, 0), items.count - 1)
        currentPage = currentMetrics.flatMap { pageProjection(metrics: $0).pageIndex(containing: selectedIndex) } ?? 0
        pendingPageDirection = currentPage == previousPage ? 0 : currentPage - previousPage
        updateSelectionAppearance()
        needsLayout = true
    }

    func updateSelectionAppearance() {
        for surface in pageSurfaces.values {
            for entry in surface.entries {
                entry.selectionLayer.opacity = entry.absoluteIndex == selectedIndex ? 1 : 0
            }
        }
    }

    func changePage(
        by offset: Int,
        queuesDuringTransition: Bool = true
    ) {
        guard interactivePageSwipe == nil else { return }
        if pageTransitionAnimator.isAnimating {
            if queuesDuringTransition {
                _ = pageTransitionAnimator.queueLatestIfAnimating(
                    direction: offset
                )
            }
            return
        }
        guard let metrics = currentMetrics else { return }
        let count = pageProjection(metrics: metrics).pageCount
        guard count > 0 else { return }
        let nextPage = min(max(currentPage + offset, 0), count - 1)
        guard nextPage != currentPage else { return }
        pendingPageDirection = nextPage - currentPage
        currentPage = nextPage
        selectedIndex = -1
        needsLayout = true
    }

    func activateSelectedItem() {
        guard !isPageTransitionActive else { return }
        let items = resolvedItems
        guard items.indices.contains(selectedIndex) else { return }
        activate(items[selectedIndex])
    }

    func activate(_ item: ResolvedLaunchpadItem) {
        switch item {
        case let .application(application):
            launch(application)
        case let .folder(folder):
            openFolder(folder.id, sourceFrame: folderSourceFrame(for: folder.id))
        }
    }

    func launch(_ application: ApplicationRecord) {
        if NSWorkspace.shared.open(application.bundleURL) {
            requestClose()
        }
    }

    @objc func applicationButtonPressed(_ sender: AppTileButton) {
        guard
            !isPageTransitionActive,
            dragSession == nil,
            !isFinishingDragVisuals
        else { return }
        launch(sender.application)
    }

    @objc func folderButtonPressed(_ sender: FolderTileButton) {
        guard
            !isPageTransitionActive,
            dragSession == nil,
            !isFinishingDragVisuals
        else { return }
        openFolder(sender.folderID, sourceFrame: sender.frame)
    }

    func focusSearch(with event: NSEvent) {
        let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard
            event.modifierFlags.isDisjoint(with: commandModifiers),
            let characters = event.characters,
            !characters.isEmpty,
            characters.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            super.keyDown(with: event)
            return
        }

        searchField.focus(in: window)
        searchField.insertText(characters)
    }

    func searchDidChange() {
        cancelDragInteraction(animated: false)
        closeFolder(animated: false)
        resetPageTransition()
        pageScrollGesture = PageScrollGesture()
        currentPage = 0
        selectedIndex = -1
        invalidatePageSurfaceCache()
        needsLayout = true
    }

    func requestClose() {
        cancelDragInteraction(animated: false)
        (window as? LaunchpadWindow)?.dismiss()
    }

    func confirmResetLaunchpad() {
        guard
            !isResettingLayout,
            !isPageTransitionActive,
            dragSession == nil,
            !isCommittingLayout,
            !isFinishingDragVisuals,
            let window
        else {
            NSSound.beep()
            return
        }

        isResettingLayout = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Launchpad?"
        alert.informativeText = "This removes your custom app order and folders, then restores the default alphabetical layout."
        alert.addButton(withTitle: "Reset Launchpad")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard response == .alertFirstButtonReturn else {
                    isResettingLayout = false
                    return
                }
                await resetLaunchpad()
            }
        }
    }

    func resetLaunchpad() async {
        cancelDragInteraction(animated: false)
        closeFolder(animated: false)
        searchField.resetForPresentation()
        window?.makeFirstResponder(self)
        setPageHitTargetsEnabled(false)
        let discovery = await catalog.refreshOutcome()
        do {
            let resetDocument = try await layoutStore.reset(
                applications: discovery.applications,
                completeness: discovery.completeness
            )
            applications = discovery.applications
            layoutDocument = resetDocument
            currentPage = 0
            selectedIndex = -1
            resetPageTransition()
            pageScrollGesture = PageScrollGesture()
            invalidatePageSurfaceCache()
            isResettingLayout = false
            setPageHitTargetsEnabled(true)
            window?.makeFirstResponder(self)
            needsLayout = true
        } catch {
            isResettingLayout = false
            setPageHitTargetsEnabled(true)
            presentResetFailure(error)
        }
    }

    func presentResetFailure(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launchpad Couldn’t Be Reset"
        if error as? LauncherLayoutStoreError == .incompleteCatalogForReset {
            alert.informativeText = "The application scan was incomplete, so your current layout was kept unchanged. Try again in a moment."
        } else {
            alert.informativeText = "Your current layout was kept unchanged."
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

private extension LaunchpadRootView {
    func beginPageTransition(
        from outgoingLayer: CALayer,
        to incomingLayer: CALayer,
        direction: Int,
        style: LaunchpadVisualStyle.PageTransition
    ) {
        cancelIconPrewarming()
        setPageHitTargetsEnabled(false)

        let request = PageTransitionAnimator.Request(
            outgoingLayer: outgoingLayer,
            incomingLayer: incomingLayer,
            direction: direction,
            style: style,
            canvasBounds: bounds
        )
        pageTransitionAnimator.start(request) { [weak self] queuedDirection in
            guard let self else { return }

            if let activeSurface {
                attachButtons(to: activeSurface, hidden: false)
            }
            setPageHitTargetsEnabled(true)

            if queuedDirection != 0 {
                changePage(by: queuedDirection)
                render()
                return
            }

            if let metrics = currentMetrics {
                let scale = window?.backingScaleFactor ?? 1
                stageAdjacentPageSurfaces(scale: scale)
                scheduleIconPrewarming(metrics: metrics, scale: scale)
            }
        }
    }

    func configurePagingDisplayLink() {
        pagingDisplayLink?.invalidate()

        // NSView.displayLink(...) follows the physical display containing this
        // view. Keep the default frame-rate range so Core Animation can use the
        // display's native cadence: typically 60 Hz, or up to 120 Hz on
        // ProMotion displays.
        let link = displayLink(
            target: self,
            selector: #selector(pagingDisplayLinkDidFire(_:))
        )

        link.isPaused = true
        link.add(
            to: RunLoop.main,
            forMode: .common
        )

        pagingDisplayLink = link
    }

    @objc
    func pagingDisplayLinkDidFire(_ link: CADisplayLink) {
        guard
            !link.isPaused,
            let swipe = interactivePageSwipe,
            swipe.phase == .tracking,
            swipe.needsPresentationUpdate
        else {
            return
        }

        presentInteractivePageSwipe(swipe)
    }

    func presentInteractivePageSwipe(
        _ swipe: InteractivePageSwipe
    ) {
        guard swipe.phase == .tracking else { return }

        swipe.needsPresentationUpdate = false

        let outgoingPosition = CGPoint(
            x: swipe.restingPosition.x + swipe.translation,
            y: swipe.restingPosition.y
        )

        let incomingPosition = CGPoint(
            x: swipe.restingPosition.x
                + CGFloat(swipe.direction) * swipe.width
                + swipe.translation,
            y: swipe.restingPosition.y
        )

        // One compositor transaction per physical display refresh.
        //
        // Trackpad events may arrive faster, slower, or irregularly relative
        // to refresh. Coalescing them here avoids presenting multiple model
        // updates between two visible frames.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        swipe.outgoingSurface.layer.position = outgoingPosition
        swipe.incomingSurface.layer.position = incomingPosition

        CATransaction.commit()
    }

    func handleInteractivePageSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else {
            return false
        }

        let disposition = InteractivePageSwipeDecision.disposition(
            hasActiveSwipe: interactivePageSwipe != nil,
            phase: PageScrollPhase(event.phase),
            hasHorizontalMovement: event.scrollingDeltaX != 0,
            isHorizontalDominant: abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        switch disposition {
        case .useDiscretePaging:
            if interactivePageSwipe != nil {
                cancelInteractivePageSwipeImmediately()
            }
            return false
        case .cancel:
            finishInteractivePageSwipe(commit: false)
            return true
        case .finish:
            return finishInteractivePageSwipeAfterRelease()
        case .beginOrUpdate:
            return continueInteractivePageSwipe(event)
        }
    }

    func finishInteractivePageSwipeAfterRelease() -> Bool {
        guard let swipe = interactivePageSwipe else { return false }
        guard swipe.phase == .tracking else { return true }
        let width = max(1, swipe.width)

        let progress = min(
            1,
            max(
                0,
                -swipe.translation
                    * CGFloat(swipe.direction)
                    / width
            )
        )
        let forwardVelocity =
            -swipe.velocity * CGFloat(swipe.direction)
        let normalizedForwardVelocity = forwardVelocity / width
        // A native-feeling trackpad flick should not require dragging a large
        // fraction of the screen. Project the release briefly forward and allow
        // a short, intentional flick to commit while still rejecting tiny jitter.
        let projectedProgress =
            progress + normalizedForwardVelocity * 0.10

        // Launchpad paging should react to intent, not require a long drag.
        //
        // A short deliberate horizontal movement is enough to commit:
        // - ~2.5% page travel commits even at a gentle release.
        // - A very short flick can commit from ~0.8% when it has velocity.
        //
        // Horizontal-dominance filtering and the one-page-per-gesture gate
        // still protect against ordinary trackpad jitter.
        let commit =
            progress >= 0.025
                || (
                    progress >= 0.012
                        && projectedProgress >= 0.040
                )
                || (
                    progress >= 0.008
                        && normalizedForwardVelocity >= 0.25
                )

        finishInteractivePageSwipe(commit: commit)
        return true
    }

    func continueInteractivePageSwipe(_ event: NSEvent) -> Bool {
        guard interactivePageSwipe?.phase != .settling else { return true }
        // Native paging ignores inertial scrolling after the finger releases.
        if !event.momentumPhase.isEmpty {
            return true
        }

        if event.phase.contains(.began) {
            cancelInteractivePageSwipeImmediately()
        }

        if interactivePageSwipe == nil {
            let direction =
                event.scrollingDeltaX < 0 ? 1 : -1

            let didBegin = beginInteractivePageSwipe(
                direction: direction,
                timestamp: event.timestamp
            )
            if didBegin {
                // Do not let partial vertical accumulation from an earlier event
                // leak into the discrete gesture that follows this swipe.
                pageScrollGesture = PageScrollGesture()
            }
        }

        if let swipe = interactivePageSwipe,
           event.scrollingDeltaX != 0
        {
            updateInteractivePageSwipe(
                swipe,
                deltaX: event.scrollingDeltaX,
                timestamp: event.timestamp
            )
        }

        return true
    }

    @discardableResult
    func beginInteractivePageSwipe(
        direction: Int,
        timestamp: TimeInterval
    ) -> Bool {
        guard
            !pageTransitionAnimator.isAnimating,
            interactivePageSwipe == nil,
            let metrics = currentMetrics,
            let outgoingSurface = activeSurface
        else {
            return false
        }

        let pageCount = pageProjection(metrics: metrics).pageCount
        let targetPage = currentPage + direction
        guard
            (0 ..< pageCount).contains(targetPage),
            let incomingSurface = pageSurfaces[targetPage]
        else {
            return false
        }

        cancelIconPrewarming()
        setPageHitTargetsEnabled(false)

        let scale = window?.backingScaleFactor ?? 1
        let restingPosition = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        let width = max(1, bounds.width)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        outgoingSurface.layer.removeAllAnimations()
        incomingSurface.layer.removeAllAnimations()

        outgoingSurface.layer.frame = bounds
        outgoingSurface.layer.contentsScale = scale
        outgoingSurface.layer.position = restingPosition
        outgoingSurface.layer.opacity = 1
        outgoingSurface.layer.isHidden = false

        incomingSurface.layer.frame = bounds
        incomingSurface.layer.contentsScale = scale
        incomingSurface.layer.position = CGPoint(
            x: restingPosition.x + CGFloat(direction) * width,
            y: restingPosition.y
        )
        incomingSurface.layer.opacity = 1
        incomingSurface.layer.isHidden = false

        if incomingSurface.layer.superlayer == nil {
            rootLayer.insertSublayer(
                incomingSurface.layer,
                below: fixedOverlayLayer
            )
        }

        CATransaction.commit()

        // The incoming page needs only its CALayer during the gesture.
        // Its NSButton/NSTrackingArea hit targets are attached only if this page
        // becomes current after settle completes. This keeps gesture begin free
        // of NSView hierarchy churn and keeps long-session view count bounded.

        interactivePageGeneration &+= 1
        interactivePageSwipe = InteractivePageSwipe(
            outgoingSurface: outgoingSurface,
            incomingSurface: incomingSurface,
            targetPage: targetPage,
            direction: direction,
            restingPosition: restingPosition,
            width: width,
            timestamp: timestamp
        )
        return true
    }

    func updateInteractivePageSwipe(
        _ swipe: InteractivePageSwipe,
        deltaX: CGFloat,
        timestamp: TimeInterval
    ) {
        guard swipe.phase == .tracking else { return }
        let rawElapsed = timestamp - swipe.lastTimestamp
        let elapsed = min(
            1.0 / 24.0,
            max(1.0 / 240.0, rawElapsed)
        )
        swipe.lastTimestamp = timestamp

        // Protect against a rare huge NSEvent delta without adding any filter or
        // latency to ordinary trackpad movement.
        // AppKit's precise trackpad delta is deliberately conservative for a
        // full-screen page. A modest gain keeps the page visually attached to
        // a light two-finger swipe without turning the gesture into a jump.
        let trackingGain: CGFloat = 1.60
        let adjustedDelta = deltaX * trackingGain
        let maximumDelta = swipe.width * 0.18
        let boundedDelta = min(
            maximumDelta,
            max(-maximumDelta, adjustedDelta)
        )

        let instantaneousVelocity = boundedDelta / elapsed
        let maximumVelocity = swipe.width * 8.0
        let boundedVelocity = min(
            maximumVelocity,
            max(-maximumVelocity, instantaneousVelocity)
        )

        // Fixed 0.72/0.28 filtering changes behaviour with event frequency.
        // A time-constant filter feels the same at 60 Hz, 120 Hz and under
        // irregular event delivery. It affects release physics only.
        let velocityTimeConstant = 0.034
        let velocityAlpha =
            1 - exp(-Double(elapsed) / velocityTimeConstant)
        swipe.velocity +=
            (boundedVelocity - swipe.velocity) * CGFloat(velocityAlpha)

        let proposed = swipe.translation + boundedDelta
        if swipe.direction > 0 {
            swipe.translation = min(0, max(-swipe.width, proposed))
        } else {
            swipe.translation = max(0, min(swipe.width, proposed))
        }

        // Keep input sampling completely finger-driven, but present the newest
        // translation only on the physical display's refresh boundary.
        //
        // Multiple trackpad events between two refreshes collapse into one
        // compositor update; on ProMotion the same path naturally gets more
        // opportunities to present.
        swipe.needsPresentationUpdate = true

        if let pagingDisplayLink {
            pagingDisplayLink.isPaused = false
        } else {
            // Defensive fallback. Normal macOS 15 presentation always has the
            // NSView display link configured.
            presentInteractivePageSwipe(swipe)
        }
    }

    func finishInteractivePageSwipe(commit: Bool) {
        guard let swipe = interactivePageSwipe, swipe.phase == .tracking else { return }

        // Make the last input sample available to Core Animation before the
        // compositor-driven settle begins.
        if swipe.needsPresentationUpdate {
            presentInteractivePageSwipe(swipe)
        }

        pagingDisplayLink?.isPaused = true
        swipe.phase = .settling
        interactivePageGeneration &+= 1
        let generation = interactivePageGeneration

        let finalTranslation = commit ? -CGFloat(swipe.direction) * swipe.width : 0
        let outgoingStart = swipe.outgoingSurface.layer.presentation()?.position
            ?? swipe.outgoingSurface.layer.position
        let incomingStart = swipe.incomingSurface.layer.presentation()?.position
            ?? swipe.incomingSurface.layer.position
        let outgoingEnd = CGPoint(
            x: swipe.restingPosition.x + finalTranslation,
            y: swipe.restingPosition.y
        )
        let incomingEnd = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width + finalTranslation,
            y: swipe.restingPosition.y
        )

        // Use the position actually displayed, not a potentially newer input
        // sample. One cubic preserves release velocity all the way into rest;
        // stretching its duration afterward would introduce a sudden slowdown.
        guard let transition = LaunchpadVisualStyle.interactivePageSettleTransition(
            direction: swipe.direction,
            displayWidth: swipe.width,
            releaseVelocity: swipe.velocity,
            targetDelta: outgoingEnd.x - outgoingStart.x
        ) else {
            completeInteractivePageSwipe(swipe, commit: commit)
            return
        }

        func animation(from start: CGPoint, to end: CGPoint) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = NSValue(point: start)
            animation.toValue = NSValue(point: end)
            animation.duration = transition.duration
            animation.timingFunction = transition.timingFunction
            return animation
        }

        // Commit model endpoints and both animations together. No intermediate
        // transaction may expose the destination before its animation exists.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    generation == interactivePageGeneration,
                    interactivePageSwipe === swipe
                else { return }
                completeInteractivePageSwipe(swipe, commit: commit)
            }
        }
        swipe.outgoingSurface.layer.position = outgoingEnd
        swipe.incomingSurface.layer.position = incomingEnd
        swipe.outgoingSurface.layer.add(
            animation(from: outgoingStart, to: outgoingEnd),
            forKey: "interactivePageOut"
        )
        swipe.incomingSurface.layer.add(
            animation(from: incomingStart, to: incomingEnd),
            forKey: "interactivePageIn"
        )
        CATransaction.commit()
    }

    func completeInteractivePageSwipe(
        _ swipe: InteractivePageSwipe,
        commit: Bool
    ) {
        pagingDisplayLink?.isPaused = true

        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        let scale = window?.backingScaleFactor ?? 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if commit {
            swipe.incomingSurface.layer.position = swipe.restingPosition
            swipe.outgoingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x
                    - CGFloat(swipe.direction) * swipe.width,
                y: swipe.restingPosition.y
            )
        } else {
            swipe.outgoingSurface.layer.position = swipe.restingPosition
            swipe.incomingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x
                    + CGFloat(swipe.direction) * swipe.width,
                y: swipe.restingPosition.y
            )
        }

        CATransaction.commit()

        if commit {
            // The outgoing page remains staged as CALayers only. Detaching its
            // hit targets removes its NSTrackingAreas from AppKit bookkeeping.
            detachButtons(from: swipe.outgoingSurface)

            pageContentLayer = swipe.incomingSurface.layer
            activeSurface = swipe.incomingSurface
            currentPage = swipe.targetPage
            selectedIndex = -1

            attachButtons(
                to: swipe.incomingSurface,
                hidden: false
            )
        } else {
            // Cancelled incoming pages never need pointer hit targets.
            detachButtons(from: swipe.incomingSurface)
            attachButtons(
                to: swipe.outgoingSurface,
                hidden: false
            )
        }

        interactivePageSwipe = nil
        setPageHitTargetsEnabled(true)
        updateSelectionAppearance()

        if let metrics = currentMetrics {
            let pageCount = pageProjection(metrics: metrics).pageCount
            updatePageIndicator(
                pageCount: pageCount,
                metrics: metrics,
                scale: scale
            )

            // Visible motion is already complete; topology maintenance cannot
            // steal time from the settle animation anymore.
            stageAdjacentPageSurfaces(scale: scale)
            scheduleIconPrewarming(metrics: metrics, scale: scale)
        }
    }

    func cancelInteractivePageSwipeImmediately() {
        guard let swipe = interactivePageSwipe else { return }

        pagingDisplayLink?.isPaused = true
        interactivePageGeneration &+= 1
        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipe.outgoingSurface.layer.position = swipe.restingPosition
        swipe.incomingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x
                + CGFloat(swipe.direction) * swipe.width,
            y: swipe.restingPosition.y
        )
        CATransaction.commit()

        interactivePageSwipe = nil
        detachButtons(from: swipe.incomingSurface)
        attachButtons(
            to: swipe.outgoingSurface,
            hidden: false
        )
        setPageHitTargetsEnabled(true)

        stageAdjacentPageSurfaces(
            scale: window?.backingScaleFactor ?? 1
        )
    }

    func resetPageTransition() {
        cancelIconPrewarming()
        cancelInteractivePageSwipeImmediately()
        pageSwipeInputGate = PageSwipeInputGate()
        pendingPageDirection = 0
        pageTransitionAnimator.reset(contentLayer: pageContentLayer, canvasBounds: bounds)
        setPageHitTargetsEnabled(true)
    }

    func setPageHitTargetsEnabled(_ enabled: Bool) {
        guard let activeSurface else { return }
        for entry in activeSurface.entries {
            entry.button.isEnabled = enabled
            entry.button.isHidden = !enabled || openFolderID != nil
        }
    }

    func scheduleIconPrewarming(
        metrics: GridMetrics,
        scale: CGFloat
    ) {
        guard
            !applications.isEmpty,
            !isLoadingApplications,
            !isPageTransitionActive
        else { return }

        let revision = contentRevision
        let currentSurface = pageSurfaces[currentPage]
        let adjacentPageIndices = [
            currentPage - 1,
            currentPage + 1,
        ].filter {
            pageSurfaces[$0] != nil
        }

        iconPrewarmTask?.cancel()

        iconPrewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // The visible page has highest priority. Two decoders are enough to
            // populate it quickly without creating a large I/O/decode burst.
            if let currentSurface {
                await iconCache.warm(
                    uniqueApplications(in: currentSurface),
                    pointSize: metrics.iconSize,
                    scale: scale,
                    maximumConcurrentLoads: 2
                )

                guard
                    !Task.isCancelled,
                    revision == contentRevision,
                    !isPageTransitionActive
                else { return }

                refreshIcons(
                    in: currentSurface,
                    pointSize: metrics.iconSize,
                    scale: scale
                )
            }

            // Warm only the two pages that can participate in the NEXT gesture.
            // Deduplication matters for folders/app aliases that can reference the
            // same underlying application icon.
            var adjacentApplications: [ApplicationRecord] = []
            var seen: Set<ApplicationIdentity> = []

            for pageIndex in adjacentPageIndices {
                guard
                    let surface = pageSurfaces[pageIndex]
                else { continue }

                for application in uniqueApplications(in: surface) {
                    if seen.insert(application.id).inserted {
                        adjacentApplications.append(application)
                    }
                }
            }

            await iconCache.warm(
                adjacentApplications,
                pointSize: metrics.iconSize,
                scale: scale,
                maximumConcurrentLoads: 2
            )

            guard
                !Task.isCancelled,
                revision == contentRevision,
                !isPageTransitionActive
            else { return }

            for pageIndex in adjacentPageIndices {
                guard
                    let surface = pageSurfaces[pageIndex]
                else { continue }

                refreshIcons(
                    in: surface,
                    pointSize: metrics.iconSize,
                    scale: scale
                )
            }
        }
    }

    func uniqueApplications(in surface: LaunchpadPageSurface) -> [ApplicationRecord] {
        var seen: Set<ApplicationIdentity> = []
        return surface.entries.flatMap(\.item.applicationsForIconRendering).filter {
            seen.insert($0.id).inserted
        }
    }

    func refreshIcons(in surface: LaunchpadPageSurface, pointSize: CGFloat, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in surface.entries {
            switch entry.presentation {
            case let .application(presentation):
                guard case let .application(application) = entry.item else { continue }
                presentation.iconLayer.contents = iconCache.cgImage(
                    for: application,
                    pointSize: pointSize,
                    scale: scale
                )
            case let .folder(presentation):
                guard case let .folder(folder) = entry.item else { continue }
                let childIcons = folder.applications.compactMap {
                    iconCache.cgImage(for: $0, pointSize: pointSize, scale: scale)
                }
                AppTilePresentationFactory.updateFolderIcon(
                    presentation,
                    childIcons: childIcons,
                    scale: scale,
                    layoutDirection: userInterfaceLayoutDirection
                )
            }
        }
        CATransaction.commit()
    }

    func cancelIconPrewarming() {
        iconPrewarmTask?.cancel()
        iconPrewarmTask = nil
    }
}

private extension LaunchpadRootView {
    func tilePointerDown(entry: LaunchpadPageEntry?, event: NSEvent) {
        guard
            let entry,
            !isSearchActive,
            openFolderID == nil,
            !isPageTransitionActive,
            !isCommittingLayout,
            !isFinishingDragVisuals,
            dragStateMachine.pointerDown(on: entry.item.id)
        else { return }

        pendingPress = PendingTilePress(
            entry: entry,
            point: convert(event.locationInWindow, from: nil)
        )

        animatePressed(
            on: entry.iconLayer,
            isPressed: true
        )
    }

    func tilePointerDragged(_ update: TilePointerDragUpdate) {
        guard update.hasExceededActivationDistance else { return }
        let point = convert(update.event.locationInWindow, from: nil)
        if dragSession == nil {
            beginDragInteraction(at: point)
        }
        updateDragInteraction(at: point)
    }

    func tilePointerUp(_ release: TilePointerRelease) {
        defer { pendingPress = nil }
        guard release.wasDrag else {
            if let pendingPress {
                animatePressed(
                    on: pendingPress.entry.iconLayer,
                    isPressed: false
                )
            }

            dragStateMachine.finish()
            return
        }
        completeDragInteraction(at: convert(release.event.locationInWindow, from: nil))
    }

    func tilePointerCancelled() {
        if dragSession != nil {
            cancelDragInteraction()
        } else {
            if let pendingPress {
                animatePressed(
                    on: pendingPress.entry.iconLayer,
                    isPressed: false
                )
            }

            pendingPress = nil
            dragStateMachine.finish()
        }
    }

    func beginDragInteraction(at point: CGPoint) {
        guard
            let pendingPress,
            let originalSurface = activeSurface,
            dragStateMachine.beginDragging(),
            let draft = try? LauncherLayoutDraft(
                document: layoutDocument.normalizedForPageCapacity(currentMetrics?.itemsPerPage ?? 1)
            )
        else { return }

        cancelIconPrewarming()

        let pointerOffset = CGVector(
            dx: pendingPress.point.x
                - pendingPress.entry.frames.cell.midX,
            dy: pendingPress.point.y
                - pendingPress.entry.frames.cell.midY
        )

        let proxyLayer = makeDragProxy(
            for: pendingPress.entry,
            initialPoint: pendingPress.point
        )

        let session = LaunchpadDragSession(
            sourceEntry: pendingPress.entry,
            draft: draft,
            proxyLayer: proxyLayer,
            pointerOffset: pointerOffset,
            originalSurface: originalSurface,
            sourcePage: currentPage
        )

        dragSession = session

        // Hand the exact pressed appearance from the source tile to the drag
        // proxy in one display transaction. Building a second page here used to
        // expose one frame containing both copies, which appeared as a flash.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragOverlayLayer.addSublayer(proxyLayer)
        // The drag proxy is the only visible owner of the source item. Detach
        // the real tile instead of leaving a transparent copy in the render
        // tree; it will be reattached atomically when the landing completes.
        pendingPress.entry.tileLayer.removeFromSuperlayer()
        animateDragLift(
            proxyLayer,
            from: pendingPress.entry.frames.cell.center,
            to: point,
            offset: pointerOffset
        )
        CATransaction.commit()
    }

    func updateDragInteraction(at point: CGPoint, allowsEdgePaging: Bool = true) {
        guard let session = dragSession else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.proxyLayer.position = CGPoint(
            x: point.x - session.pointerOffset.dx, y: point.y - session.pointerOffset.dy
        )
        CATransaction.commit()
        session.lastPointerPoint = point
        guard !session.isEdgePageTransitionActive else { return }
        if allowsEdgePaging && !session.hasReleased {
            updateDragEdgePaging(at: point, session: session)
        }
        // An edge is outside the icon grid, but a page already reached by this
        // drag has a valid landing slot. Keep it valid even on the first/last page.
        if session.hasCrossedPages, let metrics = currentMetrics,
           dragEdgeDirection(at: point, metrics: metrics) != nil {
            if let location = session.previewLocation {
                setDragTarget(.pageInsertion(page: location.page, index: location.index), session: session)
            }
            return
        }
        let target = dropTarget(at: point, source: session.sourceEntry)
        if case let .pageInsertion(page, index) = target, let metrics = currentMetrics {
            updateDragPreviewLayout(session, location: DragPageLocation(page: page, index: index),
                                    animated: true, metrics: metrics)
        }
        setDragTarget(target, session: session)
    }

    func setDragTarget(_ target: LauncherDropTarget, session: LaunchpadDragSession) {
        session.target = target
        _ = dragStateMachine.update(target: target)
        updateDropHighlight(target)
    }

    private enum DragEdgeMetrics {
        static let minimumWidth: CGFloat = 56
        static let maximumWidth: CGFloat = 96
        static let widthFraction: CGFloat = 0.04
        static let dwell: Duration = .milliseconds(400)
        static let pageDuration: CFTimeInterval = 0.45
    }

    func dragEdgeDirection(at point: CGPoint, metrics: GridMetrics) -> Int? {
        let edgeWidth = min(DragEdgeMetrics.maximumWidth,
                            max(DragEdgeMetrics.minimumWidth, bounds.width * DragEdgeMetrics.widthFraction))
        guard point.y >= metrics.contentFrame.minY, point.y <= metrics.contentFrame.maxY,
              point.x >= bounds.minX, point.x <= bounds.maxX else { return nil }
        if point.x <= bounds.minX + edgeWidth { return metrics.isRightToLeft ? 1 : -1 }
        if point.x >= bounds.maxX - edgeWidth { return metrics.isRightToLeft ? -1 : 1 }
        return nil
    }

    func updateDragEdgePaging(at point: CGPoint, session: LaunchpadDragSession) {
        guard let metrics = currentMetrics, !session.isEdgePageTransitionActive, !session.hasReleased else { return }
        let direction = dragEdgeDirection(at: point, metrics: metrics)
        // Existing pages may be traversed freely. Offer one temporary trailing
        // page, not an unbounded train of empty pages while the pointer rests.
        let existingCount = session.draft.snapshot.normalizedForPageCapacity(metrics.itemsPerPage).pages.count
        guard let direction, (0...existingCount).contains(currentPage + direction) else {
            session.edgePagingTask?.cancel()
            session.edgePagingTask = nil
            session.edgePagingDirection = nil
            return
        }
        guard session.edgePagingDirection != direction || session.edgePagingTask == nil else { return }
        session.edgePagingTask?.cancel()
        session.edgePagingDirection = direction
        session.edgePagingTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: DragEdgeMetrics.dwell)
            guard !Task.isCancelled, let self, let session,
                  self.dragSession === session, !session.hasReleased,
                  !session.isEdgePageTransitionActive,
                  session.edgePagingDirection == direction,
                  let metrics = self.currentMetrics,
                  self.dragEdgeDirection(at: session.lastPointerPoint, metrics: metrics) == direction else { return }
            session.edgePagingTask = nil
            self.performDragEdgePageTurn(direction: direction, session: session)
        }
    }

    func projectedDocument(_ session: LaunchpadDragSession, location: DragPageLocation,
                           metrics: GridMetrics) -> LauncherLayoutDocument? {
        guard var draft = try? LauncherLayoutDraft(document: session.draft.snapshot) else { return nil }
        do {
            try draft.moveRootItem(session.sourceEntry.item.id, toPage: location.page,
                                   at: location.index, pageCapacity: metrics.itemsPerPage)
            return draft.document
        } catch { return nil }
    }

    func performDragEdgePageTurn(direction: Int, session: LaunchpadDragSession) {
        guard dragSession === session, !session.hasReleased,
              !session.isEdgePageTransitionActive, let metrics = currentMetrics,
              let outgoing = session.previewSurface ?? activeSurface else { return }
        let baseline = session.draft.snapshot.normalizedForPageCapacity(metrics.itemsPerPage)
        let targetPage = currentPage + direction
        guard (0...baseline.pages.count).contains(targetPage) else { return }
        let targetItems = baseline.pages.indices.contains(targetPage) ? baseline.pages[targetPage] : []
        let sourceID = session.sourceEntry.item.id
        let targetCount = targetItems.filter { item in
            switch (item, sourceID) {
            case let (.application(ref), .application(id)): return ref.identity != id
            case let (.folder(folder), .folder(id)): return folder.id != id
            default: return true
            }
        }.count
        // Reserve an actual slot on a full page, so the dragged app stays here;
        // the previous final app overflows forward. A partial page may append.
        let location = DragPageLocation(
            page: targetPage, index: direction > 0 ? min(targetCount, metrics.itemsPerPage - 1) : 0
        )
        guard let document = projectedDocument(session, location: location, metrics: metrics) else { return }
        let projection = pageProjection(metrics: metrics, document: document)
        let scale = window?.backingScaleFactor ?? 1
        let incoming = makePageSurface(pageIndex: targetPage, items: projection.items,
                                       metrics: metrics, scale: scale, projection: projection)
        incoming.entries.first { $0.item.id == sourceID }?.tileLayer.removeFromSuperlayer()
        session.mergeCandidate = nil
        session.mergeCandidateBeganAt = nil
        session.previewLocation = location
        session.projectedDocument = document
        session.hasCrossedPages = true
        session.edgeGeneration &+= 1
        let generation = session.edgeGeneration
        session.isEdgePageTransitionActive = true
        session.edgeIncomingSurface = incoming
        session.edgeOutgoingSurface = outgoing
        setDragTarget(.pageInsertion(page: location.page, index: location.index), session: session)

        // Retire every other visible page tree before bringing in the projection.
        // The source button stays attached until mouseUp even on a return visit.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surface in pageSurfaces.values where surface !== outgoing {
            surface.layer.removeAllAnimations()
            surface.layer.removeFromSuperlayer()
        }
        let resting = CGPoint(x: bounds.midX, y: bounds.midY)
        let visualDirection = CGFloat(metrics.isRightToLeft ? -direction : direction)
        let distance = visualDirection * bounds.width
        outgoing.layer.removeAllAnimations()
        outgoing.layer.frame = bounds
        outgoing.layer.opacity = 1
        outgoing.layer.isHidden = false
        incoming.layer.position = CGPoint(x: resting.x + distance, y: resting.y)
        rootLayer.insertSublayer(incoming.layer, below: fixedOverlayLayer)
        CATransaction.commit()

        let finish = { [weak self, weak session] in
            guard let self, let session, self.dragSession === session,
                  session.edgeGeneration == generation else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outgoing.layer.removeAllAnimations()
            outgoing.layer.removeFromSuperlayer()
            incoming.layer.removeAllAnimations()
            incoming.layer.position = resting
            CATransaction.commit()
            if let stale = self.pageSurfaces[targetPage], stale !== incoming {
                if stale !== session.originalSurface { self.detachButtons(from: stale) }
                stale.layer.removeFromSuperlayer()
            }
            self.currentPage = targetPage
            self.activeSurface = incoming
            self.pageContentLayer = incoming.layer
            self.pageSurfaces[targetPage] = incoming
            session.previewSurface = incoming
            session.usesInPlacePreview = false
            session.isEdgePageTransitionActive = false
            session.edgeIncomingSurface = nil
            session.edgeOutgoingSurface = nil
            session.edgePagingDirection = nil
            self.updatePageIndicator(pageCount: projection.pageCount, metrics: metrics, scale: scale)
            if let point = session.pendingCompletionPoint {
                session.pendingCompletionPoint = nil
                self.completeDragInteraction(at: point)
            } else {
                // Re-arm from this page; no exit/re-entry requirement.
                self.updateDragInteraction(at: session.lastPointerPoint)
            }
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { finish(); return }
        let timing = CAMediaTimingFunction(controlPoints: 0.24, 0.12, 0.28, 1)
        func animation(_ start: CGPoint, _ end: CGPoint) -> CABasicAnimation {
            let result = CABasicAnimation(keyPath: "position")
            result.fromValue = NSValue(point: start)
            result.toValue = NSValue(point: end)
            result.duration = DragEdgeMetrics.pageDuration
            result.timingFunction = timing
            return result
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { Task { @MainActor in finish() } }
        let outgoingEnd = CGPoint(x: resting.x - distance, y: resting.y)
        outgoing.layer.position = outgoingEnd
        incoming.layer.position = resting
        outgoing.layer.add(animation(resting, outgoingEnd), forKey: "dragEdgePageOut")
        incoming.layer.add(animation(CGPoint(x: resting.x + distance, y: resting.y), resting), forKey: "dragEdgePageIn")
        CATransaction.commit()
    }

    func updateDragPreviewLayout(
        _ session: LaunchpadDragSession,
        location: DragPageLocation,
        animated: Bool,
        metrics: GridMetrics
    ) {
        let previousLocation = session.previewLocation
        guard previousLocation != location,
              let document = projectedDocument(session, location: location, metrics: metrics) else { return }
        session.previewLocation = location
        session.projectedDocument = document
        let projection = pageProjection(metrics: metrics, document: document)
        let items = projection.items
        let range = projection.range(forPage: currentPage)
        var targetFrames: [LauncherLayoutItemIdentifier: GridItemFrames] = [:]
        var targetIndices: [LauncherLayoutItemIdentifier: Int] = [:]
        for (localIndex, item) in items[range].enumerated() {
            if let frames = metrics.itemFrames(forItemAt: localIndex) {
                targetFrames[item.id] = frames
                targetIndices[item.id] = range.lowerBound + localIndex
            }
        }
        let previousRank = (previousLocation?.page ?? session.sourcePage) * metrics.itemsPerPage
            + (previousLocation?.index ?? 0)
        let transition = LaunchpadVisualStyle.dragReflowTransition(
            movedForward: location.page * metrics.itemsPerPage + location.index > previousRank
        )
        let scale = window?.backingScaleFactor ?? 1
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion



        let workingSurface:
            LaunchpadPageSurface = {
                if session
                    .usesInPlacePreview
                {
                    return session
                        .originalSurface
                }

                if let previewSurface =
                    session.previewSurface
                {
                    return previewSurface
                }

                return session
                    .originalSurface
            }()

        let workingIDs =
            Set(
                workingSurface
                    .entries
                    .map {
                        $0.item.id
                    }
            )

        let targetIDs =
            Set(
                targetFrames.keys
            )

        if workingIDs == targetIDs {
            if session.previewSurface == nil {
                session
                    .usesInPlacePreview = true

                activeSurface =
                    session
                        .originalSurface

                pageContentLayer =
                    session
                        .originalSurface
                        .layer
            }

            CATransaction.begin()

            CATransaction
                .setDisableActions(
                    true
                )

            workingSurface
                .layer
                .opacity = 1

            workingSurface
                .layer
                .isHidden = false

            for entry
                in workingSurface.entries
            {
                guard
                    let targetFrame =
                        targetFrames[
                            entry.item.id
                        ],
                    let targetIndex =
                        targetIndices[
                            entry.item.id
                        ]
                else {
                    continue
                }

                // 取真正螢幕上目前的位置。
                //
                // 如果使用者很快從 A -> B -> C，
                // 新動畫直接從 presentation position
                // 接續，不跳回上一個 model position。
                let visiblePosition =
                    entry
                        .tileLayer
                        .presentation()?
                        .position
                        ?? entry
                            .tileLayer
                            .position

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragReflowPosition"
                    )

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragRollbackPosition"
                    )

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragReflowOpacity"
                    )

                entry
                    .tileLayer
                    .position =
                        targetFrame
                            .cell
                            .center

                entry
                    .tileLayer
                    .opacity = 1

                entry.frames =
                    targetFrame

                entry.absoluteIndex =
                    targetIndex

                if entry.item.id
                    == session
                        .sourceEntry
                        .item
                        .id
                {
                    // Source item 仍然只有 drag proxy
                    // 是唯一 visual owner。
                    //
                    // source NSButton 不在 drag 中移動，
                    // 避免 AppKit mouse tracking view
                    // 在 mouseDown -> mouseUp 中途換 frame。
                    entry
                        .tileLayer
                        .removeFromSuperlayer()

                    continue
                }

                entry.button.frame =
                    targetFrame.icon

                guard
                    shouldAnimate,
                    visiblePosition
                        != targetFrame
                            .cell
                            .center
                else {
                    continue
                }

                let move =
                    CABasicAnimation(
                        keyPath:
                            "position"
                    )

                move.fromValue =
                    NSValue(
                        point:
                            visiblePosition
                    )

                move.toValue =
                    NSValue(
                        point:
                            targetFrame
                                .cell
                                .center
                    )

                move.duration =
                    transition.duration

                move.timingFunction =
                    transition
                        .timingFunction

                entry
                    .tileLayer
                    .add(
                        move,
                        forKey:
                            "dragReflowPosition"
                    )
            }

            CATransaction.commit()

            return
        }

        // ----------------------------------------------------
        // Defensive fallback.
        //
        // 理論上目前同頁 drag 不會走到這裡。
        // 只有未來真的加入 cross-page membership change
        // 才需要 materialize 新 surface。
        // ----------------------------------------------------

        let previousSurface =
            workingSurface

        let newSurface =
            makePageSurface(
                pageIndex:
                    currentPage,
                items:
                    items,
                metrics:
                    metrics,
                scale: scale,
                projection: projection
            )

        var oldPositions:
            [
                LauncherLayoutItemIdentifier:
                    CGPoint
            ] = [:]

        for entry
            in previousSurface.entries
        {
            oldPositions[
                entry.item.id
            ] =
                entry
                    .tileLayer
                    .presentation()?
                    .position
                    ?? entry
                        .tileLayer
                        .position
        }

        CATransaction.begin()

        CATransaction
            .setDisableActions(
                true
            )

        newSurface.layer.frame =
            bounds

        newSurface
            .layer
            .contentsScale =
                scale

        newSurface
            .layer
            .opacity = 1

        newSurface
            .layer
            .isHidden = false

        for entry
            in newSurface.entries
        {
            let targetPosition =
                entry
                    .tileLayer
                    .position

            if entry.item.id
                == session
                    .sourceEntry
                    .item
                    .id
            {
                entry
                    .tileLayer
                    .removeFromSuperlayer()

                continue
            }

            guard shouldAnimate else {
                continue
            }

            let startPosition:
                CGPoint

            if let oldPosition =
                oldPositions[
                    entry.item.id
                ]
            {
                startPosition =
                    oldPosition
            } else {
                startPosition =
                    CGPoint(
                        x:
                            targetPosition.x
                                + transition
                                    .enteringItemOffset,
                        y:
                            targetPosition.y
                    )

                let fade =
                    CABasicAnimation(
                        keyPath:
                            "opacity"
                    )

                fade.fromValue = 0
                fade.toValue = 1

                fade.duration =
                    transition
                        .enteringItemFadeDuration

                fade.timingFunction =
                    transition
                        .timingFunction

                entry
                    .tileLayer
                    .add(
                        fade,
                        forKey:
                            "dragReflowOpacity"
                    )
            }

            guard
                startPosition
                    != targetPosition
            else {
                continue
            }

            let move =
                CABasicAnimation(
                    keyPath:
                        "position"
                )

            move.fromValue =
                NSValue(
                    point:
                        startPosition
                )

            move.toValue =
                NSValue(
                    point:
                        targetPosition
                )

            move.duration =
                transition.duration

            move.timingFunction =
                transition
                    .timingFunction

            entry
                .tileLayer
                .add(
                    move,
                    forKey:
                        "dragReflowPosition"
                )
        }

        // 如果未來真的進入 fallback，
        // 舊 surface 必須先失去 render ownership。
        previousSurface
            .layer
            .removeAllAnimations()

        previousSurface
            .layer
            .opacity = 0

        previousSurface
            .layer
            .isHidden = true

        previousSurface
            .layer
            .removeFromSuperlayer()

        rootLayer.insertSublayer(
            newSurface.layer,
            below:
                fixedOverlayLayer
        )

        CATransaction.commit()

        session.previewSurface =
            newSurface

        session
            .usesInPlacePreview = false
    }



    func dropTarget(
        at point: CGPoint,
        source: LaunchpadPageEntry
    ) -> LauncherDropTarget {
        guard let metrics = currentMetrics else {
            return .outside
        }

        let baseline = (dragSession?.draft.snapshot ?? layoutDocument)
            .normalizedForPageCapacity(metrics.itemsPerPage)
        let pageItems = baseline.pages.indices.contains(currentPage) ? baseline.pages[currentPage] : []
        let countWithoutSource = pageItems.filter { item in
            switch (item, source.item.id) {
            case let (.application(ref), .application(id)): return ref.identity != id
            case let (.folder(folder), .folder(id)): return folder.id != id
            default: return true
            }
        }.count
        let insertionTarget: LauncherDropTarget = {
            guard metrics.contentFrame.contains(point),
                  let localIndex = (0..<metrics.itemsPerPage).first(where: {
                      metrics.cellFrame(forItemAt: $0)?.contains(point) == true
                  }) else { return .outside }
            let projection = pageProjection(metrics: metrics, document: baseline)
            let visibleIDs = projection.pages.indices.contains(currentPage)
                ? projection.pages[currentPage].map(\.id) : []
            let pageIDs = pageItems.map { item -> LauncherLayoutItemIdentifier in
                switch item {
                case let .application(reference): return .application(reference.identity)
                case let .folder(folder): return .folder(folder.id)
                }
            }
            guard let index = ResolvedLaunchpadInsertionIndex.resolve(
                visibleSlot: min(localIndex, countWithoutSource),
                pageIdentifiers: pageIDs,
                visibleIdentifiers: visibleIDs,
                sourceIdentifier: source.item.id
            ) else { return .outside }
            return .pageInsertion(page: currentPage, index: index)
        }()

        guard
            case let .application(
                sourceApplication
            ) = source.item,
            let session = dragSession
        else {
            return insertionTarget
        }

        let surface =
            session.previewSurface
                ?? activeSurface

        var candidate:
            LauncherDropTarget?

        if let surface {
            for entry
                in surface.entries
                where entry.item.id
                    != source.item.id
            {
                let mergeFrame =
                    entry.frames.icon
                        .insetBy(
                            dx:
                                entry.frames.icon.width
                                * 0.12,
                            dy:
                                entry.frames.icon.height
                                * 0.12
                        )

                guard
                    mergeFrame.contains(point)
                else {
                    continue
                }

                switch entry.item {
                case let .application(
                    targetApplication
                ):
                    guard
                        targetApplication.id
                            != sourceApplication.id
                    else {
                        continue
                    }

                    candidate =
                        .application(
                            targetApplication.id
                        )

                case let .folder(folder):
                    candidate =
                        .folder(folder.id)
                }

                break
            }
        }

        guard let candidate else {
            session.mergeCandidate = nil
            session.mergeCandidateBeganAt = nil

            return insertionTarget
        }

        let now =
            CACurrentMediaTime()

        if session.mergeCandidate
            != candidate
        {
            session.mergeCandidate =
                candidate

            session.mergeCandidateBeganAt =
                now

            // 不能一碰到 App 就把它推走，
            // 否則永遠無法形成 folder。
            return session.previewLocation.map {
                .pageInsertion(page: $0.page, index: $0.index)
            } ?? insertionTarget
        }

        let beganAt =
            session.mergeCandidateBeganAt
                ?? now

        if now - beganAt >= 0.44 {
            return candidate
        }

        return session.previewLocation.map {
            .pageInsertion(page: $0.page, index: $0.index)
        } ?? insertionTarget
    }

    func updateDropHighlight(
        _ target: LauncherDropTarget
    ) {
        let surface =
            dragSession?.previewSurface
                ?? activeSurface

        guard let surface else {
            return
        }

        CATransaction.begin()

        CATransaction.setAnimationDuration(
            0.12
        )

        CATransaction
            .setAnimationTimingFunction(
                CAMediaTimingFunction(
                    name: .easeOut
                )
            )

        for entry in surface.entries {
            // 不使用舊的透明外框。
            entry.selectionLayer.opacity =
                entry.absoluteIndex
                    == selectedIndex
                ? 1
                : 0

            let isMergeTarget: Bool

            switch target {
            case let .application(identity):
                isMergeTarget =
                    entry.item.id
                        == .application(
                            identity
                        )

            case let .folder(folderID):
                isMergeTarget =
                    entry.item.id
                        == .folder(
                            folderID
                        )

            case .insertion, .pageInsertion, .outside:
                isMergeTarget = false
            }

            entry.iconLayer
                .setAffineTransform(
                    isMergeTarget
                        ? .init(
                            scaleX: 1.08,
                            y: 1.08
                        )
                        : .identity
                )
        }

        CATransaction.commit()
    }

    func completeDragInteraction(at point: CGPoint) {
        guard let dragSession else {
            dragStateMachine.finish()
            return
        }

        dragSession.hasReleased = true
        dragSession.edgePagingTask?.cancel()
        dragSession.edgePagingTask = nil
        dragSession.edgePagingDirection = nil

        // If mouse-up arrives while an edge page is still sliding, preserve the
        // release point and complete the drop when that page becomes active.
        if dragSession.isEdgePageTransitionActive {
            dragSession.pendingCompletionPoint =
                point
            return
        }

        updateDragInteraction(at: point, allowsEdgePaging: false)

        do {
            try applyDropTarget(dragSession.target, to: dragSession)
        } catch {
            cancelDragInteraction()
            return
        }
        guard dragSession.draft.hasChanges, dragStateMachine.beginCommit() else {
            cancelDragInteraction()
            return
        }

        let committingSession = dragSession
        let draft = committingSession.draft
        let commitContext = LaunchpadDragCommitContext(
            session: committingSession
        )
        dragCommitContext = commitContext
        isCommittingLayout = true
        finishDragVisuals(
            dragSession,
            committed: true,
            animated: true
        ) { [weak self, weak commitContext] in
            guard let self, let commitContext else { return }
            commitContext.completionState.markVisualsFinished()
            finishDragCommitIfReady(commitContext)
        }
        self.dragSession = nil
        pendingPress = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                layoutDocument = try await layoutStore.commit(draft)
                selectedIndex = -1
                if let metrics = currentMetrics {
                    currentPage = min(currentPage, pageProjection(metrics: metrics).pageCount - 1)
                }
                if adoptCommittedInsertionPreviewIfPossible(
                    committingSession
                ) {
                    commitContext.didAdoptInsertionPreview = true
                } else {
                    invalidatePageSurfaceCache()
                }

                commitContext
                    .completionState
                    .markPersistenceFinished()
            } catch {
                _ = dragStateMachine.beginRollback()
                committingSession.draft.rollback()
                layoutDocument = committingSession.draft.snapshot
                restoreSnapshotUI(afterFailedCommit: committingSession)
                invalidatePageSurfaceCache()
                NSSound.beep()
                // Restoring the original surface also terminates the visual
                // landing, so a stale Core Animation completion must not keep
                // the interaction locked.
                commitContext.completionState.finishImmediately()
            }
            finishDragCommitIfReady(commitContext)
        }
    }

    func adoptCommittedInsertionPreviewIfPossible(
        _ session: LaunchpadDragSession
    ) -> Bool {
        guard
            session.target.isInsertion,
            let previewSurface = session.previewSurface,
            let metrics = currentMetrics
        else {
            return false
        }

        // Only preserve the preview when it is an exact projection of the
        // document returned by the store.
        //
        // This deliberately keeps partial-catalog, cross-page, and any future
        // edge cases on the safe full-rebuild path.
        let items = resolvedItems

        let projection = pageProjection(metrics: metrics)
        let pageCount = projection.pageCount

        guard pageSurfaces.count == pageCount else {
            return false
        }

        for pageIndex in 0 ..< pageCount {
            let candidateSurface:
                LaunchpadPageSurface? =
                    pageIndex == currentPage
                        ? previewSurface
                        : pageSurfaces[
                            pageIndex
                        ]

            guard let candidateSurface else {
                return false
            }

            let range = projection.range(forPage: pageIndex)
            let startIndex = range.lowerBound
            let endIndex = range.upperBound

            let expectedIDs:
                [LauncherLayoutItemIdentifier]

            if startIndex < endIndex {
                expectedIDs =
                    items[
                        startIndex
                            ..<
                            endIndex
                    ]
                    .map(\.id)
            } else {
                expectedIDs = []
            }

            // `entries` intentionally keeps object identity while tiles reflow,
            // so array order itself is not authoritative. `absoluteIndex` is.
            let actualIDs =
                candidateSurface
                    .entries
                    .sorted {
                        $0.absoluteIndex
                            < $1.absoluteIndex
                    }
                    .map {
                        $0.item.id
                    }

            guard
                actualIDs
                    == expectedIDs
            else {
                return false
            }
        }

        // The live preview is already the committed page.
        //
        // Rebuilding here would create another CALayer tree containing the same
        // icons while the preview's presentation tree is still retiring.
        if let cachedSurface =
            pageSurfaces[
                currentPage
            ],
           cachedSurface
            !== previewSurface
        {
            detachButtons(
                from: cachedSurface
            )

            CATransaction.begin()
            CATransaction
                .setDisableActions(
                    true
                )

            cachedSurface
                .layer
                .removeAllAnimations()

            cachedSurface
                .layer
                .opacity = 0

            cachedSurface
                .layer
                .isHidden = true

            cachedSurface
                .layer
                .removeFromSuperlayer()

            CATransaction.commit()
        }

        pageSurfaces[
            currentPage
        ] = previewSurface

        activeSurface =
            previewSurface

        pageContentLayer =
            previewSurface.layer

        return true
    }

    func finishDragCommitIfReady(
        _ context:
            LaunchpadDragCommitContext
    ) {
        guard
            dragCommitContext
                === context,
            context
                .completionState
                .isReadyToFinalize
        else {
            return
        }

        dragCommitContext = nil
        isCommittingLayout = false

        dragStateMachine.finish()

        // For a normal insertion the preview page has already been proven to be
        // identical to the committed document. Keep that exact layer tree alive
        // instead of replacing it with another copy.
        if context
            .didAdoptInsertionPreview,
           let previewSurface =
            context
                .session
                .previewSurface
        {
            CATransaction.begin()
            CATransaction
                .setDisableActions(
                    true
                )

            previewSurface
                .layer
                .opacity = 1

            previewSurface
                .layer
                .isHidden = false

            // Collapse every drag-only presentation state back to its model
            // value before pointer interaction becomes available again.
            for entry in
                previewSurface.entries
            {
                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragReflowPosition"
                    )

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragReflowOpacity"
                    )

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragRollbackPosition"
                    )

                entry
                    .tileLayer
                    .opacity = 1

                entry
                    .iconLayer
                    .removeAnimation(
                        forKey:
                            "iconPressedOpacity"
                    )

                entry
                    .iconLayer
                    .opacity = 1

                entry
                    .iconLayer
                    .setAffineTransform(
                        .identity
                    )
            }

            CATransaction.commit()

            activeSurface =
                previewSurface

            pageContentLayer =
                previewSurface.layer

            attachButtons(
                to: previewSurface,
                hidden: false
            )

            setPageHitTargetsEnabled(
                true
            )

            updateSelectionAppearance()

            if let metrics =
                currentMetrics
            {
                scheduleIconPrewarming(
                    metrics: metrics,
                    scale:
                        window?
                            .backingScaleFactor
                        ?? 1
                )
            }

            return
        }

        // Folder merge, cross-page mismatch, partial-catalog mismatch, etc.
        // still use the conservative full rebuild.
        needsLayout = true
    }

    func applyDropTarget(_ target: LauncherDropTarget, to session: LaunchpadDragSession) throws {
        switch target {
        case let .pageInsertion(page, index):
            try session.draft.moveRootItem(
                session.sourceEntry.item.id, toPage: page, at: index,
                pageCapacity: currentMetrics?.itemsPerPage ?? 1
            )
        case let .insertion(destination):
            try session.draft.moveRootItem(
                session.sourceEntry.item.id,
                toPositionOf: destination
            )
        case let .application(targetIdentity):
            guard case let .application(sourceIdentity) = session.sourceEntry.item.id else { return }
            try session.draft.mergeApplications(
                source: sourceIdentity,
                target: targetIdentity,
                customTitle: "Folder"
            )
        case let .folder(folderID):
            guard case let .application(sourceIdentity) = session.sourceEntry.item.id else { return }
            try session.draft.addApplication(sourceIdentity, toFolder: folderID)
        case .outside:
            return
        }
    }

    func restoreSnapshotUI(afterFailedCommit session: LaunchpadDragSession) {
        currentPage = session.sourcePage
        session.originalSurface.layer.frame = bounds
        session.originalSurface.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Immutable source geometry also matters after crossing pages.
        do {
            CATransaction.begin()

            CATransaction
                .setDisableActions(
                    true
                )

            for entry
                in session
                    .originalSurface
                    .entries
            {
                guard
                    let originalFrame =
                        session
                            .originalFramesByIdentifier[
                                entry.item.id
                            ]
                else {
                    continue
                }

                entry
                    .tileLayer
                    .removeAllAnimations()

                entry
                    .iconLayer
                    .removeAllAnimations()

                entry.frames =
                    originalFrame

                entry.absoluteIndex =
                    session
                        .originalIndexByIdentifier[
                            entry.item.id
                        ]
                        ?? entry
                            .absoluteIndex

                entry.button.frame =
                    originalFrame.icon

                entry
                    .tileLayer
                    .position =
                        originalFrame
                            .cell
                            .center

                entry
                    .tileLayer
                    .opacity = 1

                entry
                    .iconLayer
                    .opacity = 1

                entry
                    .iconLayer
                    .setAffineTransform(
                        .identity
                    )
            }

            session
                .originalSurface
                .layer
                .opacity = 1

            session
                .originalSurface
                .layer
                .isHidden = false

            CATransaction.commit()
        }

        if let previewSurface = session.previewSurface {
            detachButtons(from: previewSurface)
            previewSurface.layer.removeFromSuperlayer()
        }

        session.proxyLayer.removeAllAnimations()
        session.proxyLayer.removeFromSuperlayer()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.originalSurface.layer.opacity = 1
        if session.sourceEntry.tileLayer.superlayer == nil {
            session.originalSurface.layer.addSublayer(
                session.sourceEntry.tileLayer
            )
        }
        session.sourceEntry.tileLayer.opacity = 1
        session.sourceEntry.iconLayer.opacity = 1
        if session.originalSurface.layer.superlayer == nil {
            rootLayer.insertSublayer(
                session.originalSurface.layer,
                below: fixedOverlayLayer
            )
        }
        CATransaction.commit()

        activeSurface = session.originalSurface
        pageContentLayer = session.originalSurface.layer
        attachButtons(to: session.originalSurface, hidden: false)
    }

    func cancelDragInteraction(animated: Bool = true) {
        pendingPress = nil
        guard !isFinishingDragVisuals else { return }
        guard let dragSession else {
            if dragStateMachine.state != .idle {
                _ = dragStateMachine.beginRollback()
                dragStateMachine.finish()
            }
            return
        }

        dragSession.edgePagingTask?.cancel()
        dragSession.edgePagingTask = nil
        dragSession.pendingCompletionPoint = nil
        dragSession.hasReleased = true
        dragSession.edgeGeneration &+= 1

        _ = dragStateMachine.beginRollback()
        dragSession.draft.rollback()
        isFinishingDragVisuals = true
        if dragSession.hasCrossedPages {
            finishCrossPageRollback(dragSession, animated: animated) { [weak self] in
                guard let self else { return }
                isFinishingDragVisuals = false
                dragStateMachine.finish()
                setPageHitTargetsEnabled(true)
                needsLayout = true
            }
            self.dragSession = nil
            return
        }
        setPageHitTargetsEnabled(false)
        finishDragVisuals(
            dragSession,
            committed: false,
            animated: animated
        ) { [weak self] in
            guard let self else { return }
            isFinishingDragVisuals = false
            dragStateMachine.finish()
            setPageHitTargetsEnabled(true)
            needsLayout = true
        }
        self.dragSession = nil
    }

    func finishCrossPageRollback(_ session: LaunchpadDragSession, animated: Bool,
                                 completion: @escaping () -> Void) {
        session.edgeIncomingSurface?.layer.removeAllAnimations()
        session.edgeIncomingSurface?.layer.removeFromSuperlayer()
        session.edgeOutgoingSurface?.layer.removeAllAnimations()
        session.edgeOutgoingSurface?.layer.removeFromSuperlayer()
        session.previewSurface?.layer.removeFromSuperlayer()
        session.originalSurface.layer.removeFromSuperlayer()
        detachButtons(from: session.originalSurface)
        session.isEdgePageTransitionActive = false
        layoutDocument = session.draft.snapshot
        currentPage = session.sourcePage
        selectedIndex = -1
        invalidatePageSurfaceCache()
        guard let metrics = currentMetrics else {
            session.proxyLayer.removeFromSuperlayer()
            completion()
            return
        }
        let scale = window?.backingScaleFactor ?? 1
        let configuration = PageSurfaceConfiguration(bounds: bounds, scale: scale,
                                                     contentRevision: contentRevision, metrics: metrics)
        rebuildPageSurfaces(items: resolvedItems, metrics: metrics, scale: scale, configuration: configuration)
        guard let restored = pageSurfaces[currentPage],
              let source = restored.entries.first(where: { $0.item.id == session.sourceEntry.item.id }) else {
            session.proxyLayer.removeFromSuperlayer()
            completion()
            return
        }
        activeSurface = restored
        pageContentLayer = restored.layer
        rootLayer.insertSublayer(restored.layer, below: fixedOverlayLayer)
        source.tileLayer.removeFromSuperlayer()
        updatePageIndicator(pageCount: pageProjection(metrics: metrics).pageCount, metrics: metrics, scale: scale)
        let proxy = session.proxyLayer
        refreshDragProxyForRelease(proxy, sourceEntry: session.sourceEntry)
        let start = proxy.presentation()?.position ?? proxy.position
        let end = source.frames.cell.center
        let style = LaunchpadVisualStyle.dragCompletionTransition(kind: .rollback)
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? style.duration : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        proxy.removeAllAnimations()
        proxy.position = end
        if duration > 0 {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: start)
            move.toValue = NSValue(point: end)
            move.duration = duration
            move.timingFunction = style.timingFunction
            proxy.add(move, forKey: "crossPageRollback")
        }
        CATransaction.commit()
        Task { @MainActor in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy.removeFromSuperlayer()
            restored.layer.addSublayer(source.tileLayer)
            CATransaction.commit()
            completion()
        }
    }

    func makeDragProxy(
        for entry: LaunchpadPageEntry,
        initialPoint _: CGPoint
    ) -> CALayer {
        let scale = max(
            1,
            window?.backingScaleFactor ?? 1
        )

        // Snapshot 必須是乾淨的 App tile。
        // 不把 hover scale / pressed opacity /
        // selection outline 烤進拖曳影像。
        let previousSelectionOpacity =
            entry.selectionLayer.opacity

        let modelIconOpacity =
            entry.iconLayer.opacity

        let modelIconTransform =
            entry.iconLayer.affineTransform()

        // `render(in:)` captures model values, while the user is looking at the
        // presentation values of the short press/hover animations. Sample those
        // values first so the proxy's first pixel is identical to the last pixel
        // of the source tile.
        let visibleIconOpacity =
            entry.iconLayer.presentation()?.opacity
            ?? modelIconOpacity

        let visibleIconTransform =
            entry.iconLayer.presentation()?.affineTransform()
            ?? modelIconTransform

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        entry.selectionLayer.opacity = 0

        entry.iconLayer.opacity = visibleIconOpacity
        entry.iconLayer.setAffineTransform(
            visibleIconTransform
        )

        entry.tileLayer.layoutIfNeeded()

        let snapshot =
            snapshotImage(
                of: entry.tileLayer,
                scale: scale
            )

        entry.selectionLayer.opacity =
            previousSelectionOpacity

        entry.iconLayer.opacity =
            modelIconOpacity

        entry.iconLayer.setAffineTransform(
            modelIconTransform
        )

        CATransaction.commit()

        let proxy = CALayer()

        proxy.bounds = CGRect(
            origin: .zero,
            size: entry.frames.cell.size
        )

        proxy.position =
            entry.frames.cell.center

        proxy.anchorPoint =
            CGPoint(
                x: 0.5,
                y: 0.5
            )

        proxy.contents = snapshot
        proxy.contentsGravity = .resize
        proxy.contentsScale = scale

        proxy.minificationFilter = .linear
        proxy.magnificationFilter = .linear

        proxy.opacity = 1
        proxy.zPosition = 10_000

        // show3 的浮起感很輕，
        // 不做過強的陰影。
        // No extra lift effect while dragging.
        // Keep the proxy visually identical to the pressed tile.
        proxy.shadowOpacity = 0
        proxy.shadowRadius = 0
        proxy.shadowOffset = .zero

        return proxy
    }

    /// The drag proxy intentionally mirrors the pressed tile while the pointer is
    /// down. On release, replace that bitmap with a clean, steady-state tile so
    /// the pressed/hover presentation cannot linger as a translucent afterimage
    /// during the landing/reflow interval.
    func refreshDragProxyForRelease(
        _ proxy: CALayer,
        sourceEntry entry: LaunchpadPageEntry
    ) {
        let scale = max(
            1,
            window?.backingScaleFactor ?? 1
        )

        let previousSelectionOpacity =
            entry.selectionLayer.opacity

        // The source tile has already been detached from the visible surface.
        // Press/hover animations therefore have no reason to survive mouse-up.
        //
        // Normalize the model state before rendering the release bitmap so:
        //
        // 1. pressed opacity is not baked into the landing proxy
        // 2. hover scale is not baked into the landing proxy
        // 3. rollback cannot reattach a stale pressed presentation
        entry.iconLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        entry.selectionLayer.opacity = 0

        entry.iconLayer.opacity = 1
        entry.iconLayer.setAffineTransform(.identity)

        entry.tileLayer.layoutIfNeeded()

        let releaseSnapshot =
            snapshotImage(
                of: entry.tileLayer,
                scale: scale
            )

        entry.selectionLayer.opacity =
            previousSelectionOpacity

        if let releaseSnapshot {
            proxy.contents = releaseSnapshot
            proxy.contentsScale = scale
        }

        CATransaction.commit()
    }

    func snapshotImage(
        of layer: CALayer,
        scale: CGFloat
    ) -> CGImage? {
        let size = layer.bounds.size

        guard
            size.width > 0,
            size.height > 0
        else {
            return nil
        }

        let pixelWidth = max(
            1,
            Int(
                ceil(
                    size.width * scale
                )
            )
        )

        let pixelHeight = max(
            1,
            Int(
                ceil(
                    size.height * scale
                )
            )
        )

        let colorSpace =
            CGColorSpaceCreateDeviceRGB()

        let bitmapInfo =
            CGImageAlphaInfo
                .premultipliedLast
                .rawValue

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // CALayer 使用 point，
        // bitmap 使用 Retina pixel。
        context.scaleBy(
            x: scale,
            y: scale
        )

        layer.render(
            in: context
        )

        return context.makeImage()
    }

    func copiedLayer(_ source: CALayer) -> CALayer {
        let copy = CALayer(layer: source)
        copy.sublayers = source.sublayers?.map(copiedLayer)
        return copy
    }

    func animateDragLift(
        _ layer: CALayer,
        from _: CGPoint,
        to point: CGPoint,
        offset: CGVector
    ) {
        let destination = CGPoint(
            x: point.x - offset.dx,
            y: point.y - offset.dy
        )

        // Do not create a separate "lifted" drag appearance.
        //
        // The App should look exactly the same from:
        //
        // mouseDown -> dragging
        //
        // Only its position changes.
        layer.removeAnimation(
            forKey: "dragLiftPosition"
        )

        layer.removeAnimation(
            forKey: "dragLiftScale"
        )

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


    func finishInPlaceDragVisuals(
        _ session: LaunchpadDragSession,
        committed: Bool,
        animated: Bool,
        completion: (() -> Void)?
    ) {
        updateDropHighlight(.outside)

        let surface =
            session.originalSurface

        let proxy =
            session.proxyLayer

        let sourceID =
            session.sourceEntry.item.id

        let shouldAnimate =
            animated
                && !NSWorkspace
                    .shared
                    .accessibilityDisplayShouldReduceMotion

        let completionKind:
            LaunchpadVisualStyle
                .DragCompletionKind

        if !committed {
            completionKind =
                .rollback
        } else {
            switch session.target {
            case .insertion, .pageInsertion,
                 .outside:
                completionKind =
                    .insertion

            case .application,
                 .folder:
                completionKind =
                    .merge
            }
        }

        let completionTransition =
            LaunchpadVisualStyle
                .dragCompletionTransition(
                    kind:
                        completionKind
                )

        let duration:
            CFTimeInterval =
                shouldAnimate
                    ? completionTransition
                        .duration
                    : 0

        let destination:
            CGPoint

        let destinationScale:
            CGFloat

        let destinationOpacity:
            Float

        let shouldRevealSource:
            Bool

        if committed {
            switch session.target {
            case .insertion, .pageInsertion:
                destination =
                    surface
                        .entries
                        .first {
                            $0.item.id
                                == sourceID
                        }?
                        .frames
                        .cell
                        .center
                        ?? session
                            .sourceEntry
                            .frames
                            .cell
                            .center

                destinationScale = 1
                destinationOpacity = 1
                shouldRevealSource = true

            case let .application(
                identity
            ):
                destination =
                    surface
                        .entries
                        .first {
                            $0.item.id
                                == .application(
                                    identity
                                )
                        }?
                        .frames
                        .cell
                        .center
                        ?? proxy.position

                destinationScale = 0.72
                destinationOpacity = 0
                shouldRevealSource = false

            case let .folder(
                folderID
            ):
                destination =
                    surface
                        .entries
                        .first {
                            $0.item.id
                                == .folder(
                                    folderID
                                )
                        }?
                        .frames
                        .cell
                        .center
                        ?? proxy.position

                destinationScale = 0.72
                destinationOpacity = 0
                shouldRevealSource = false

            case .outside:
                destination =
                    session
                        .originalFramesByIdentifier[
                            sourceID
                        ]?
                        .cell
                        .center
                        ?? session
                            .sourceEntry
                            .frames
                            .cell
                            .center

                destinationScale = 1
                destinationOpacity = 1
                shouldRevealSource = true
            }
        } else {
            destination =
                session
                    .originalFramesByIdentifier[
                        sourceID
                    ]?
                    .cell
                    .center
                    ?? session
                        .sourceEntry
                        .frames
                        .cell
                        .center

            destinationScale = 1
            destinationOpacity = 1
            shouldRevealSource = true

            // --------------------------------------------
            // Cancel / rollback:
            //
            // 所有 App 都直接在同一棵 surface
            // 裡回到原始位置。
            //
            // 沒有 previewSurface -> originalSurface
            // handoff。
            // --------------------------------------------

            CATransaction.begin()

            CATransaction
                .setDisableActions(
                    true
                )

            for entry
                in surface.entries
            {
                guard
                    let originalFrame =
                        session
                            .originalFramesByIdentifier[
                                entry.item.id
                            ]
                else {
                    continue
                }

                let visiblePosition =
                    entry
                        .tileLayer
                        .presentation()?
                        .position
                        ?? entry
                            .tileLayer
                            .position

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragReflowPosition"
                    )

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragRollbackPosition"
                    )

                entry
                    .tileLayer
                    .removeAnimation(
                        forKey:
                            "dragReflowOpacity"
                    )

                entry.frames =
                    originalFrame

                entry.absoluteIndex =
                    session
                        .originalIndexByIdentifier[
                            entry.item.id
                        ]
                        ?? entry
                            .absoluteIndex

                entry
                    .tileLayer
                    .position =
                        originalFrame
                            .cell
                            .center

                entry
                    .tileLayer
                    .opacity = 1

                if entry.item.id
                    == sourceID
                {
                    entry
                        .tileLayer
                        .removeFromSuperlayer()

                    continue
                }

                entry.button.frame =
                    originalFrame.icon

                guard
                    shouldAnimate,
                    visiblePosition
                        != originalFrame
                            .cell
                            .center
                else {
                    continue
                }

                let rollback =
                    CABasicAnimation(
                        keyPath:
                            "position"
                    )

                rollback.fromValue =
                    NSValue(
                        point:
                            visiblePosition
                    )

                rollback.toValue =
                    NSValue(
                        point:
                            originalFrame
                                .cell
                                .center
                    )

                rollback.duration =
                    duration

                rollback.timingFunction =
                    completionTransition
                        .timingFunction

                entry
                    .tileLayer
                    .add(
                        rollback,
                        forKey:
                            "dragRollbackPosition"
                    )
            }

            CATransaction.commit()
        }

        // Live source tile 不保留 mouseDown 狀態。
        CATransaction.begin()

        CATransaction
            .setDisableActions(
                true
            )

        surface
            .layer
            .opacity = 1

        surface
            .layer
            .isHidden = false

        session
            .sourceEntry
            .iconLayer
            .removeAnimation(
                forKey:
                    "iconPressedOpacity"
            )

        session
            .sourceEntry
            .iconLayer
            .opacity = 1

        session
            .sourceEntry
            .iconLayer
            .setAffineTransform(
                .identity
            )

        session
            .sourceEntry
            .tileLayer
            .opacity = 1

        CATransaction.commit()

        activeSurface =
            surface

        pageContentLayer =
            surface.layer

        let finalize = {
            [
                weak proxy,
                weak sourceLayer =
                    session
                        .sourceEntry
                        .tileLayer
            ] in

            CATransaction.begin()

            CATransaction
                .setDisableActions(
                    true
                )

            proxy?
                .removeAllAnimations()

            proxy?
                .opacity = 0

            proxy?
                .removeFromSuperlayer()

            if shouldRevealSource,
               let sourceLayer
            {
                sourceLayer
                    .removeAllAnimations()

                sourceLayer
                    .opacity = 1

                if sourceLayer
                    .superlayer == nil
                {
                    // Proxy 已經先移除，
                    // 然後 live source 接手。
                    //
                    // 同一個 transaction，
                    // 不存在兩個 visual owner。
                    surface
                        .layer
                        .addSublayer(
                            sourceLayer
                        )
                }
            }

            // source NSButton 在 mouse tracking
            // 結束後才移到最後位置。
            if let frame =
                committed
                    ? surface
                        .entries
                        .first(
                            where: {
                                $0.item.id
                                    == sourceID
                            }
                        )?
                        .frames
                    : session
                        .originalFramesByIdentifier[
                            sourceID
                        ]
            {
                session
                    .sourceEntry
                    .button
                    .frame =
                        frame.icon
            }

            CATransaction.commit()

            completion?()
        }

        guard shouldAnimate else {
            CATransaction.begin()

            CATransaction
                .setDisableActions(
                    true
                )

            proxy.position =
                destination

            proxy.setAffineTransform(
                .init(
                    scaleX:
                        destinationScale,
                    y:
                        destinationScale
                )
            )

            proxy.opacity =
                destinationOpacity

            CATransaction.commit()

            finalize()

            return
        }

        CATransaction.begin()

        CATransaction
            .setAnimationDuration(
                duration
            )

        CATransaction
            .setAnimationTimingFunction(
                completionTransition
                    .timingFunction
            )

        proxy.position =
            destination

        proxy.setAffineTransform(
            .init(
                scaleX:
                    destinationScale,
                y:
                    destinationScale
            )
        )

        proxy.opacity =
            destinationOpacity

        CATransaction.commit()

        Task { @MainActor in
            try? await Task.sleep(
                for:
                    .seconds(
                        duration
                    )
            )

            finalize()
        }
    }

    func finishDragVisuals(
        _ session: LaunchpadDragSession,
        committed: Bool,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        // Same-page reorder uses one persistent page tree.
        // Never enter the legacy preview/original surface
        // handoff path for this gesture.
        if session.usesInPlacePreview {
            finishInPlaceDragVisuals(
                session,
                committed: committed,
                animated: animated,
                completion: completion
            )
            return
        }

        updateDropHighlight(.outside)

        let proxy =
            session.proxyLayer

        // Mouse-up ends the pressed state immediately.
        //
        // The proxy may stay alive while surrounding tiles finish their reflow,
        // but its bitmap must no longer contain the mouse-down opacity / hover
        // transform. Otherwise the stale snapshot looks like an afterimage after
        // the user has already released the icon.
        refreshDragProxyForRelease(
            proxy,
            sourceEntry: session.sourceEntry
        )

        let previewSurface =
            session.previewSurface

        let originalSurface =
            session.originalSurface

        let sourceID =
            session.sourceEntry.item.id

        let originalSourceLayer =
            session.sourceEntry.tileLayer

        let destination: CGPoint
        let destinationScale: CGFloat
        let destinationOpacity: Float

        var revealLayer: CALayer?
        var revealSurface: LaunchpadPageSurface?

        let shouldAnimate =
            animated
                && !NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion

        let completionKind: LaunchpadVisualStyle.DragCompletionKind

        if !committed {
            completionKind = .rollback
        } else {
            switch session.target {
            case .insertion, .pageInsertion, .outside:
                completionKind = .insertion
            case .application, .folder:
                completionKind = .merge
            }
        }

        let completionTransition =
            LaunchpadVisualStyle.dragCompletionTransition(
                kind: completionKind
            )

        let duration: CFTimeInterval =
            shouldAnimate
                ? completionTransition.duration
                : 0

        if committed {
            switch session.target {
            case .insertion, .pageInsertion:
                let previewSource =
                    previewSurface?
                        .entries
                        .first {
                            $0.item.id
                                == sourceID
                        }

                destination =
                    previewSource?
                        .frames
                        .cell
                        .center
                    ?? session
                        .sourceEntry
                        .frames
                        .cell
                        .center

                destinationScale = 1
                destinationOpacity = 1

                revealLayer =
                    previewSource?
                        .tileLayer

                revealSurface =
                    previewSurface

            case let .application(identity):
                let target =
                    previewSurface?
                        .entries
                        .first {
                            $0.item.id
                                == .application(
                                    identity
                                )
                        }

                destination =
                    target?
                        .frames
                        .cell
                        .center
                    ?? proxy.position

                destinationScale = 0.72
                destinationOpacity = 0

            case let .folder(folderID):
                let target =
                    previewSurface?
                        .entries
                        .first {
                            $0.item.id
                                == .folder(
                                    folderID
                                )
                        }

                destination =
                    target?
                        .frames
                        .cell
                        .center
                    ?? proxy.position

                destinationScale = 0.72
                destinationOpacity = 0

            case .outside:
                destination =
                    session
                        .sourceEntry
                        .frames
                        .cell
                        .center

                destinationScale = 1
                destinationOpacity = 1
            }

            if let previewSurface {
                // The preview becomes the sole visual owner while persistence is pending.
                // Remove the old native views before hiding/removing their backing layer so
                // transparent hit targets and accessibility elements cannot survive promotion.
                detachButtons(
                    from: session.originalSurface
                )

                activeSurface =
                    previewSurface

                pageContentLayer =
                    previewSurface.layer

                // 原 surface 已經不需要顯示，
                // 但保留正確 model state，
                // 以防 layout commit 失敗。
                session
                    .originalSurface
                    .layer
                    .removeFromSuperlayer()

                session
                    .originalSurface
                    .layer
                    .opacity = 1

                session
                    .sourceEntry
                    .tileLayer
                    .opacity = 1
            }
        } else {
            destination =
                session
                    .sourceEntry
                    .frames
                    .cell
                    .center

            destinationScale = 1
            destinationOpacity = 1

            revealLayer =
                originalSourceLayer

            revealSurface =
                originalSurface

            if shouldAnimate, previewSurface != nil {
                // Keep the reordered preview visible while every displaced tile
                // travels back. Revealing the original surface here used to show
                // both layouts during the rollback and created a fading ghost.
                originalSurface.layer.opacity = 0
            } else {
                previewSurface?
                    .layer
                    .removeFromSuperlayer()

                originalSurface.layer.opacity = 1
            }

            activeSurface =
                originalSurface

            pageContentLayer =
                originalSurface.layer
        }

        session
            .sourceEntry
            .iconLayer
            .opacity = 1

        // If mouse-up happens while the dragged tile is already sitting exactly
        // on its insertion slot, there is no source-tile landing motion left to
        // display.
        //
        // Previously the snapshot proxy was still kept alive for the full
        // drag-reflow duration (~0.48 s). That left a stale bitmap sitting on
        // screen after mouse-up and visually read as an afterimage.
        //
        // Promote the real preview tile immediately in that case. Other displaced
        // tiles are still allowed to finish their existing reflow animation, and
        // the normal completion path below still waits for the declared duration.
        if committed,
           session.target.isInsertion,
           let liveLayer = revealLayer,
           let liveSurface = revealSurface
        {
            let visibleProxyPosition =
                proxy.presentation()?.position
                    ?? proxy.position

            let landingDistance = hypot(
                visibleProxyPosition.x - destination.x,
                visibleProxyPosition.y - destination.y
            )

            // Less than one logical point is visually already landed.
            // Keeping the proxy around at this point only creates a stale frame.
            if landingDistance <= 0.75 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                proxy.removeAllAnimations()
                proxy.removeFromSuperlayer()

                if liveLayer.superlayer == nil {
                    liveSurface.layer.addSublayer(
                        liveLayer
                    )
                }

                liveLayer.opacity = 1

                CATransaction.commit()

                // The delayed reflow completion must not perform the source-owner
                // handoff a second time.
                revealLayer = nil
                revealSurface = nil
            }
        }

        guard shouldAnimate else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            proxy.position =
                destination

            proxy.setAffineTransform(
                .init(
                    scaleX:
                        destinationScale,
                    y:
                        destinationScale
                )
            )

            proxy.opacity =
                destinationOpacity

            proxy.removeFromSuperlayer()

            if let revealLayer,
               revealLayer.superlayer == nil,
               let revealSurface
            {
                revealSurface.layer.addSublayer(revealLayer)
            }
            revealLayer?.opacity = 1

            CATransaction.commit()
            completion?()
            return
        }

        let finishPresentation = {
            [weak proxy, weak revealLayer] in

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy?.removeFromSuperlayer()
            if !committed {
                previewSurface?.layer.removeFromSuperlayer()
                originalSurface.layer.opacity = 1
            }
            if let revealLayer,
               revealLayer.superlayer == nil,
               let revealSurface
            {
                revealSurface.layer.addSublayer(revealLayer)
            }
            revealLayer?.opacity = 1
            CATransaction.commit()
            completion?()
        }

        CATransaction.begin()

        CATransaction.setAnimationDuration(
            duration
        )

        CATransaction.setAnimationTimingFunction(
            completionTransition.timingFunction
        )

        if !committed, let previewSurface {
            var originalPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]
            for entry in originalSurface.entries {
                originalPositions[entry.item.id] = entry.frames.cell.center
            }

            for entry in previewSurface.entries where entry.item.id != sourceID {
                guard let targetPosition = originalPositions[entry.item.id] else {
                    continue
                }

                let visiblePosition =
                    entry.tileLayer.presentation()?.position
                        ?? entry.tileLayer.position

                entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                entry.tileLayer.position = targetPosition
                CATransaction.commit()

                guard visiblePosition != targetPosition else { continue }

                let rollback = CABasicAnimation(keyPath: "position")
                rollback.fromValue = NSValue(point: visiblePosition)
                rollback.toValue = NSValue(point: targetPosition)
                rollback.duration = duration
                rollback.timingFunction = completionTransition.timingFunction
                entry.tileLayer.add(rollback, forKey: "dragRollbackPosition")
            }
        }

        proxy.position =
            destination

        proxy.setAffineTransform(
            .init(
                scaleX:
                    destinationScale,
                y:
                    destinationScale
            )
        )

        proxy.opacity =
            destinationOpacity

        CATransaction.commit()

        // A rollback can have displaced preview tiles still moving even when
        // the pointer has already brought the proxy back to its origin. In that
        // case the proxy creates no implicit animation, so a CATransaction
        // completion may fire before the visible rollback finishes. Drive the
        // handoff from the declared transition duration instead.
        Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(duration)
            )
            finishPresentation()
        }
    }

}

private extension LaunchpadRootView {
    func openFolder(_ folderID: UUID, sourceFrame: CGRect? = nil) {
        guard resolvedFolder(id: folderID) != nil else { return }
        folderAnimationSourceFrame = sourceFrame ?? folderSourceFrame(for: folderID)
        openFolderID = folderID
        folderPage = 0
        folderSelectedIndex = -1
        folderPageScrollGesture = PageScrollGesture()
        window?.makeFirstResponder(self)
        searchField.isHidden = true
        setPageHitTargetsEnabled(false)
        renderFolderOverlay(animated: true)
    }

    func folderSourceFrame(for folderID: UUID) -> CGRect? {
        activeSurface?.entries.first { $0.item.folderID == folderID }?.frames.icon
    }

    func resolvedFolder(id: UUID) -> ResolvedLaunchpadFolder? {
        resolvedItems.first { $0.id == .folder(id) }.flatMap {
            guard case let .folder(folder) = $0 else { return nil }
            return folder
        }
    }

    func renderFolderOverlay(animated: Bool) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else {
            closeFolder(animated: false)
            return
        }
        folderAnimationGeneration &+= 1
        let animationGeneration = folderAnimationGeneration
        folderIconTask?.cancel()
        removeFolderButtons()
        folderOverlayLayer.removeAllAnimations()
        folderOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        folderOverlayLayer.opacity = 1
        folderOverlayLayer.isHidden = false

        let scale = window?.backingScaleFactor ?? 1
        let allMetrics = solver.solveFolder(
            display: displayContext,
            requested: layoutPreferences,
            itemCount: folder.applications.count
        )
        let pageCount = allMetrics.pageCount
        folderPage = min(folderPage, max(0, pageCount - 1))
        let startIndex = folderPage * allMetrics.itemsPerPage
        let endIndex = min(startIndex + allMetrics.itemsPerPage, folder.applications.count)
        let visibleApplications = Array(folder.applications[startIndex ..< endIndex])
        let metrics = solver.solveFolder(
            display: displayContext,
            requested: layoutPreferences,
            itemCount: visibleApplications.count
        )
        folderPanelFrame = metrics.panelFrame

        let sourceFrame = folderAnimationSourceFrame
        let sourcePoint = sourceFrame?.center ?? metrics.panelFrame.center
        let normalizedAnchor = CGPoint(
            x: bounds.width > 0 ? min(1, max(0, (sourcePoint.x - bounds.minX) / bounds.width)) : 0.5,
            y: bounds.height > 0 ? min(1, max(0, (sourcePoint.y - bounds.minY) / bounds.height)) : 0.5
        )

        let dimLayer = CALayer()
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.26).cgColor
        dimLayer.opacity = 1
        folderOverlayLayer.addSublayer(dimLayer)
        folderDimAnimationLayer = dimLayer

        // All folder visuals live in one full-screen container. Scaling this layer
        // around the source tile makes the panel, title and icons expand together,
        // matching the native Launchpad folder transition instead of merely scaling
        // the rounded rectangle in place.
        let contentLayer = CALayer()
        contentLayer.bounds = bounds
        contentLayer.anchorPoint = normalizedAnchor
        contentLayer.position = sourcePoint
        contentLayer.opacity = 1
        contentLayer.contentsScale = scale
        folderOverlayLayer.addSublayer(contentLayer)
        folderContentAnimationLayer = contentLayer

        let panelLayer = CALayer()
        panelLayer.frame = metrics.panelFrame
        panelLayer.cornerRadius = min(34, metrics.panelFrame.height * 0.09)
        panelLayer.cornerCurve = .continuous
        panelLayer.backgroundColor = NSColor.white.withAlphaComponent(0.19).cgColor
        panelLayer.borderColor = NSColor.white.withAlphaComponent(0.26).cgColor
        panelLayer.borderWidth = 1
        panelLayer.shadowColor = NSColor.black.cgColor
        panelLayer.shadowOpacity = 0.24
        panelLayer.shadowOffset = CGSize(width: 0, height: -12)
        panelLayer.shadowRadius = 34
        contentLayer.addSublayer(panelLayer)

        let titleLayer = CATextLayer()
        titleLayer.frame = metrics.titleFrame
        titleLayer.string = folder.title
        titleLayer.alignmentMode = .center
        titleLayer.fontSize = 24
        titleLayer.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        titleLayer.foregroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        titleLayer.contentsScale = scale
        contentLayer.addSublayer(titleLayer)

        for (localIndex, application) in visibleApplications.enumerated() {
            guard let frames = metrics.itemFrames(forItemAt: localIndex) else { continue }
            let presentation = AppTilePresentationFactory.make(AppTileRenderInput(
                application: application,
                cellFrame: frames.cell,
                iconFrame: frames.icon,
                labelFrame: frames.label,
                scale: scale,
                selected: startIndex + localIndex == folderSelectedIndex,
                icon: iconCache.cgImage(for: application, pointSize: metrics.iconSize, scale: scale)
            ))
            contentLayer.addSublayer(presentation.tileLayer)
            presentation.button.frame = frames.icon
            presentation.button.target = self
            presentation.button.action = #selector(applicationButtonPressed(_:))
            presentation.button.isHidden = animated
            presentation.button.onHoverChanged = { [weak iconLayer = presentation.iconLayer,
                                                      weak self] isHovering in
                self?.animateHover(on: iconLayer, isHovering: isHovering)
            }
            addSubview(presentation.button)
            folderPresentations.append(presentation)
        }

        if pageCount > 1 {
            let dots = CATextLayer()
            dots.frame = CGRect(
                x: metrics.panelFrame.minX,
                y: metrics.panelFrame.minY + 7,
                width: metrics.panelFrame.width,
                height: 18
            )
            dots.string = (0 ..< pageCount)
                .map { $0 == folderPage ? "●" : "○" }
                .joined(separator: "  ")
            dots.alignmentMode = .center
            dots.fontSize = 10
            dots.foregroundColor = NSColor.white.withAlphaComponent(0.64).cgColor
            dots.contentsScale = scale
            contentLayer.addSublayer(dots)
        }

        warmFolderIcons(visibleApplications, pointSize: metrics.iconSize, scale: scale)
        guard
            animated,
            let transition = LaunchpadVisualStyle.folderTransition(
                sourceFrame: sourceFrame,
                panelFrame: metrics.panelFrame
            )
        else {
            for presentation in folderPresentations {
                presentation.button.isHidden = false
            }
            return
        }

        let dimFade = CABasicAnimation(keyPath: "opacity")
        dimFade.fromValue = 0
        dimFade.toValue = 1
        dimFade.duration = transition.openDuration * 0.82
        dimFade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = transition.sourceScale
        scaleAnimation.toValue = 1
        scaleAnimation.duration = transition.openDuration

        let contentFade = CABasicAnimation(keyPath: "opacity")
        contentFade.fromValue = 0
        contentFade.toValue = 1
        contentFade.duration = transition.openDuration

        let contentAnimation = CAAnimationGroup()
        contentAnimation.animations = [scaleAnimation, contentFade]
        contentAnimation.duration = transition.openDuration
        contentAnimation.timingFunction = transition.openTimingFunction

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    animationGeneration == folderAnimationGeneration,
                    self.openFolderID != nil
                else { return }
                for presentation in folderPresentations {
                    presentation.button.isHidden = false
                }
            }
        }
        dimLayer.add(dimFade, forKey: "folderDimIn")
        contentLayer.add(contentAnimation, forKey: "folderExpandIn")
        CATransaction.commit()
    }

    func warmFolderIcons(
        _ applications: [ApplicationRecord],
        pointSize: CGFloat,
        scale: CGFloat
    ) {
        folderIconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await iconCache.warm(applications, pointSize: pointSize, scale: scale)
            guard !Task.isCancelled else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for presentation in folderPresentations {
                presentation.iconLayer.contents = iconCache.cgImage(
                    for: presentation.button.application,
                    pointSize: pointSize,
                    scale: scale
                )
            }
            CATransaction.commit()
        }
    }

    func changeFolderPage(by offset: Int) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext,
            requested: layoutPreferences,
            itemCount: folder.applications.count
        )
        let nextPage = min(max(folderPage + offset, 0), max(0, metrics.pageCount - 1))
        guard nextPage != folderPage else { return }
        folderPage = nextPage
        folderSelectedIndex = -1
        // Changing a page inside an already-open folder must not replay the
        // folder-opening zoom from the source tile.
        renderFolderOverlay(animated: false)
    }

    func moveFolderSelection(_ movement: GridNavigationMovement) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext,
            requested: layoutPreferences,
            itemCount: folder.applications.count
        )
        let currentSelection = folder.applications.indices.contains(folderSelectedIndex)
            ? folderSelectedIndex
            : nil
        guard let nextIndex = GridSelectionNavigator.nextIndex(
            from: currentSelection,
            movement: movement,
            currentPage: folderPage,
            itemsPerPage: metrics.itemsPerPage,
            columns: metrics.columns,
            itemCount: folder.applications.count,
            isRightToLeft: metrics.isRightToLeft
        ) else { return }

        let previousPage = folderPage
        folderSelectedIndex = nextIndex
        folderPage = nextIndex / metrics.itemsPerPage
        if folderPage != previousPage {
            renderFolderOverlay(animated: false)
        } else {
            updateFolderSelectionAppearance(itemsPerPage: metrics.itemsPerPage)
        }
    }

    func updateFolderSelectionAppearance(itemsPerPage: Int) {
        let pageStartIndex = folderPage * itemsPerPage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (localIndex, presentation) in folderPresentations.enumerated() {
            presentation.selectionLayer.opacity = pageStartIndex + localIndex == folderSelectedIndex
                ? 1
                : 0
        }
        CATransaction.commit()
    }

    func activateSelectedFolderItem() {
        guard
            let openFolderID,
            let folder = resolvedFolder(id: openFolderID),
            folder.applications.indices.contains(folderSelectedIndex)
        else { return }
        launch(folder.applications[folderSelectedIndex])
    }

    func closeFolder(animated: Bool = true) {
        guard openFolderID != nil else { return }
        folderAnimationGeneration &+= 1
        let animationGeneration = folderAnimationGeneration
        let sourceFrame = folderAnimationSourceFrame
        let panelFrame = folderPanelFrame
        let contentLayer = folderContentAnimationLayer
        let dimLayer = folderDimAnimationLayer

        openFolderID = nil
        folderPage = 0
        folderSelectedIndex = -1
        folderPanelFrame = .zero
        folderIconTask?.cancel()
        folderIconTask = nil
        removeFolderButtons()
        searchField.isHidden = false
        setPageHitTargetsEnabled(true)

        guard
            animated,
            let contentLayer,
            let dimLayer,
            let transition = LaunchpadVisualStyle.folderTransition(
                sourceFrame: sourceFrame,
                panelFrame: panelFrame
            )
        else {
            cleanupFolderOverlay()
            return
        }

        let dimFade = CABasicAnimation(keyPath: "opacity")
        dimFade.fromValue = dimLayer.presentation()?.opacity ?? dimLayer.opacity
        dimFade.toValue = 0
        dimFade.duration = transition.closeDuration
        dimFade.timingFunction = transition.closeTimingFunction

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = contentLayer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        scaleAnimation.toValue = transition.sourceScale
        scaleAnimation.duration = transition.closeDuration

        let contentFade = CABasicAnimation(keyPath: "opacity")
        contentFade.fromValue = contentLayer.presentation()?.opacity ?? contentLayer.opacity
        contentFade.toValue = 0
        contentFade.duration = transition.closeDuration

        let contentAnimation = CAAnimationGroup()
        contentAnimation.animations = [scaleAnimation, contentFade]
        contentAnimation.duration = transition.closeDuration
        contentAnimation.timingFunction = transition.closeTimingFunction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = 0
        contentLayer.opacity = 0
        contentLayer.setAffineTransform(
            CGAffineTransform(scaleX: transition.sourceScale, y: transition.sourceScale)
        )
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    animationGeneration == folderAnimationGeneration,
                    openFolderID == nil
                else { return }
                cleanupFolderOverlay()
            }
        }
        dimLayer.add(dimFade, forKey: "folderDimOut")
        contentLayer.add(contentAnimation, forKey: "folderCollapseOut")
        CATransaction.commit()
    }

    func cleanupFolderOverlay() {
        folderOverlayLayer.removeAllAnimations()
        folderOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        folderOverlayLayer.opacity = 1
        folderOverlayLayer.isHidden = true
        folderContentAnimationLayer = nil
        folderDimAnimationLayer = nil
        folderAnimationSourceFrame = nil
    }

    func removeFolderButtons() {
        for presentation in folderPresentations {
            presentation.button.removeFromSuperview()
        }
        folderPresentations.removeAll(keepingCapacity: true)
    }
}

private extension ResolvedLaunchpadItem {
    var applicationsForIconRendering: [ApplicationRecord] {
        switch self {
        case let .application(application):
            [application]
        case let .folder(folder):
            folder.applications
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

@MainActor
private final class InteractivePageSwipe {
    enum Phase {
        case tracking
        case settling
    }

    var phase: Phase = .tracking
    let outgoingSurface: LaunchpadPageSurface
    let incomingSurface: LaunchpadPageSurface
    let targetPage: Int
    let direction: Int
    let restingPosition: CGPoint
    let width: CGFloat

    var translation: CGFloat = 0
    var velocity: CGFloat = 0
    var lastTimestamp: TimeInterval
    var needsPresentationUpdate = false

    init(
        outgoingSurface: LaunchpadPageSurface,
        incomingSurface: LaunchpadPageSurface,
        targetPage: Int,
        direction: Int,
        restingPosition: CGPoint,
        width: CGFloat,
        timestamp: TimeInterval
    ) {
        self.outgoingSurface = outgoingSurface
        self.incomingSurface = incomingSurface
        self.targetPage = targetPage
        self.direction = direction
        self.restingPosition = restingPosition
        self.width = width
        lastTimestamp = timestamp
    }
}

private enum LaunchpadRuntimePaths {
    static var layoutFileURL: URL {
        guard
            let overridePath = ProcessInfo.processInfo.environment["OPENLAUNCHPAD_LAYOUT_PATH"],
            !overridePath.isEmpty
        else {
            return LauncherLayoutStore.defaultFileURL
        }
        return URL(fileURLWithPath: overridePath)
    }
}

private struct PageSurfaceConfiguration: Equatable {
    let bounds: CGRect
    let scale: CGFloat
    let contentRevision: Int
    let metrics: GridMetrics
}

@MainActor
private final class LaunchpadPageSurface {
    let pageIndex: Int
    let layer: CALayer
    var entries: [LaunchpadPageEntry] = []

    init(pageIndex: Int, layer: CALayer) {
        self.pageIndex = pageIndex
        self.layer = layer
    }
}

@MainActor
private enum LaunchpadTilePresentation {
    case application(AppTilePresentation)
    case folder(FolderTilePresentation)

    var tileLayer: CALayer {
        switch self {
        case let .application(presentation): presentation.tileLayer
        case let .folder(presentation): presentation.tileLayer
        }
    }

    var selectionLayer: CALayer {
        switch self {
        case let .application(presentation): presentation.selectionLayer
        case let .folder(presentation): presentation.selectionLayer
        }
    }

    var iconLayer: CALayer {
        switch self {
        case let .application(presentation): presentation.iconLayer
        case let .folder(presentation): presentation.iconLayer
        }
    }

    var button: PointerTrackingTileButton {
        switch self {
        case let .application(presentation): presentation.button
        case let .folder(presentation): presentation.button
        }
    }
}

@MainActor
private final class LaunchpadPageEntry {
    let item: ResolvedLaunchpadItem
    var absoluteIndex: Int
    var frames: GridItemFrames
    let presentation: LaunchpadTilePresentation

    var tileLayer: CALayer { presentation.tileLayer }
    var selectionLayer: CALayer { presentation.selectionLayer }
    var iconLayer: CALayer { presentation.iconLayer }
    var button: PointerTrackingTileButton { presentation.button }

    init(
        item: ResolvedLaunchpadItem,
        absoluteIndex: Int,
        frames: GridItemFrames,
        presentation: LaunchpadTilePresentation
    ) {
        self.item = item
        self.absoluteIndex = absoluteIndex
        self.frames = frames
        self.presentation = presentation
    }
}

@MainActor
private struct PendingTilePress {
    let entry: LaunchpadPageEntry
    let point: CGPoint
}

private struct DragPageLocation: Equatable {
    let page: Int
    let index: Int
}

@MainActor
private final class LaunchpadDragSession {
    let sourceEntry: LaunchpadPageEntry

    var draft: LauncherLayoutDraft

    let proxyLayer: CALayer
    let pointerOffset: CGVector
    let originalSurface: LaunchpadPageSurface
    let sourcePage: Int

    var lastPointerPoint: CGPoint = .zero

    var edgePagingDirection: Int?

    var hasReleased = false
    var hasCrossedPages = false
    var edgeGeneration = 0
    var edgeIncomingSurface: LaunchpadPageSurface?
    var edgeOutgoingSurface: LaunchpadPageSurface?
    var previewLocation: DragPageLocation?
    var projectedDocument: LauncherLayoutDocument?

    var edgePagingTask:
        Task<Void, Never>?

    var isEdgePageTransitionActive =
        false

    var pendingCompletionPoint:
        CGPoint?

    // Immutable geometry captured before dragging begins.
    //
    // In-place preview changes entry.frames / position,
    // therefore cancellation must restore from this snapshot.
    let originalFramesByIdentifier:
        [
            LauncherLayoutItemIdentifier:
                GridItemFrames
        ]

    let originalIndexByIdentifier:
        [
            LauncherLayoutItemIdentifier:
                Int
        ]

    // Normal same-page reorder path.
    //
    // true means:
    //
    // originalSurface itself is the preview.
    //
    // No second page CALayer tree exists.
    var usesInPlacePreview = false

    var previewSurface: LaunchpadPageSurface?
    var previewState: LauncherDragPreviewState

    var previewDestinationIdentifier: LauncherLayoutItemIdentifier {
        previewState.destination
    }

    var mergeCandidate:
        LauncherDropTarget?

    var mergeCandidateBeganAt:
        CFTimeInterval?

    var target:
        LauncherDropTarget = .outside

    init(
        sourceEntry: LaunchpadPageEntry,
        draft: LauncherLayoutDraft,
        proxyLayer: CALayer,
        pointerOffset: CGVector,
        originalSurface: LaunchpadPageSurface,
        sourcePage: Int
    ) {
        self.sourceEntry = sourceEntry
        self.draft = draft
        self.proxyLayer = proxyLayer
        self.pointerOffset = pointerOffset
        self.originalSurface =
            originalSurface

        self.sourcePage =
            sourcePage

        lastPointerPoint =
            sourceEntry
                .frames
                .cell
                .center

        originalFramesByIdentifier =
            Dictionary(
                uniqueKeysWithValues:
                    originalSurface
                        .entries
                        .map {
                            (
                                $0.item.id,
                                $0.frames
                            )
                        }
            )

        originalIndexByIdentifier =
            Dictionary(
                uniqueKeysWithValues:
                    originalSurface
                        .entries
                        .map {
                            (
                                $0.item.id,
                                $0.absoluteIndex
                            )
                        }
            )
        previewState = LauncherDragPreviewState(
            source: sourceEntry.item.id
        )
    }
}

@MainActor
private final class LaunchpadDragCommitContext {
    let session: LaunchpadDragSession

    var completionState =
        LauncherDragCommitState()

    // True only after the persisted document has been compared page-by-page
    // with the existing layer surfaces and the insertion preview was proven to
    // be an exact match.
    var didAdoptInsertionPreview = false

    init(session: LaunchpadDragSession) {
        self.session = session
    }
}
