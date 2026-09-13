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
final class LaunchpadRootView: NSView, NSTextFieldDelegate {
    private let solver = LayoutConstraintSolver()
    private let catalog = AppCatalogActor(
        excludedBundleIdentifiers: [
            "org.openlaunchpad.OpenLaunchpad",
            "org.openlaunchpad.OpenLaunchpadAgent",
        ]
    )
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
    private var folderHiddenApplicationID: ApplicationIdentity?

    // OPENLAUNCHPAD_FOLDER_INTERACTION_V1
    // Folder title editing is an AppKit control layered above the Core Animation
    // folder chrome. Folder-child dragging owns its gesture until the child
    // actually crosses the panel boundary, then hands the same mouse gesture to
    // the existing root drag/reflow state machine.
    private var folderTitleFrame = CGRect.zero
    private var folderTitleHitFrame = CGRect.zero
    private var folderTitleLayer: CATextLayer?
    private var folderTitleEditor: NSTextField?
    private var isEndingFolderTitleEditing = false
    private var isCommittingFolderTitle = false
    private var pendingFolderPress: PendingFolderTilePress?
    private var folderItemDragSession: FolderItemDragSession?

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

    /// The window transition scales the complete foreground around the display
    /// center. Counter-scaling this full-screen wallpaper keeps the desktop
    /// spatially fixed while icons and controls converge or disperse.
    var presentationBackgroundLayer: CALayer? {
        wallpaperView.layer
    }

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
            // The native title sits above the translucent panel. Treat it as an
            // interactive control before applying the "outside panel closes" rule.
            if folderTitleEditor != nil {
                finishFolderTitleEditing(commit: true)
            } else if folderTitleHitFrame.contains(point) {
                startFolderTitleEditing()
                return
            }

            if !folderPanelFrame.contains(point) {
                closeFolder()
            }
            return
        }

        if let fallbackEntry = visibleRootEntry(at: point) {
            // Normally an AppTileButton/FolderTileButton receives this event.
            // Reaching the root means a transient hit-target lifecycle gap. Never
            // interpret a geometrically valid tile click as a background dismiss.
            if case let .folder(folder) = fallbackEntry.item {
                openFolder(folder.id, sourceFrame: visibleIconFrame(for: fallbackEntry))
            }
            return
        }

        requestClose()
    }

    // OPENLAUNCHPAD_VISIBLE_ROOT_ENTRY_ACCESS_REPAIR_V1
    fileprivate func visibleRootEntry(at point: CGPoint) -> LaunchpadPageEntry? {
        guard openFolderID == nil, let activeSurface else { return nil }
        return activeSurface.entries.first { entry in
            let frame = visibleIconFrame(for: entry).insetBy(dx: -4, dy: -4)
            return frame.contains(point)
        }
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
        incomingSurface.layer.opacity = openFolderID == nil ? 1 : 0.10
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
        alert.informativeText = "This removes your custom app order and folders, then restores the default layout."
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

    func setPageHitTargetsEnabled(
        _ enabled: Bool,
        preserving preservedButton: PointerTrackingTileButton? = nil
    ) {
        guard let activeSurface else { return }
        for entry in activeSurface.entries {
            if let preservedButton, entry.button === preservedButton {
                // A live drag must keep the original NSButton attached until
                // AppKit delivers mouseUp/cancel. The button is transparent, so
                // keeping it alive does not create a second visible icon.
                entry.button.isEnabled = true
                entry.button.isHidden = false
                continue
            }
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

        // Once native-style folder creation has opened the provisional folder,
        // root-page reorder/edge logic is suspended. The drag proxy remains the
        // only moving visual and continues to follow the original pointer owner.
        if session.folderCreationPreview != nil {
            return
        }

        if allowsEdgePaging && !session.hasReleased {
            updateDragEdgePaging(at: point, session: session)
        }
        // An edge is outside the icon grid, but a page already reached by this
        // drag has a valid landing slot. Keep it valid even on the first/last page.
        if session.hasCrossedPages, let metrics = currentMetrics,
           dragEdgeDirection(at: point, metrics: metrics) != nil {
            clearDragIntent(session)
            if let location = session.previewLocation {
                setDragTarget(.pageInsertion(page: location.page, index: location.index), session: session)
            }
            return
        }
        if session.edgePagingDirection != nil {
            clearDragIntent(session)
            setDragTarget(.outside, session: session)
            return
        }

        let hits = dragHitTargets(session)
        let candidate = hits.merge ?? (hits.insertion == .outside ? nil : hits.insertion)
        let generation = session.intentState.generation
        let decision = session.intentState.update(
            candidate: candidate,
            at: CACurrentMediaTime(),
            // Spatial hysteresis now decides whether an insertion is valid.
            // Continuous pointer movement inside that valid zone must NOT keep
            // restarting the reorder timer.
            restartDwell: false
        )
        if generation != session.intentState.generation {
            session.intentTask?.cancel()
            session.intentTask = nil
            session.folderSpringOpenTask?.cancel()
            session.folderSpringOpenTask = nil
        }

        if session.hasReleased {
            // A quick drop still means insertion. Waiting for merge never
            // moves the target, but must not turn an early release into a no-op.
            let target: LauncherDropTarget
            if case let .ready(ready) = decision, !ready.isInsertion {
                target = ready
            } else {
                target = hits.insertion
            }
            applyDragPreviewTarget(target, session: session)
            return
        }

        switch decision {
        case .hold:
            // Do not materialize the insertion fallback while acquiring a
            // folder, even when this drag has not created its first preview.
            let heldTarget: LauncherDropTarget = session.previewLocation.map {
                .pageInsertion(page: $0.page, index: $0.index)
            } ?? .outside
            setDragTarget(candidate == nil ? .outside : heldTarget, session: session)
            scheduleDragIntent(session)
        case let .ready(target):
            session.intentTask?.cancel()
            session.intentTask = nil
            switch target {
            case .application, .folder:
                // Short dwell means “folder drop is ready”, not “open the folder”.
                // Keep the target locked/highlighted. A mouseUp now commits a
                // closed folder; only a continuous one-second hold spring-opens it.
                setDragTarget(target, session: session)
                scheduleFolderSpringOpen(target, session: session)
                return
            case .insertion, .pageInsertion, .outside:
                session.folderSpringOpenTask?.cancel()
                session.folderSpringOpenTask = nil
            }
            applyDragPreviewTarget(target, session: session)
        }
    }

    // OPENLAUNCHPAD_NATIVE_FOLDER_CREATION_V2
    @discardableResult
    func beginFolderCreationPreview(
        _ target: LauncherDropTarget,
        session: LaunchpadDragSession
    ) -> Bool {
        guard
            session.folderCreationPreview == nil,
            case let .application(sourceIdentity) = session.sourceEntry.item.id
        else { return false }

        let surface = session.previewSurface ?? activeSurface
        let targetFrame: CGRect? = {
            guard let surface else { return nil }
            return surface.entries.first { entry in
                switch target {
                case let .application(identity):
                    return entry.item.id == .application(identity)
                case let .folder(folderID):
                    return entry.item.id == .folder(folderID)
                case .insertion, .pageInsertion, .outside:
                    return false
                }
            }.map { visibleIconFrame(for: $0) }
        }()

        let folderID: UUID
        do {
            switch target {
            case let .application(targetIdentity):
                folderID = UUID()
                try session.draft.mergeApplications(
                    source: sourceIdentity,
                    target: targetIdentity,
                    folderID: folderID,
                    customTitle: "Untitled"
                )
            case let .folder(existingFolderID):
                folderID = existingFolderID
                try session.draft.addApplication(sourceIdentity, toFolder: existingFolderID)
            case .insertion, .pageInsertion, .outside:
                return false
            }
        } catch {
            return false
        }

        session.intentTask?.cancel()
        session.intentTask = nil
        session.folderSpringOpenTask?.cancel()
        session.folderSpringOpenTask = nil
        setDragTarget(target, session: session)
        session.folderCreationPreview = FolderCreationPreview(
            folderID: folderID,
            target: target,
            sourceIdentity: sourceIdentity
        )
        folderHiddenApplicationID = sourceIdentity

        folderAnimationSourceFrame = targetFrame
        openFolderID = folderID
        folderPage = 0
        folderSelectedIndex = -1
        folderPageScrollGesture = PageScrollGesture()
        searchField.isHidden = true
        setPageHitTargetsEnabled(false, preserving: session.sourceEntry.button)
        setFolderBackgroundVisible(true, animated: true)
        renderFolderOverlay(animated: true)
        return true
    }

    func applyDragPreviewTarget(_ target: LauncherDropTarget, session: LaunchpadDragSession) {
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

    func clearDragIntent(_ session: LaunchpadDragSession) {
        session.intentTask?.cancel()
        session.intentTask = nil
        session.folderSpringOpenTask?.cancel()
        session.folderSpringOpenTask = nil
        session.intentState.reset()
    }

    func scheduleDragIntent(_ session: LaunchpadDragSession) {
        guard session.intentTask == nil, let deadline = session.intentState.deadline,
              !session.hasReleased else { return }
        let generation = session.intentState.generation
        session.intentTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .seconds(max(0, deadline - CACurrentMediaTime())))
            guard
                !Task.isCancelled,
                let self,
                let session,
                self.dragSession === session,
                !session.hasReleased,
                !session.isEdgePageTransitionActive,
                session.intentState.generation == generation
            else {
                return
            }

            session.intentTask = nil
            // Re-sample visible target geometry: an in-flight reflow may have
            // moved it since the last pointer event. Time alone cannot arm it.
            self.updateDragInteraction(at: session.lastPointerPoint)
        }
    }

    func scheduleFolderSpringOpen(
        _ target: LauncherDropTarget,
        session: LaunchpadDragSession
    ) {
        guard
            session.folderCreationPreview == nil,
            session.folderSpringOpenTask == nil,
            !session.hasReleased,
            !session.isEdgePageTransitionActive,
            session.intentState.isReady,
            session.intentState.candidate == target,
            let beganAt = session.intentState.beganAt,
            !target.isInsertion,
            target != .outside
        else { return }

        let generation = session.intentState.generation
        let deadline = beganAt + FolderSpringOpenMetrics.dwell
        session.folderSpringOpenTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .seconds(max(0, deadline - CACurrentMediaTime())))
            guard
                !Task.isCancelled,
                let self,
                let session,
                self.dragSession === session,
                !session.hasReleased,
                !session.isEdgePageTransitionActive,
                session.folderCreationPreview == nil,
                session.intentState.generation == generation,
                session.intentState.isReady,
                session.intentState.candidate == target,
                self.dragHitTargets(session).merge == target
            else { return }

            session.folderSpringOpenTask = nil
            _ = self.beginFolderCreationPreview(target, session: session)
        }
    }

    private enum DragEdgeMetrics {
        static let minimumWidth: CGFloat = 56
        static let maximumWidth: CGFloat = 96
        static let widthFraction: CGFloat = 0.04
        static let dwell: Duration = .milliseconds(400)
        static let pageDuration: CFTimeInterval = 0.45
    }

    private enum FolderSpringOpenMetrics {
        // Total stable overlap before spring-loading the folder. The shorter
        // LauncherDragIntentState merge dwell only arms a closed-folder drop.
        // OPENLAUNCHPAD_FOLDER_SPRING_OPEN_DWELL_100_V2
        static let dwell: TimeInterval = 1.0
    }

    private enum DragProxyMetrics {
        static let labelLayerName = "OpenLaunchpadDragProxyLabel"
        static let labelAnimationKey = "folderMergeSourceLabelFade"
    }

    private enum FolderMergeVisualMetrics {
        // The merge-ready surface should feel like a closed folder preview:
        // smaller than the old selection ring, but much more legible.
        static let appTargetFrameScale: CGFloat = 0.82
        // Existing folders grow more assertively when an app is held over them.
        // The requested merge-ready state is 30% larger than the normal folder tile.
        static let folderTargetScale: CGFloat = 1.30
        static let transitionDuration: CFTimeInterval = 0.14
        // Names intentionally trail the geometry so the merge intent reads first.
        static let labelFadeDuration: CFTimeInterval = 0.30
        // Merge landing stays fully visible while it travels toward the folder,
        // then disappears only after it has visibly shrunk into the target.
        // Keep the source visible until it is close to the miniature size;
        // the final scale itself comes from AppTilePresentationFactory so it
        // always matches the closed-folder 3x3 geometry exactly.
        static let mergeFadeStartProgress: Double = 0.90
        // When all nine miniature slots are already occupied, the incoming
        // app is absorbed by the folder itself rather than by a visible slot.
        // Shrink almost to a point and defer fading until the final instant.
        static let fullFolderAbsorbScale: CGFloat = 0.03
        static let fullFolderFadeStartProgress: Double = 0.97
        // Keep the page completely still until the source app has finished
        // shrinking into the folder. One extra display frame makes the visual
        // ownership handoff unambiguous before the surrounding grid reflows.
        static let postLandingReflowDelay: CFTimeInterval = 0.02
        static let folderBackgroundOpacity: CGFloat = 0.42
        static let folderBorderOpacity: CGFloat = 0.52
        static let folderBorderWidth: CGFloat = 0.75
        static let normalSelectionBackgroundOpacity: CGFloat = 0.12
        static let normalSelectionBorderOpacity: CGFloat = 0.18
        static let normalSelectionBorderWidth: CGFloat = 0.7
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
        let existingCount = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage).pages.count
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
        guard var draft = try? LauncherLayoutDraft(document: session.projectionBaselineDocument) else { return nil }
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
        let baseline = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage)
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
        clearDragIntent(session)
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

            // One wall-clock start for the complete reflow batch. Every displaced
            // tile converts this exact media time into its own layer time.
            let reflowBatchMediaTime = CACurrentMediaTime()

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

                move.beginTime =
                    entry.tileLayer.convertTime(
                        reflowBatchMediaTime,
                        from: nil
                    )

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

        let fallbackReflowBatchMediaTime = CACurrentMediaTime()

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

                fade.beginTime =
                    entry.tileLayer.convertTime(
                        fallbackReflowBatchMediaTime,
                        from: nil
                    )

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

            move.beginTime =
                entry.tileLayer.convertTime(
                    fallbackReflowBatchMediaTime,
                    from: nil
                )

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



    func visibleIconFrame(for entry: LaunchpadPageEntry) -> CGRect {
        let visibleCenter = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position
        return entry.frames.icon.offsetBy(
            dx: visibleCenter.x - entry.frames.cell.midX,
            dy: visibleCenter.y - entry.frames.cell.midY
        )
    }

    func draggedIconFrame(for session: LaunchpadDragSession) -> CGRect {
        let frames = session.originalFramesByIdentifier[session.sourceEntry.item.id]
            ?? session.sourceEntry.frames
        // The dragged end follows this event, not last frame's presentation.
        // Immutable grab geometry also survives in-place reflow and page turns.
        let center = CGPoint(
            x: session.lastPointerPoint.x - session.pointerOffset.dx,
            y: session.lastPointerPoint.y - session.pointerOffset.dy
        )
        return frames.icon.offsetBy(dx: center.x - frames.cell.midX,
                                    dy: center.y - frames.cell.midY)
    }
    // OPENLAUNCHPAD_NATIVE_REORDER_FAST_SYNC_V4
    //
    // Fixed-cell, direction-aware reorder hysteresis.
    //
    // The center of a neighboring cell remains a stable/dead region. Reorder
    // activates only after the dragged icon center has moved 60% through the
    // cell in the direction of travel (40% when travelling left).
    //
    // Unlike V3, this function does NOT force one-slot-at-a-time progression.
    // If a coarse/fast pointer update legitimately lands several cells away,
    // return the furthest spatially-valid slot in one decision. That lets every
    // displaced app reflow in one animation batch instead of stair-stepping.
    //
    // The gate is always derived from GridMetrics model cells. Presentation
    // animation never moves the hit-test boundary.
    func stabilizedReorderVisibleSlot(
        rawSlot: Int,
        draggedFrame: CGRect,
        session: LaunchpadDragSession,
        metrics: GridMetrics
    ) -> Int {
        let surface = session.previewSurface ?? session.originalSurface
        let activeDragPage = session.previewLocation?.page ?? session.sourcePage

        guard
            activeDragPage == currentPage,
            let layoutSource = surface.entries.first(where: {
                $0.item.id == session.sourceEntry.item.id
            }),
            let currentSlot = (0 ..< metrics.itemsPerPage).first(where: {
                metrics.cellFrame(forItemAt: $0)?.contains(layoutSource.frames.cell.center) == true
            }),
            rawSlot != currentSlot
        else {
            return rawSlot
        }

        // Keep existing vertical-row semantics. V4 only changes horizontal
        // reorder behavior.
        guard rawSlot / metrics.columns == currentSlot / metrics.columns,
              let rawCell = metrics.cellFrame(forItemAt: rawSlot)
        else {
            return rawSlot
        }

        let activationFraction: CGFloat = 0.60

        if rawSlot > currentSlot {
            let activationX = rawCell.minX + rawCell.width * activationFraction

            if draggedFrame.midX >= activationX {
                return rawSlot
            }

            // The pointer may have jumped over several complete cells in one
            // event. Every fully-crossed slot is already spatially valid, so
            // resolve to the slot immediately before the current raw cell.
            return max(currentSlot, rawSlot - 1)
        }

        let activationX = rawCell.maxX - rawCell.width * activationFraction

        if draggedFrame.midX <= activationX {
            return rawSlot
        }

        return min(currentSlot, rawSlot + 1)
    }

    func dragHitTargets(
        _ session: LaunchpadDragSession
    ) -> (insertion: LauncherDropTarget, merge: LauncherDropTarget?) {
        guard let metrics = currentMetrics else { return (.outside, nil) }
        let source = session.sourceEntry
        let draggedFrame = draggedIconFrame(for: session)
        let point = draggedFrame.center
        let baseline = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage)
        let pageItems = baseline.pages.indices.contains(currentPage) ? baseline.pages[currentPage] : []
        let pageIDs = pageItems.map { item -> LauncherLayoutItemIdentifier in
            switch item {
            case let .application(reference): return .application(reference.identity)
            case let .folder(folder): return .folder(folder.id)
            }
        }
        let countWithoutSource = pageIDs.filter { $0 != source.item.id }.count
        let insertion: LauncherDropTarget = {
            guard metrics.contentFrame.contains(point),
                  let rawSlot = (0..<metrics.itemsPerPage).first(where: {
                      metrics.cellFrame(forItemAt: $0)?.contains(point) == true
                  }) else { return .outside }
            let slot = stabilizedReorderVisibleSlot(
                rawSlot: rawSlot, draggedFrame: draggedFrame, session: session, metrics: metrics
            )
            let projection = pageProjection(metrics: metrics, document: baseline)
            let visibleIDs = projection.pages.indices.contains(currentPage)
                ? projection.pages[currentPage].map(\.id) : []
            guard let index = ResolvedLaunchpadInsertionIndex.resolve(
                visibleSlot: min(slot, countWithoutSource), pageIdentifiers: pageIDs,
                visibleIdentifiers: visibleIDs, sourceIdentifier: source.item.id
            ) else { return .outside }
            return .pageInsertion(page: currentPage, index: index)
        }()

        guard case .application = source.item,
              let surface = session.previewSurface ?? activeSurface else {
            return (insertion, nil)
        }
        let retaining: LauncherLayoutItemIdentifier?
        switch session.intentState.candidate {
        case let .application(identity): retaining = .application(identity)
        case let .folder(folderID): retaining = .folder(folderID)
        default: retaining = nil
        }
        let targets = surface.entries.filter {
            $0.item.id != source.item.id && $0.tileLayer.superlayer != nil
        }.map {
            FolderMergeGeometry.Target(id: $0.item.id, iconFrame: visibleIconFrame(for: $0))
        }
        // Only visible icons participate. Old snapshot slots remain exclusively
        // rollback data, never invisible merge anchors after an exchange.
        let selected = FolderMergeGeometry.target(
            draggedIcon: draggedFrame, targets: targets, retaining: retaining
        )
        let merge: LauncherDropTarget?
        switch selected {
        case let .application(identity): merge = .application(identity)
        case let .folder(folderID): merge = .folder(folderID)
        case nil: merge = nil
        }
        return (insertion, merge)
    }

    func updateDropHighlight(
        _ target: LauncherDropTarget
    ) {
        let surface = dragSession?.previewSurface ?? activeSurface
        guard let surface else { return }

        let mergeTarget: LauncherLayoutItemIdentifier?
        switch target {
        case let .application(identity):
            mergeTarget = .application(identity)
        case let .folder(folderID):
            mergeTarget = .folder(folderID)
        case .insertion, .pageInsertion, .outside:
            mergeTarget = nil
        }

        if let session = dragSession {
            let keepHiddenForMergeLanding: Bool
            if session.hasReleased {
                switch session.target {
                case .application, .folder:
                    keepHiddenForMergeLanding = true
                case .insertion, .pageInsertion, .outside:
                    keepHiddenForMergeLanding = false
                }
            } else {
                keepHiddenForMergeLanding = false
            }
            updateDragProxyMergeLabel(
                session,
                hidden: mergeTarget != nil || keepHiddenForMergeLanding
            )
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(FolderMergeVisualMetrics.transitionDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        for entry in surface.entries {
            let isMergeTarget = entry.item.id == mergeTarget
            let isApplicationTarget: Bool
            let isFolderTarget: Bool
            switch entry.item {
            case .application:
                isApplicationTarget = isMergeTarget
                isFolderTarget = false
            case .folder:
                isApplicationTarget = false
                isFolderTarget = isMergeTarget
            }

            // Restore the normal selection style before applying merge-ready visuals.
            entry.selectionLayer.backgroundColor = NSColor.white
                .withAlphaComponent(FolderMergeVisualMetrics.normalSelectionBackgroundOpacity)
                .cgColor
            entry.selectionLayer.borderColor = NSColor.white
                .withAlphaComponent(FolderMergeVisualMetrics.normalSelectionBorderOpacity)
                .cgColor
            entry.selectionLayer.borderWidth = FolderMergeVisualMetrics.normalSelectionBorderWidth
            entry.selectionLayer.setAffineTransform(.identity)

            if isApplicationTarget {
                // App -> App: keep both app icons visible. Add a compact,
                // folder-colored rounded surface behind the target and only fade
                // the two names. This reads as "these apps will group" instead of
                // prematurely replacing the target with a folder.
                entry.selectionLayer.backgroundColor = NSColor.white
                    .withAlphaComponent(FolderMergeVisualMetrics.folderBackgroundOpacity)
                    .cgColor
                entry.selectionLayer.borderColor = NSColor.white
                    .withAlphaComponent(FolderMergeVisualMetrics.folderBorderOpacity)
                    .cgColor
                entry.selectionLayer.borderWidth = FolderMergeVisualMetrics.folderBorderWidth
                entry.selectionLayer.setAffineTransform(.init(
                    scaleX: FolderMergeVisualMetrics.appTargetFrameScale,
                    y: FolderMergeVisualMetrics.appTargetFrameScale
                ))
                entry.selectionLayer.opacity = 1
                entry.iconLayer.opacity = 1
                entry.iconLayer.setAffineTransform(.identity)
                setMergeLabelOpacity(entry.labelLayer, to: 0)
            } else if isFolderTarget {
                // App -> Folder: the folder itself becomes the merge-ready surface.
                // Enlarge it to the same footprint as the App -> App preview and
                // fade both labels, without drawing a second frame around it.
                entry.selectionLayer.opacity = 0
                entry.iconLayer.opacity = 1
                entry.iconLayer.setAffineTransform(.init(
                    scaleX: FolderMergeVisualMetrics.folderTargetScale,
                    y: FolderMergeVisualMetrics.folderTargetScale
                ))
                setMergeLabelOpacity(entry.labelLayer, to: 0)
            } else {
                entry.selectionLayer.opacity =
                    entry.absoluteIndex == selectedIndex ? 1 : 0
                entry.iconLayer.opacity = 1
                entry.iconLayer.setAffineTransform(.identity)
                setMergeLabelOpacity(entry.labelLayer, to: 1)
            }
        }

        CATransaction.commit()
    }

    func setMergeLabelOpacity(
        _ labelLayer: CALayer,
        to targetOpacity: Float
    ) {
        guard labelLayer.opacity != targetOpacity else { return }

        let visibleOpacity = labelLayer.presentation()?.opacity ?? labelLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.opacity = targetOpacity
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = visibleOpacity
        animation.toValue = targetOpacity
        animation.duration = FolderMergeVisualMetrics.labelFadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        labelLayer.add(animation, forKey: "folderMergeLabelOpacity")
    }

    func updateDragProxyMergeLabel(
        _ session: LaunchpadDragSession,
        hidden: Bool
    ) {
        guard session.isSourceLabelHiddenForMerge != hidden else { return }
        session.isSourceLabelHiddenForMerge = hidden

        // Never cross-fade the moving proxy's `contents`. CATransition keeps a
        // cached copy of the old backing store while the proxy position is being
        // updated every pointer event; that cached copy stays at the transition
        // origin and produces the visible ghost left behind when the drag exits
        // a merge target. Keep the label as its own child layer instead so both
        // icon and label always share the proxy's live position.
        guard let labelLayer = dragProxyLabelLayer(session.proxyLayer) else { return }
        let targetOpacity: Float = hidden ? 0 : 1
        let visibleOpacity = labelLayer.presentation()?.opacity ?? labelLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.opacity = targetOpacity
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = visibleOpacity
        fade.toValue = targetOpacity
        fade.duration = FolderMergeVisualMetrics.labelFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        labelLayer.add(fade, forKey: DragProxyMetrics.labelAnimationKey)
    }

    func prepareFolderMergeReflowPreviewIfNeeded(
        _ session: LaunchpadDragSession
    ) {
        guard
            session.folderCreationPreview == nil,
            let metrics = currentMetrics,
            !session.hasCrossedPages || session.previewSurface != nil
        else { return }

        switch session.target {
        case .application, .folder:
            break
        case .insertion, .pageInsertion, .outside:
            return
        }

        let projection = pageProjection(
            metrics: metrics,
            document: session.draft.document
        )
        guard projection.pages.indices.contains(currentPage) else { return }

        let items = projection.items
        let scale = window?.backingScaleFactor ?? 1
        let oldSurface = session.previewSurface ?? session.originalSurface
        guard oldSurface.pageIndex == currentPage else { return }

        // Freeze the merge destination before the final layout starts moving.
        // The source app must finish shrinking into the folder at the folder's
        // current visible position; only after that handoff may the page compact.
        let landingTargetID: LauncherLayoutItemIdentifier?
        switch session.target {
        case let .application(identity):
            landingTargetID = .application(identity)
        case let .folder(folderID):
            landingTargetID = .folder(folderID)
        case .insertion, .pageInsertion, .outside:
            landingTargetID = nil
        }
        if let landingTargetID,
           let landingEntry = oldSurface.entries.first(where: {
               $0.item.id == landingTargetID
           })
        {
            session.mergeLandingTargetIconFrame = visibleIconFrame(for: landingEntry)
        } else {
            session.mergeLandingTargetIconFrame = nil
        }

        let newSurface = makePageSurface(
            pageIndex: currentPage,
            items: items,
            metrics: metrics,
            scale: scale,
            projection: projection
        )

        var oldPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]
        for entry in oldSurface.entries {
            oldPositions[entry.item.id] =
                entry.tileLayer.presentation()?.position
                    ?? entry.tileLayer.position
        }

        let applicationTargetPosition: CGPoint? = {
            guard case let .application(identity) = session.target else { return nil }
            return oldPositions[.application(identity)]
        }()

        // OPENLAUNCHPAD_CROSS_PAGE_ENTERING_HANDOFF_V3
        // oldSurface is the live pre-merge projection after edge paging. Remember
        // which page owned each item so a tile pulled in from an adjacent page
        // can receive a real visual handoff instead of appearing directly on top
        // of the tile that is still occupying the final slot.
        let preMergePageByIdentifier: [LauncherLayoutItemIdentifier: Int] = {
            guard session.hasCrossedPages else { return [:] }

            let preMergeDocument =
                session.projectedDocument
                    ?? session.projectionBaselineDocument
            let preMergeProjection = pageProjection(
                metrics: metrics,
                document: preMergeDocument
            )

            var result: [LauncherLayoutItemIdentifier: Int] = [:]
            for (pageIndex, page) in preMergeProjection.pages.enumerated() {
                for item in page {
                    result[item.id] = pageIndex
                }
            }
            return result
        }()

        let transition = LaunchpadVisualStyle.dragReflowTransition(movedForward: false)
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let mergeLandingDuration = LaunchpadVisualStyle.dragCompletionTransition(
            kind: .merge
        ).duration
        let reflowStartTime = CACurrentMediaTime()
            + mergeLandingDuration
            + FolderMergeVisualMetrics.postLandingReflowDelay

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        newSurface.layer.frame = bounds
        newSurface.layer.contentsScale = scale
        newSurface.layer.opacity = 1
        newSurface.layer.isHidden = false

        for entry in newSurface.entries {
            let targetPosition = entry.tileLayer.position
            var startPosition = oldPositions[entry.item.id]

            // App -> App replaces the target application identifier with a new
            // folder identifier. Start that new folder exactly where the target
            // app is visibly sitting so the replacement does not flash in from a
            // different slot while the rest of the page compacts.
            if startPosition == nil,
               let applicationTargetPosition,
               case let .folder(folder) = entry.item,
               case let .application(targetIdentity) = session.target,
               folder.applications.contains(where: { $0.id == targetIdentity })
            {
                startPosition = applicationTargetPosition
            }

            // A genuine page-entering item has no old position on this surface.
            // Before this fix it therefore appeared immediately at targetPosition while
            // the previous last tile was held at that exact slot until reflowStartTime.
            // Stage it in the adjacent-page direction and keep it invisible until the
            // outgoing tile has visibly vacated the slot.
            if startPosition == nil,
               let previousPage = preMergePageByIdentifier[entry.item.id],
               previousPage != currentPage
            {
                let logicalDirection: CGFloat =
                    previousPage > currentPage ? 1 : -1
                let visualDirection =
                    metrics.isRightToLeft
                        ? -logicalDirection
                        : logicalDirection
                let enteringOffset =
                    abs(transition.enteringItemOffset) * visualDirection

                startPosition = CGPoint(
                    x: targetPosition.x + enteringOffset,
                    y: targetPosition.y
                )

                if shouldAnimate {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = transition.enteringItemFadeDuration
                    // Position starts moving with the grid. Opacity deliberately waits
                    // for about the first third of the current reflow so two icons never
                    // read as owners of the same bottom-right slot.
                    fade.beginTime = reflowStartTime
                        + min(transition.duration * 0.33, 0.16)
                    fade.timingFunction = transition.timingFunction
                    fade.fillMode = .backwards
                    entry.tileLayer.add(
                        fade,
                        forKey: "dragReflowOpacity"
                    )
                }
            }

            guard shouldAnimate,
                  let startPosition,
                  startPosition != targetPosition
            else { continue }

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: startPosition)
            move.toValue = NSValue(point: targetPosition)
            move.duration = transition.duration
            move.timingFunction = transition.timingFunction
            move.beginTime = reflowStartTime
            move.fillMode = .backwards
            entry.tileLayer.add(move, forKey: "dragReflowPosition")
        }

        // App -> existing Folder leaves the same folder identifier in the final
        // document. Continue the merge-ready +30% presentation back to 1.0 on
        // the new surface instead of snapping smaller at mouse-up.
        if case let .folder(folderID) = session.target,
           let folderEntry = newSurface.entries.first(where: {
               $0.item.id == .folder(folderID)
           }), shouldAnimate
        {
            let scaleDown = CABasicAnimation(keyPath: "transform")
            scaleDown.fromValue = CATransform3DMakeAffineTransform(
                .init(
                    scaleX: FolderMergeVisualMetrics.folderTargetScale,
                    y: FolderMergeVisualMetrics.folderTargetScale
                )
            )
            scaleDown.toValue = CATransform3DIdentity
            scaleDown.duration = FolderMergeVisualMetrics.transitionDuration
            scaleDown.timingFunction = CAMediaTimingFunction(name: .easeOut)
            folderEntry.iconLayer.add(scaleDown, forKey: "folderMergeCommitScale")
        }

        // Swap render ownership atomically. Every surviving tile in the new
        // surface starts at its current presentation position, then translates
        // into the compacted slot using the same reflow animation as App swaps.
        oldSurface.layer.removeAllAnimations()
        oldSurface.layer.opacity = 0
        oldSurface.layer.isHidden = true
        oldSurface.layer.removeFromSuperlayer()

        rootLayer.insertSublayer(newSurface.layer, below: fixedOverlayLayer)

        CATransaction.commit()

        session.previewSurface = newSurface
        session.usesInPlacePreview = false
        activeSurface = newSurface
        pageContentLayer = newSurface.layer
    }

    func mergedFolderEntry(
        in surface: LaunchpadPageSurface?,
        for target: LauncherDropTarget
    ) -> LaunchpadPageEntry? {
        guard let surface else { return nil }
        switch target {
        case let .folder(folderID):
            return surface.entries.first { $0.item.id == .folder(folderID) }
        case let .application(targetIdentity):
            return surface.entries.first { entry in
                guard case let .folder(folder) = entry.item else { return false }
                return folder.applications.contains { $0.id == targetIdentity }
            }
        case .insertion, .pageInsertion, .outside:
            return nil
        }
    }

    func mergeLandingScale(
        session: LaunchpadDragSession
    ) -> CGFloat {
        guard
            case let .application(sourceIdentity) = session.sourceEntry.item.id
        else {
            return AppTilePresentationFactory.folderMiniatureIconScale
        }

        let finalFolder: LauncherFolder?

        switch session.target {
        case let .folder(folderID):
            finalFolder = session.draft.document.items.compactMap {
                (item: LauncherLayoutItem) -> LauncherFolder? in
                guard case let .folder(folder) = item, folder.id == folderID else {
                    return nil
                }
                return folder
            }.first

        case let .application(targetIdentity):
            finalFolder = session.draft.document.items.compactMap {
                (item: LauncherLayoutItem) -> LauncherFolder? in
                guard case let .folder(folder) = item else { return nil }
                let identities = folder.applications.map(\.identity)
                guard
                    identities.contains(sourceIdentity),
                    identities.contains(targetIdentity)
                else {
                    return nil
                }
                return folder
            }.first

        case .insertion, .pageInsertion, .outside:
            finalFolder = nil
        }

        guard
            let finalFolder,
            finalFolder.applications.count
                > AppTilePresentationFactory.folderMaximumVisibleChildren
        else {
            return AppTilePresentationFactory.folderMiniatureIconScale
        }

        return FolderMergeVisualMetrics.fullFolderAbsorbScale
    }

    func mergeLandingDestination(
        in surface: LaunchpadPageSurface?,
        session: LaunchpadDragSession
    ) -> CGPoint? {
        guard
            let surface,
            case let .application(sourceIdentity) = session.sourceEntry.item.id
        else { return nil }

        let visualEntry: LaunchpadPageEntry?
        let finalFolder: LauncherFolder?

        switch session.target {
        case let .folder(folderID):
            visualEntry = surface.entries.first { $0.item.id == .folder(folderID) }
            finalFolder = session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                guard case let .folder(folder) = item, folder.id == folderID else { return nil }
                return folder
            }.first

        case let .application(targetIdentity):
            // A same-page committed preview already contains the new folder.
            // Cross-page / conservative paths may still be rendering the target
            // application, so accept either visual owner for the same location.
            visualEntry = mergedFolderEntry(in: surface, for: session.target)
                ?? surface.entries.first { $0.item.id == .application(targetIdentity) }
            finalFolder = session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                guard case let .folder(folder) = item else { return nil }
                let ids = folder.applications.map(\.identity)
                guard ids.contains(sourceIdentity), ids.contains(targetIdentity) else { return nil }
                return folder
            }.first

        case .insertion, .pageInsertion, .outside:
            return nil
        }

        guard let visualEntry else { return nil }

        let landingScale = mergeLandingScale(session: session)
        let landingIconFrame = session.mergeLandingTargetIconFrame
            ?? visibleIconFrame(for: visualEntry)
        let targetCenter: CGPoint

        if
            let finalFolder,
            let sourceIndex = finalFolder.applications.firstIndex(where: { $0.identity == sourceIdentity }),
            let childCenter = AppTilePresentationFactory.folderChildCenter(
                iconFrame: landingIconFrame,
                logicalIndex: sourceIndex,
                layoutDirection: userInterfaceLayoutDirection
            )
        {
            targetCenter = childCenter
        } else {
            // Closed folders expose only nine miniature slots. Once all nine
            // are occupied, land at the *folder icon* center, not the cell
            // center (which is lower because the cell also contains the label).
            targetCenter = landingIconFrame.center
        }

        // The drag proxy is cell-sized, while the visible app icon sits above
        // the cell center. Compensate that offset after scaling so the visible
        // icon itself — not the proxy's transparent cell — lands exactly on
        // the miniature-slot / folder center.
        let sourceIconOffset = CGPoint(
            x: session.sourceEntry.frames.icon.midX - session.sourceEntry.frames.cell.midX,
            y: session.sourceEntry.frames.icon.midY - session.sourceEntry.frames.cell.midY
        )

        return CGPoint(
            x: targetCenter.x - sourceIconOffset.x * landingScale,
            y: targetCenter.y - sourceIconOffset.y * landingScale
        )
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
        dragSession.intentTask?.cancel()
        dragSession.intentTask = nil
        dragSession.folderSpringOpenTask?.cancel()
        dragSession.folderSpringOpenTask = nil

        if dragSession.folderCreationPreview != nil {
            // OPENLAUNCHPAD_SPRING_OPEN_COMMIT_LOCK_V1
            // Spring-open is the irreversible mouse-up intent boundary.
            //
            // beginFolderCreationPreview() has already mutated the draft by
            // inserting/merging the source App into this Folder, and
            // updateDragInteraction() deliberately suspends root reorder/edge
            // logic while folderCreationPreview exists. Re-checking the current
            // pointer against folderPanelFrame here created a contradictory
            // second decision: an already-open Folder could be rolled back merely
            // because the user moved the pointer outside its panel before release.
            //
            // Once the Folder has opened, mouse-up always commits that Folder
            // draft. Explicit cancellation still goes through cancelDragInteraction()
            // and remains able to rollback the provisional mutation.
        } else {
            // If mouse-up arrives while an edge page is still sliding, preserve the
            // release point and complete the drop when that page becomes active.
            if dragSession.isEdgePageTransitionActive {
                dragSession.pendingCompletionPoint = point
                return
            }

            updateDragInteraction(at: point, allowsEdgePaging: false)

            do {
                try applyDropTarget(dragSession.target, to: dragSession)
                prepareFolderMergeReflowPreviewIfNeeded(dragSession)
            } catch {
                cancelDragInteraction()
                return
            }
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

                    if let previewSurface = committingSession.previewSurface {
                        refreshCommittedPageCacheForCrossPageMergeIfNeeded(
                            committingSession,
                            keeping: previewSurface,
                            metrics: metrics
                        )
                    }
                }
                if adoptCommittedPreviewIfPossible(
                    committingSession
                ) {
                    commitContext.didAdoptCommittedPreview = true
                } else {
                    invalidatePageSurfaceCache()
                }

                commitContext
                    .completionState
                    .markPersistenceFinished()
            } catch {
                _ = dragStateMachine.beginRollback()
                if committingSession.folderCreationPreview != nil {
                    closeFolder(animated: false)
                }
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

    func refreshCommittedPageCacheForCrossPageMergeIfNeeded(
        _ session: LaunchpadDragSession,
        keeping previewSurface: LaunchpadPageSurface,
        metrics: GridMetrics
    ) {
        guard session.hasCrossedPages else { return }

        switch session.target {
        case .application, .folder:
            break
        case .insertion, .pageInsertion, .outside:
            return
        }

        let items = resolvedItems
        let projection = pageProjection(metrics: metrics)
        let scale = window?.backingScaleFactor ?? 1
        let pageCount = projection.pageCount

        // The target page already owns the live, animated committed preview.
        // Cross-page merge only leaves the off-screen page cache stale (most
        // importantly the source page, which still contains the dragged root
        // item). Rebuild those hidden surfaces immediately from the committed
        // document while preserving the target page's presentation tree.
        for (pageIndex, surface) in pageSurfaces {
            guard pageIndex != currentPage || surface !== previewSurface else {
                continue
            }
            detachButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.opacity = 0
            surface.layer.isHidden = true
            surface.layer.removeFromSuperlayer()
        }

        var refreshedSurfaces: [Int: LaunchpadPageSurface] = [:]
        refreshedSurfaces.reserveCapacity(pageCount)

        for pageIndex in 0 ..< pageCount {
            if pageIndex == currentPage {
                refreshedSurfaces[pageIndex] = previewSurface
            } else {
                refreshedSurfaces[pageIndex] = makePageSurface(
                    pageIndex: pageIndex,
                    items: items,
                    metrics: metrics,
                    scale: scale,
                    projection: projection
                )
            }
        }

        pageSurfaces = refreshedSurfaces
        activeSurface = previewSurface
        pageContentLayer = previewSurface.layer

        updatePageIndicator(
            pageCount: pageCount,
            metrics: metrics,
            scale: scale
        )
    }

    func adoptCommittedPreviewIfPossible(
        _ session: LaunchpadDragSession
    ) -> Bool {
        let canAdoptTarget: Bool
        switch session.target {
        case .insertion, .pageInsertion, .application, .folder:
            canAdoptTarget = true
        case .outside:
            canAdoptTarget = false
        }

        guard
            canAdoptTarget,
            let previewSurface = session.previewSurface,
            let metrics = currentMetrics
        else {
            return false
        }

        // Only preserve the preview when it is an exact projection of the
        // document returned by the store.
        //
        // Cross-page folder merges refresh their off-screen page cache from the
        // committed document first, so the live target-page preview can be
        // adopted without rebuilding it. Partial-catalog and any future
        // mismatches still fall back to the safe full-rebuild path.
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

        // A commit is allowed to replace the root surface while a spring-open
        // Folder is still on screen, but it must NOT change who owns the stage.
        // Apply the Folder visibility rule to the newly adopted surface before
        // returning so there is no one-frame root-grid flash.
        setFolderBackgroundVisible(
            openFolderID != nil,
            animated: false
        )
        setPageHitTargetsEnabled(
            openFolderID == nil
        )

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

        // Keep isCommittingLayout=true until visual ownership AND AppKit hit
        // targets are ready. Unlocking here used to expose a visible tile with no
        // button for one run-loop turn; clicking it fell through to root mouseDown
        // and dismissed Launchpad.

        // When a drag preview has already been proven identical to the committed
        // document, keep that exact layer tree alive. Rebuilding it would flash
        // displaced apps at their final positions after a folder merge.
        if context
            .didAdoptCommittedPreview,
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
                .opacity =
                    openFolderID == nil
                        ? 1
                        : 0

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
                hidden: openFolderID != nil
            )

            // Keep root AppKit ownership disabled while the Folder overlay is
            // open. closeFolder() will restore both root visibility and hit
            // targets through the normal Folder-close handoff.
            setFolderBackgroundVisible(
                openFolderID != nil,
                animated: false
            )
            setPageHitTargetsEnabled(
                openFolderID == nil
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

            // Preview layer + NSButtons are now atomically ready for input.
            isCommittingLayout = false
            dragStateMachine.finish()
            return
        }

        // Any preview that still cannot be proven identical to the committed
        // document falls back to a full rebuild. Cross-page folder merges are
        // normally adopted after their hidden page cache is refreshed above.
        //
        // IMPORTANT: perform that rebuild synchronously before unlocking input.
        // Otherwise the CALayer remains visible for a frame while its NSButton
        // has already been detached, and a folder click becomes a background click.
        needsLayout = true
        isCommittingLayout = false
        layoutSubtreeIfNeeded()

        // Full-rebuild fallback follows the same ownership invariant as the
        // adopted-preview path. A still-open Folder keeps the rebuilt root
        // surface and its hit targets hidden.
        setFolderBackgroundVisible(
            openFolderID != nil,
            animated: false
        )
        setPageHitTargetsEnabled(
            openFolderID == nil
        )
        dragStateMachine.finish()
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
                customTitle: "Untitled"
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
        if session.sourceOrigin.folderID == nil,
           session.sourceEntry.tileLayer.superlayer == nil {
            session.originalSurface.layer.addSublayer(
                session.sourceEntry.tileLayer
            )
        }
        session.sourceEntry.tileLayer.opacity = 1
        session.sourceEntry.iconLayer.opacity = 1
        if session.sourceOrigin.folderID != nil {
            session.sourceEntry.button.removeFromSuperview()
        }
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

        if folderItemDragSession != nil {
            cancelFolderItemDragBeforeExit(animated: animated)
            return
        }

        guard !isFinishingDragVisuals else { return }
        guard let dragSession else {
            if dragStateMachine.state != .idle {
                _ = dragStateMachine.beginRollback()
                dragStateMachine.finish()
            }
            return
        }

        if dragSession.sourceOrigin.folderID != nil {
            cancelFolderExtractionDrag(dragSession, animated: animated)
            self.dragSession = nil
            return
        }

        dragSession.edgePagingTask?.cancel()
        dragSession.edgePagingTask = nil
        clearDragIntent(dragSession)
        dragSession.pendingCompletionPoint = nil
        dragSession.hasReleased = true
        dragSession.edgeGeneration &+= 1

        if dragSession.folderCreationPreview != nil {
            closeFolder(animated: false)
        }

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

        // Split the moving proxy into an icon-only backing store plus a live
        // label child. The label can then fade without ever replacing the moving
        // layer's contents, so there is no transition snapshot left behind at
        // the old pointer position.
        let previousSelectionOpacity = entry.selectionLayer.opacity
        let previousLabelOpacity = entry.labelLayer.opacity
        let modelIconOpacity = entry.iconLayer.opacity
        let modelIconTransform = entry.iconLayer.affineTransform()

        let visibleIconOpacity =
            entry.iconLayer.presentation()?.opacity
            ?? modelIconOpacity
        let visibleIconTransform =
            entry.iconLayer.presentation()?.affineTransform()
            ?? modelIconTransform
        let visibleLabelOpacity =
            entry.labelLayer.presentation()?.opacity
            ?? previousLabelOpacity

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
        proxyLabelLayer.opacity = visibleLabelOpacity
        proxy.addSublayer(proxyLabelLayer)

        return proxy
    }

    func dragProxyLabelLayer(_ proxy: CALayer) -> CATextLayer? {
        proxy.sublayers?.first {
            $0.name == DragProxyMetrics.labelLayerName
        } as? CATextLayer
    }

    /// Refresh the steady-state icon backing store before landing. The label is
    /// a separate child layer, so its merge fade can never leave a spatial ghost.
    func refreshDragProxyForRelease(
        _ proxy: CALayer,
        sourceEntry entry: LaunchpadPageEntry,
        hidesLabel: Bool = false
    ) {
        let scale = max(
            1,
            window?.backingScaleFactor ?? 1
        )

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


    func animateMergeProxyIntoFolder(
        _ proxy: CALayer,
        destination: CGPoint,
        destinationScale: CGFloat,
        duration: CFTimeInterval,
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
        proxy.setAffineTransform(.init(
            scaleX: destinationScale,
            y: destinationScale
        ))
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
        opacity.values = [
            NSNumber(value: startOpacity),
            NSNumber(value: startOpacity),
            NSNumber(value: 0),
        ]
        let fadeStartProgress =
            destinationScale <= FolderMergeVisualMetrics.fullFolderAbsorbScale
                ? FolderMergeVisualMetrics.fullFolderFadeStartProgress
                : FolderMergeVisualMetrics.mergeFadeStartProgress

        opacity.keyTimes = [
            NSNumber(value: 0),
            NSNumber(value: fadeStartProgress),
            NSNumber(value: 1),
        ]
        opacity.duration = duration
        opacity.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut),
        ]
        proxy.add(opacity, forKey: "folderMergeLandingOpacity")
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

            case .application, .folder:
                destination =
                    mergeLandingDestination(
                        in: surface,
                        session: session
                    )
                        ?? proxy.position

                destinationScale = mergeLandingScale(session: session)
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

        if completionKind == .merge {
            animateMergeProxyIntoFolder(
                proxy,
                destination: destination,
                destinationScale: destinationScale,
                duration: duration,
                timingFunction: completionTransition.timingFunction
            )

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration))
                finalize()
            }
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

    func finishFolderCreationPreviewVisuals(
        _ session: LaunchpadDragSession,
        animated: Bool,
        completion: (() -> Void)?
    ) {
        guard let preview = session.folderCreationPreview else {
            completion?()
            return
        }

        updateDropHighlight(.outside)
        refreshDragProxyForRelease(
            session.proxyLayer,
            sourceEntry: session.sourceEntry,
            hidesLabel: true
        )

        let sourcePresentation = folderPresentations.first {
            $0.button.application.id == preview.sourceIdentity
        }
        let destination = preview.sourceLandingCenter
            ?? sourcePresentation?.tileLayer.frame.center
            ?? session.proxyLayer.position
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = LaunchpadVisualStyle.dragCompletionTransition(kind: .insertion)
        // OPENLAUNCHPAD_SPRING_OPEN_RELEASE_HANDOFF_V1
        // Spring-open Folder release is still an ordinary positional landing.
        // Use the exact same insertion/reflow transition as App swaps, rollback,
        // and Folder->root landing instead of the old 0.22s fast path.
        let duration: CFTimeInterval = shouldAnimate ? transition.duration : 0

        // mouseUp has completed the AppKit tracking chain. The transparent root
        // source button can finally retire; the folder child will become the
        // next interactive owner after the proxy lands.
        session.sourceEntry.button.isEnabled = false
        session.sourceEntry.button.isHidden = true

        let finalize = { [weak self, weak proxy = session.proxyLayer, weak sourcePresentation] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy?.removeAllAnimations()
            proxy?.opacity = 0
            proxy?.removeFromSuperlayer()
            sourcePresentation?.tileLayer.opacity = 1
            sourcePresentation?.button.isHidden = false
            sourcePresentation?.button.isEnabled = true
            CATransaction.commit()
            self?.folderHiddenApplicationID = nil
            completion?()
        }

        guard shouldAnimate else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.proxyLayer.position = destination
            session.proxyLayer.setAffineTransform(.identity)
            session.proxyLayer.opacity = 1
            CATransaction.commit()
            finalize()
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(
            transition.timingFunction
        )
        session.proxyLayer.position = destination
        session.proxyLayer.setAffineTransform(.identity)
        session.proxyLayer.opacity = 1
        CATransaction.commit()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            finalize()
        }
    }

    func finishDragVisuals(
        _ session: LaunchpadDragSession,
        committed: Bool,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        if committed, session.folderCreationPreview != nil {
            finishFolderCreationPreviewVisuals(
                session,
                animated: animated,
                completion: completion
            )
            return
        }
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
            sourceEntry: session.sourceEntry,
            hidesLabel: session.isSourceLabelHiddenForMerge
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

        let visualCompletionDuration: CFTimeInterval = {
            guard
                shouldAnimate,
                committed,
                previewSurface != nil
            else { return duration }

            switch session.target {
            case .application, .folder:
                // The source proxy can finish its short merge landing first, but
                // keep the preview alive until surrounding apps complete the same
                // reflow used by ordinary App exchanges.
                return duration
                    + FolderMergeVisualMetrics.postLandingReflowDelay
                    + LaunchpadVisualStyle.dragReflowTransition(
                        movedForward: false
                    ).duration
            case .insertion, .pageInsertion, .outside:
                return duration
            }
        }()

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

            case .application, .folder:
                destination =
                    mergeLandingDestination(
                        in: previewSurface,
                        session: session
                    )
                        ?? proxy.position

                destinationScale = mergeLandingScale(session: session)
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
        // full drag-reflow duration. That left a stale bitmap sitting on
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

        if completionKind == .merge {
            CATransaction.commit()

            animateMergeProxyIntoFolder(
                proxy,
                destination: destination,
                destinationScale: destinationScale,
                duration: duration,
                timingFunction: completionTransition.timingFunction
            )
        } else {
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
        }

        // A rollback can have displaced preview tiles still moving even when
        // the pointer has already brought the proxy back to its origin. In that
        // case the proxy creates no implicit animation, so a CATransaction
        // completion may fire before the visible rollback finishes. Drive the
        // handoff from the declared transition duration instead.
        Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(visualCompletionDuration)
            )
            finishPresentation()
        }
    }

}

private extension LaunchpadRootView {
        // MARK: - Native-style folder title editing

        func startFolderTitleEditing() {
            guard
                folderTitleEditor == nil,
                !isCommittingFolderTitle,
                let openFolderID,
                let folder = resolvedFolder(id: openFolderID),
                folderTitleFrame.width > 0,
                folderTitleFrame.height > 0
            else { return }

            let editor = NSTextField(frame: folderTitleFrame)
            editor.stringValue = folder.title
            editor.isEditable = true
            editor.isSelectable = true
            editor.isBordered = false
            editor.isBezeled = false
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.textColor = NSColor.white.withAlphaComponent(0.96)
            editor.font = NSFont.systemFont(ofSize: 27, weight: .regular)
            editor.alignment = .center
            editor.focusRingType = .none
            editor.maximumNumberOfLines = 1
            editor.lineBreakMode = .byClipping
            editor.delegate = self
            editor.setAccessibilityLabel("Folder name")

            folderTitleEditor = editor
            folderTitleLayer?.opacity = 0
            addSubview(editor)

            guard window?.makeFirstResponder(editor) == true else {
                editor.removeFromSuperview()
                folderTitleEditor = nil
                folderTitleLayer?.opacity = 1
                return
            }
            editor.currentEditor()?.selectAll(nil)
        }

        func finishFolderTitleEditing(commit: Bool) {
            guard !isEndingFolderTitleEditing, let editor = folderTitleEditor else { return }
            isEndingFolderTitleEditing = true

            let folderID = openFolderID
            let rawTitle = editor.stringValue
            let fallbackTitle = folderID.flatMap { resolvedFolder(id: $0)?.title } ?? "Untitled"
            let normalizedTitle = normalizedFolderTitle(rawTitle)

            // Clear ownership before resigning first responder because AppKit sends
            // controlTextDidEndEditing synchronously during the responder handoff.
            folderTitleEditor = nil
            editor.delegate = nil
            editor.removeFromSuperview()
            folderTitleLayer?.opacity = 1
            folderTitleLayer?.string = commit ? normalizedTitle : fallbackTitle
            window?.makeFirstResponder(self)
            isEndingFolderTitleEditing = false

            guard commit, let folderID else { return }
            persistFolderTitle(normalizedTitle, folderID: folderID)
        }

        func normalizedFolderTitle(_ rawTitle: String) -> String {
            let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled" : trimmed
        }

        func persistFolderTitle(_ title: String, folderID: UUID) {
            guard !isCommittingFolderTitle else { return }

            let draft: LauncherLayoutDraft
            do {
                var candidate = try LauncherLayoutDraft(document: layoutDocument)
                try candidate.renameFolder(folderID, to: title)
                guard candidate.hasChanges else { return }
                draft = candidate
            } catch {
                NSSound.beep()
                return
            }

            isCommittingFolderTitle = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { isCommittingFolderTitle = false }
                do {
                    layoutDocument = try await layoutStore.commit(draft)
                    invalidatePageSurfaceCache()
                    if openFolderID == folderID {
                        renderFolderOverlay(animated: false)
                    } else {
                        needsLayout = true
                    }
                } catch {
                    NSSound.beep()
                    if openFolderID == folderID {
                        renderFolderOverlay(animated: false)
                    }
                }
            }
        }

        // MARK: - Folder child drag -> root drag handoff

        func folderItemPointerDown(
            folderID: UUID,
            application: ApplicationRecord,
            absoluteIndex: Int,
            frames: GridItemFrames,
            presentation: AppTilePresentation,
            event: NSEvent
        ) {
            guard
                openFolderID == folderID,
                dragSession == nil,
                folderItemDragSession == nil,
                !isCommittingLayout,
                !isFinishingDragVisuals,
                dragStateMachine.pointerDown(on: .application(application.id))
            else { return }

            if folderTitleEditor != nil {
                finishFolderTitleEditing(commit: true)
            }

            let entry = LaunchpadPageEntry(
                item: .application(application),
                absoluteIndex: absoluteIndex,
                frames: frames,
                presentation: .application(presentation)
            )
            pendingFolderPress = PendingFolderTilePress(
                folderID: folderID,
                entry: entry,
                point: convert(event.locationInWindow, from: nil)
            )
            animatePressed(on: entry.iconLayer, isPressed: true)
        }

        func folderItemPointerDragged(_ update: TilePointerDragUpdate) {
            let point = convert(update.event.locationInWindow, from: nil)

            if let session = dragSession, session.sourceOrigin.folderID != nil {
                updateDragInteraction(at: point)
                return
            }

            guard update.hasExceededActivationDistance else { return }
            if folderItemDragSession == nil {
                beginFolderItemDrag(at: point)
            }
            updateFolderItemDrag(at: point)
        }

        func folderItemPointerUp(_ release: TilePointerRelease) {
            defer { pendingFolderPress = nil }
            let point = convert(release.event.locationInWindow, from: nil)

            if let session = dragSession, session.sourceOrigin.folderID != nil {
                let trackingButton = session.sourceEntry.button
                if session.target == .outside,
                   let fallback = nearestFolderExtractionInsertionTarget(at: point, session: session) {
                    applyDragPreviewTarget(fallback, session: session)
                }
                completeDragInteraction(at: point)
                trackingButton.removeFromSuperview()
                return
            }

            if folderItemDragSession != nil {
                cancelFolderItemDragBeforeExit(animated: true)
                return
            }

            if let pendingFolderPress {
                animatePressed(on: pendingFolderPress.entry.iconLayer, isPressed: false)
            }
            dragStateMachine.finish()
        }

        func folderItemPointerCancelled() {
            if let session = dragSession, session.sourceOrigin.folderID != nil {
                let trackingButton = session.sourceEntry.button
                cancelDragInteraction()
                trackingButton.removeFromSuperview()
                return
            }
            if folderItemDragSession != nil {
                cancelFolderItemDragBeforeExit(animated: true)
                return
            }
            if let pendingFolderPress {
                animatePressed(on: pendingFolderPress.entry.iconLayer, isPressed: false)
            }
            pendingFolderPress = nil
            dragStateMachine.finish()
        }

        func beginFolderItemDrag(at point: CGPoint) {
            guard
                let pendingFolderPress,
                let sourceButton = pendingFolderPress.entry.button as? AppTileButton,
                let sourceTileParent = pendingFolderPress.entry.tileLayer.superlayer,
                dragStateMachine.beginDragging()
            else { return }

            let sourceTileIndex = sourceTileParent.sublayers?.firstIndex(where: {
                $0 === pendingFolderPress.entry.tileLayer
            }) ?? (sourceTileParent.sublayers?.count ?? 0)
            let pointerOffset = CGVector(
                dx: pendingFolderPress.point.x - pendingFolderPress.entry.frames.cell.midX,
                dy: pendingFolderPress.point.y - pendingFolderPress.entry.frames.cell.midY
            )
            let proxy = makeDragProxy(for: pendingFolderPress.entry, initialPoint: pendingFolderPress.point)
            let context = FolderItemDragSession(
                folderID: pendingFolderPress.folderID,
                sourceEntry: pendingFolderPress.entry,
                proxyLayer: proxy,
                pointerOffset: pointerOffset,
                trackingButton: sourceButton,
                sourceTileParent: sourceTileParent,
                sourceTileIndex: sourceTileIndex
            )
            folderItemDragSession = context

            // Proxy acquisition and source detachment happen in one display
            // transaction. The folder never renders a duplicate source app and
            // the detached source remains fully opaque for later release snapshots.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dragOverlayLayer.addSublayer(proxy)
            pendingFolderPress.entry.tileLayer.opacity = 1
            pendingFolderPress.entry.tileLayer.removeFromSuperlayer()
            animateDragLift(
                proxy,
                from: pendingFolderPress.entry.frames.cell.center,
                to: point,
                offset: pointerOffset
            )
            CATransaction.commit()
        }

        func updateFolderItemDrag(at point: CGPoint) {
            guard let context = folderItemDragSession else { return }
            let center = CGPoint(
                x: point.x - context.pointerOffset.dx,
                y: point.y - context.pointerOffset.dy
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            context.proxyLayer.position = center
            CATransaction.commit()

            // OPENLAUNCHPAD_FOLDER_DRAG_HANDOFF_V3
            // Ownership is one-way after extraction, so an extra 16pt dead zone is
            // unnecessary. The moment the dragged app center leaves the visible
            // folder panel, promote it to the root drag session.
            guard !folderPanelFrame.contains(center) else { return }
            promoteFolderItemDragToRoot(context, at: point)
        }

        func promoteFolderItemDragToRoot(_ context: FolderItemDragSession, at point: CGPoint) {
            guard
                folderItemDragSession === context,
                let metrics = currentMetrics,
                let originalSurface = activeSurface,
                case let .application(application) = context.sourceEntry.item
            else { return }

            let draft: LauncherLayoutDraft
            do {
                var candidate = try LauncherLayoutDraft(
                    document: layoutDocument.normalizedForPageCapacity(metrics.itemsPerPage)
                )
                try candidate.extractApplication(
                    application.id,
                    fromFolder: context.folderID,
                    pageCapacity: metrics.itemsPerPage
                )
                draft = candidate
            } catch {
                cancelFolderItemDragBeforeExit(animated: true)
                return
            }

            let session = LaunchpadDragSession(
                sourceEntry: context.sourceEntry,
                draft: draft,
                proxyLayer: context.proxyLayer,
                pointerOffset: context.pointerOffset,
                originalSurface: originalSurface,
                sourcePage: currentPage,
                sourceOrigin: .folder(context.folderID),
                projectionBaselineDocument: draft.document
            )
            session.lastPointerPoint = point
            dragSession = session
            folderItemDragSession = nil
            pendingFolderPress = nil

            // Build the root projection while the folder overlay still owns the
            // screen. The preview is based on draft.document, where the dragged
            // child has already been removed from its folder. It starts hidden and
            // becomes the root surface that closeFolder() fades in, so the stale
            // pre-extraction folder miniature is never exposed.
            prepareFolderExtractionRootPreview(session, metrics: metrics)

            closeFolder(animated: true, preservingTrackedButton: context.trackingButton)
            updateDragInteraction(at: point)
        }

        func prepareFolderExtractionRootPreview(
            _ session: LaunchpadDragSession,
            metrics: GridMetrics
        ) {
            let baseline = session.projectionBaselineDocument
                .normalizedForPageCapacity(metrics.itemsPerPage)
            let sourceID = session.sourceEntry.item.id

            var sourceLocation: DragPageLocation?
            for (pageIndex, page) in baseline.pages.enumerated() {
                if let itemIndex = page.firstIndex(where: { item in
                    switch (item, sourceID) {
                    case let (.application(reference), .application(identity)):
                        return reference.identity == identity
                    case let (.folder(folder), .folder(folderID)):
                        return folder.id == folderID
                    default:
                        return false
                    }
                }) {
                    sourceLocation = DragPageLocation(page: pageIndex, index: itemIndex)
                    break
                }
            }

            guard let sourceLocation else { return }

            updateDragPreviewLayout(
                session,
                location: sourceLocation,
                animated: false,
                metrics: metrics
            )
            setDragTarget(
                .pageInsertion(page: sourceLocation.page, index: sourceLocation.index),
                session: session
            )

            guard let previewSurface = session.previewSurface else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewSurface.layer.opacity = 0
            previewSurface.layer.isHidden = false
            CATransaction.commit()

            // closeFolder()/setFolderBackgroundVisible(false) must fade THIS
            // post-extraction surface in, not the stale original root surface.
            activeSurface = previewSurface
            pageContentLayer = previewSurface.layer
        }

        func nearestFolderExtractionInsertionTarget(
            at point: CGPoint,
            session: LaunchpadDragSession
        ) -> LauncherDropTarget? {
            guard
                session.sourceOrigin.folderID != nil,
                let metrics = currentMetrics,
                bounds.contains(point)
            else { return nil }

            let baseline = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage)
            let pageItems = baseline.pages.indices.contains(currentPage) ? baseline.pages[currentPage] : []
            let pageIDs = pageItems.map { item -> LauncherLayoutItemIdentifier in
                switch item {
                case let .application(reference): .application(reference.identity)
                case let .folder(folder): .folder(folder.id)
                }
            }
            let sourceID = session.sourceEntry.item.id
            let countWithoutSource = pageIDs.filter { $0 != sourceID }.count
            let usableSlotCount = max(1, min(metrics.itemsPerPage, countWithoutSource + 1))
            let nearestSlot = (0..<usableSlotCount).compactMap { slot -> (Int, CGFloat)? in
                guard let frame = metrics.cellFrame(forItemAt: slot) else { return nil }
                let distance = hypot(point.x - frame.midX, point.y - frame.midY)
                return (slot, distance)
            }.min { $0.1 < $1.1 }?.0
            guard let nearestSlot else { return nil }

            let projection = pageProjection(metrics: metrics, document: baseline)
            let visibleIDs = projection.pages.indices.contains(currentPage)
                ? projection.pages[currentPage].map(\.id)
                : []
            guard let index = ResolvedLaunchpadInsertionIndex.resolve(
                visibleSlot: min(nearestSlot, countWithoutSource),
                pageIdentifiers: pageIDs,
                visibleIdentifiers: visibleIDs,
                sourceIdentifier: sourceID
            ) else { return nil }
            return .pageInsertion(page: currentPage, index: index)
        }

        func cancelFolderItemDragBeforeExit(animated: Bool) {
            pendingFolderPress = nil
            guard let context = folderItemDragSession else {
                dragStateMachine.finish()
                return
            }
            folderItemDragSession = nil
            _ = dragStateMachine.beginRollback()

            let sourceParent = context.sourceTileParent
            let sourceIndex = context.sourceTileIndex
            let finish = { [weak self, weak proxy = context.proxyLayer, weak sourceLayer = context.sourceEntry.tileLayer, weak iconLayer = context.sourceEntry.iconLayer] in
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                // Return the real folder child before retiring the proxy. Both
                // mutations commit together, so visual ownership never drops to zero.
                if let sourceLayer, sourceLayer.superlayer == nil {
                    let currentCount = sourceParent.sublayers?.count ?? 0
                    let restoredIndex = UInt32(min(max(sourceIndex, 0), currentCount))
                    sourceParent.insertSublayer(sourceLayer, at: restoredIndex)
                }
                sourceLayer?.opacity = 1
                iconLayer?.removeAnimation(forKey: "iconPressedOpacity")
                iconLayer?.opacity = 1
                iconLayer?.setAffineTransform(.identity)

                proxy?.removeAllAnimations()
                proxy?.removeFromSuperlayer()
                CATransaction.commit()
                self?.dragStateMachine.finish()
            }

            let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard shouldAnimate else {
                finish()
                return
            }
            let transition = LaunchpadVisualStyle.dragCompletionTransition(kind: .rollback)
            CATransaction.begin()
            CATransaction.setAnimationDuration(transition.duration)
            CATransaction.setAnimationTimingFunction(transition.timingFunction)
            context.proxyLayer.position = context.sourceEntry.frames.cell.center
            context.proxyLayer.setAffineTransform(.identity)
            context.proxyLayer.opacity = 1
            CATransaction.commit()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(transition.duration))
                finish()
            }
        }

        func cancelFolderExtractionDrag(_ session: LaunchpadDragSession, animated: Bool) {
            guard let folderID = session.sourceOrigin.folderID else { return }
            session.edgePagingTask?.cancel()
            clearDragIntent(session)
            session.pendingCompletionPoint = nil
            session.edgeGeneration &+= 1
            session.draft.rollback()

            folderAnimationGeneration &+= 1
            cleanupFolderOverlay()
            session.proxyLayer.removeAllAnimations()
            session.proxyLayer.removeFromSuperlayer()
            session.sourceEntry.button.removeFromSuperview()

            let originalSurface = session.originalSurface
            for surface in pageSurfaces.values where surface !== originalSurface {
                detachButtons(from: surface)
                surface.layer.removeAllAnimations()
                surface.layer.removeFromSuperlayer()
            }
            if let edgeIncoming = session.edgeIncomingSurface, edgeIncoming !== originalSurface {
                detachButtons(from: edgeIncoming)
                edgeIncoming.layer.removeFromSuperlayer()
            }
            if let previewSurface = session.previewSurface, previewSurface !== originalSurface {
                detachButtons(from: previewSurface)
                previewSurface.layer.removeFromSuperlayer()
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            originalSurface.layer.removeAllAnimations()
            originalSurface.layer.frame = bounds
            originalSurface.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            originalSurface.layer.opacity = 1
            originalSurface.layer.isHidden = false
            if originalSurface.layer.superlayer == nil {
                rootLayer.insertSublayer(originalSurface.layer, below: fixedOverlayLayer)
            }
            CATransaction.commit()

            currentPage = session.sourcePage
            activeSurface = originalSurface
            pageContentLayer = originalSurface.layer
            pageSurfaces = [session.sourcePage: originalSurface]
            attachButtons(to: originalSurface, hidden: false)
            setPageHitTargetsEnabled(true)
            dragStateMachine.finish()

            if let metrics = currentMetrics {
                updatePageIndicator(
                    pageCount: pageProjection(metrics: metrics).pageCount,
                    metrics: metrics,
                    scale: window?.backingScaleFactor ?? 1
                )
            }
            openFolder(folderID, sourceFrame: folderSourceFrame(for: folderID))
        }

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
        setFolderBackgroundVisible(true, animated: true)
        renderFolderOverlay(animated: true)
    }

    func folderSourceFrame(for folderID: UUID) -> CGRect? {
        activeSurface?.entries.first { $0.item.folderID == folderID }?.frames.icon
    }

    func resolvedFolder(id: UUID) -> ResolvedLaunchpadFolder? {
        let document: LauncherLayoutDocument
        if let session = dragSession,
           session.folderCreationPreview?.folderID == id {
            document = session.draft.document
        } else {
            document = layoutDocument
        }

        return ResolvedLaunchpadItemFactory.makeItems(
            document: document,
            applications: applications,
            query: ""
        ).first { $0.id == .folder(id) }.flatMap {
            guard case let .folder(folder) = $0 else { return nil }
            return folder
        }
    }

    func setFolderBackgroundVisible(_ visible: Bool, animated: Bool) {
        // Open folders own the stage. Hide the root app grid completely;
        // wallpaper remains visible and AppKit hit targets are managed separately.
        let targetOpacity: Float = visible ? 0 : 1
        let indicatorOpacity: Float = visible ? 0 : 1
        let duration: CFTimeInterval = animated ? 0.18 : 0

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        activeSurface?.layer.opacity = targetOpacity
        pageIndicatorLayer.opacity = indicatorOpacity
        CATransaction.commit()
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
        folderTitleLayer = nil
        folderTitleFrame = .zero
        folderTitleHitFrame = .zero
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
        dimLayer.backgroundColor = NSColor.clear.cgColor
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
        panelLayer.cornerRadius = min(32, metrics.panelFrame.height * 0.14)
        panelLayer.cornerCurve = .continuous
        panelLayer.backgroundColor = NSColor.white.withAlphaComponent(0.46).cgColor
        panelLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panelLayer.borderWidth = 0.6
        panelLayer.shadowColor = NSColor.black.cgColor
        panelLayer.shadowOpacity = 0.22
        panelLayer.shadowOffset = CGSize(width: 0, height: -10)
        panelLayer.shadowRadius = 30
        contentLayer.addSublayer(panelLayer)

        // OPENLAUNCHPAD_FOLDER_TITLE_27PT_V1
        let titleFont = NSFont.systemFont(ofSize: 27, weight: .regular)
        let titleLayer = CATextLayer()
        titleLayer.frame = metrics.titleFrame
        titleLayer.string = folder.title
        titleLayer.alignmentMode = .center
        titleLayer.fontSize = 27
        titleLayer.font = titleFont
        titleLayer.foregroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        titleLayer.contentsScale = scale
        contentLayer.addSublayer(titleLayer)
        folderTitleLayer = titleLayer
        folderTitleFrame = metrics.titleFrame
        let measuredTitleWidth = ceil(
            (folder.title as NSString).size(withAttributes: [.font: titleFont]).width
        )
        let titleHitWidth = min(metrics.titleFrame.width, max(88, measuredTitleWidth + 28))
        folderTitleHitFrame = CGRect(
            x: metrics.titleFrame.midX - titleHitWidth / 2,
            y: metrics.titleFrame.minY,
            width: titleHitWidth,
            height: metrics.titleFrame.height
        )

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

            let isDraggedSource = folderHiddenApplicationID == application.id
            if isDraggedSource {
                // The model already contains the provisional child, but the
                // floating drag proxy remains its sole visual owner until drop.
                presentation.tileLayer.opacity = 0
                presentation.button.isHidden = true
                dragSession?.folderCreationPreview?.sourceLandingCenter = frames.cell.center
            } else {
                presentation.button.isHidden = animated
            }

            presentation.button.onHoverChanged = { [weak iconLayer = presentation.iconLayer,
                                                      weak self] isHovering in
                self?.animateHover(on: iconLayer, isHovering: isHovering)
            }
            presentation.button.onPointerDown = { [weak self, weak presentation] event in
                guard let self, let presentation else { return }
                self.folderItemPointerDown(
                    // OPENLAUNCHPAD_FOLDER_COMPILE_REPAIR_V1
                    // This callback belongs to the concrete folder snapshot that
                    // renderFolderOverlay() already resolved. Do not pass the
                    // mutable optional openFolderID (UUID?) to a UUID parameter.
                    folderID: folder.id,
                    application: application,
                    absoluteIndex: startIndex + localIndex,
                    frames: frames,
                    presentation: presentation,
                    event: event
                )
            }
            presentation.button.onPointerDragged = { [weak self] update in
                self?.folderItemPointerDragged(update)
            }
            presentation.button.onPointerUp = { [weak self] release in
                self?.folderItemPointerUp(release)
            }
            presentation.button.onPointerCancelled = { [weak self] in
                self?.folderItemPointerCancelled()
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
                let isDraggedSource = folderHiddenApplicationID == presentation.button.application.id
                presentation.button.isHidden = isDraggedSource
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
                    let isDraggedSource = self.folderHiddenApplicationID == presentation.button.application.id
                    presentation.button.isHidden = isDraggedSource
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

    func closeFolder(animated: Bool = true, preservingTrackedButton: AppTileButton? = nil) {
        guard openFolderID != nil else { return }
        if folderTitleEditor != nil {
            finishFolderTitleEditing(commit: true)
        }
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
        removeFolderButtons(preserving: preservingTrackedButton)
        folderHiddenApplicationID = nil
        searchField.isHidden = false
        setFolderBackgroundVisible(false, animated: animated)
        if dragSession == nil, !isCommittingLayout {
            setPageHitTargetsEnabled(true)
        } else {
            // The original tracking button must live until AppKit delivers the
            // matching mouseUp, but every root target stays disabled during the
            // ownership handoff.
            setPageHitTargetsEnabled(false, preserving: preservingTrackedButton)
        }
        if renderedConfiguration == nil {
            needsLayout = true
        }

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
        folderTitleLayer = nil
        folderTitleFrame = .zero
        folderTitleHitFrame = .zero
        if let editor = folderTitleEditor {
            editor.delegate = nil
            editor.removeFromSuperview()
            folderTitleEditor = nil
        }
    }

    func removeFolderButtons(preserving preservedButton: AppTileButton? = nil) {
        for presentation in folderPresentations {
            if presentation.button !== preservedButton {
                presentation.button.removeFromSuperview()
            }
        }
        folderPresentations.removeAll(keepingCapacity: true)
    }
 }

    // NSTextFieldDelegate is intentionally handled by the root view so editing can
    // commit without introducing a second window or stealing the folder's visual
    // animation ownership.
    extension LaunchpadRootView {
        func controlTextDidEndEditing(_ obj: Notification) {
            guard
                !isEndingFolderTitleEditing,
                let editor = folderTitleEditor,
                obj.object as? NSTextField === editor
            else { return }
            finishFolderTitleEditing(commit: true)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let editor = folderTitleEditor, control === editor else { return false }
            if commandSelector == NSSelectorFromString("insertNewline:") {
                finishFolderTitleEditing(commit: true)
                return true
            }
            if commandSelector == NSSelectorFromString("cancelOperation:") {
                finishFolderTitleEditing(commit: false)
                return true
            }
            return false
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

    var labelLayer: CATextLayer {
        switch self {
        case let .application(presentation): presentation.labelLayer
        case let .folder(presentation): presentation.labelLayer
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
    var labelLayer: CATextLayer { presentation.labelLayer }
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

private enum DragSourceOrigin {
        case root
        case folder(UUID)

        var folderID: UUID? {
            guard case let .folder(folderID) = self else { return nil }
            return folderID
        }
    }

    @MainActor
    private struct PendingFolderTilePress {
        let folderID: UUID
        let entry: LaunchpadPageEntry
        let point: CGPoint
    }

    @MainActor
    private final class FolderItemDragSession {
        let folderID: UUID
        let sourceEntry: LaunchpadPageEntry
        let proxyLayer: CALayer
        let pointerOffset: CGVector
        let trackingButton: AppTileButton

        // OPENLAUNCHPAD_FOLDER_DRAG_OWNERSHIP_V2
        // Folder-local dragging follows the same ownership rule as root drag:
        // once the proxy exists, the source tile is detached rather than made
        // transparent. Keep its exact parent/index for an atomic local rollback.
        let sourceTileParent: CALayer
        let sourceTileIndex: Int

        init(
            folderID: UUID,
            sourceEntry: LaunchpadPageEntry,
            proxyLayer: CALayer,
            pointerOffset: CGVector,
            trackingButton: AppTileButton,
            sourceTileParent: CALayer,
            sourceTileIndex: Int
        ) {
            self.folderID = folderID
            self.sourceEntry = sourceEntry
            self.proxyLayer = proxyLayer
            self.pointerOffset = pointerOffset
            self.trackingButton = trackingButton
            self.sourceTileParent = sourceTileParent
            self.sourceTileIndex = sourceTileIndex
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
private final class FolderCreationPreview {
    let folderID: UUID
    let target: LauncherDropTarget
    let sourceIdentity: ApplicationIdentity
    var sourceLandingCenter: CGPoint?

    init(folderID: UUID, target: LauncherDropTarget, sourceIdentity: ApplicationIdentity) {
        self.folderID = folderID
        self.target = target
        self.sourceIdentity = sourceIdentity
    }
}

@MainActor
private final class LaunchpadDragSession {
    let sourceEntry: LaunchpadPageEntry

    var draft: LauncherLayoutDraft

    let proxyLayer: CALayer
    let pointerOffset: CGVector
    let originalSurface: LaunchpadPageSurface
    let sourcePage: Int
    let sourceOrigin: DragSourceOrigin
    let projectionBaselineDocument: LauncherLayoutDocument

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

    // Snapshot of the target folder/app icon at mouse-up. Merge landing uses
    // this frozen geometry while the final page surface waits to reflow.
    var mergeLandingTargetIconFrame: CGRect?

    var previewSurface: LaunchpadPageSurface?
    var previewState: LauncherDragPreviewState

    var previewDestinationIdentifier: LauncherLayoutItemIdentifier {
        previewState.destination
    }

    // OPENLAUNCHPAD_REORDER_RESPONSE_080_V4
    // The spatial gate prevents accidental swaps; keep the temporal confirmation
    // short so a deliberate crossing feels immediate.
    var intentState = LauncherDragIntentState(mergeDwell: 0.15, reorderDwell: 0.08)
    var intentTask: Task<Void, Never>?
    var folderSpringOpenTask: Task<Void, Never>?
    var folderCreationPreview: FolderCreationPreview?
    var isSourceLabelHiddenForMerge = false

    var target:
        LauncherDropTarget = .outside

    init(
        sourceEntry: LaunchpadPageEntry,
        draft: LauncherLayoutDraft,
        proxyLayer: CALayer,
        pointerOffset: CGVector,
        originalSurface: LaunchpadPageSurface,
        sourcePage: Int,
        sourceOrigin: DragSourceOrigin = .root,
        projectionBaselineDocument: LauncherLayoutDocument? = nil
    ) {
        self.sourceEntry = sourceEntry
        self.draft = draft
        self.proxyLayer = proxyLayer
        self.pointerOffset = pointerOffset
        self.originalSurface =
            originalSurface

        self.sourcePage =
            sourcePage

        self.sourceOrigin = sourceOrigin
        self.projectionBaselineDocument = projectionBaselineDocument ?? draft.snapshot

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
    // with the existing layer surfaces and the live drag preview was proven to
    // be an exact match. This covers both insertion and same-page folder merges.
    var didAdoptCommittedPreview = false

    init(session: LaunchpadDragSession) {
        self.session = session
    }
}
