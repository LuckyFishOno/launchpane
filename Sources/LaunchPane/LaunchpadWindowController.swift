import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

// This controller owns the AppKit event surface and its tightly coupled Core Animation presentation state.
// LAUNCHPANE_AGENT_LOW_MEMORY_V1
// swiftlint:disable file_length
@MainActor private final class LaunchpadCanvasView: NSView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// swiftlint:disable:next type_body_length
@MainActor final class LaunchpadRootView: NSView, NSTextFieldDelegate {
    let solver = LayoutConstraintSolver()
    let catalog = AppCatalogActor(excludedBundleIdentifiers: [
        "org.launchpane.LaunchPane", "org.launchpane.LaunchPaneAgent",
    ])
    let layoutStore = LauncherLayoutStore(fileURL: LaunchpadRuntimePaths.layoutFileURL)
    let iconCache = AppIconCache()
    private let wallpaperView = NSView()
    private let canvasView = LaunchpadCanvasView()
    let rootLayer = CALayer()
    private let fixedBackgroundLayer = CALayer()
    let fixedOverlayLayer = CALayer()
    let pageIndicatorLayer = CATextLayer()
    private let dragOverlayLayer = CALayer()
    var pageContentLayer = CALayer()
    let pageTransitionAnimator = PageTransitionAnimator()
    let searchField = LaunchpadSearchField(frame: .zero)
    var displayContext: DisplayContext
    private lazy var applicationDirectoryMonitor = ApplicationDirectoryMonitor { [weak self] in
        Task { @MainActor [weak self] in await self?.refreshApplicationsFromDisk() }
    }

    var applications: [ApplicationRecord] = []
    var layoutDocument = LauncherLayoutDocument()
    var pageSurfaces: [Int: LaunchpadPageSurface] = [:]
    var activeSurface: LaunchpadPageSurface?
    var renderedConfiguration: PageSurfaceConfiguration?
    var contentRevision = 0
    var currentPage = 0
    var selectedIndex = -1
    var currentMetrics: GridMetrics?
    var pendingPageDirection = 0
    var pageScrollGesture = PageScrollGesture()
    var pageSwipeInputGate = PageSwipeInputGate()
    var interactivePageSwipe: InteractivePageSwipe?
    var interactivePageGeneration = 0

    // LAUNCHPANE_VISIBLE_ALL_HQ_ICON_PREWARM_V4
    // One presentation-wide task fills the transient cache with full-size
    // icons after the first frame. It survives page transitions so opening a
    // folder later is a cache hit instead of a new decode burst.
    let iconPrewarmTasks = IconPrewarmTasks()

    var pagingDisplayLink: CADisplayLink?

    var isPageTransitionActive: Bool {
        pageTransitionAnimator.isAnimating || interactivePageSwipe != nil || folderPaging.animator.isAnimating
            || folderPaging.swipe != nil
    }

    let dragInteraction = DragInteractionCoordinator()
    let dragVisuals = DragVisualCoordinator()
    private var pendingPress: PendingTilePress?
    var dragSession: LaunchpadDragSession?
    let dragCommit = DragCommitCoordinator<LaunchpadDragCommitContext>()
    let folderReorderCommit = DragCommitCoordinator<FolderItemDragSession>()
    var isCommittingLayout = false
    private var isFinishingDragVisuals = false
    private var isResettingLayout = false

    let folderPresentation = FolderPresentation()
    let folderPaging = FolderPagingController()

    var openFolderID: UUID?

    var folderHiddenApplicationID: ApplicationIdentity?

    // LAUNCHPANE_FOLDER_INTERACTION_V1
    // Folder title editing is an AppKit control layered above the Core Animation
    // folder chrome. Folder-child dragging owns its gesture until the child
    // actually crosses the panel boundary, then hands the same mouse gesture to
    // the existing root drag/reflow state machine.
    var isCommittingFolderTitle = false
    var pendingFolderPress: PendingFolderTilePress?
    var folderItemDragSession: FolderItemDragSession?

    var suppressesResignActiveDismissal: Bool {
        dragInteraction.suppressesDismissal(
            hasFolderDrag: folderItemDragSession != nil, hasFolderCommit: openFolderID != nil && isCommittingLayout)
    }

    private var hasLoadedApplications = false
    var isLoadingApplications = true

    // High-resolution icon/page/wallpaper resources exist only while the
    // launcher is being presented. The agent keeps model/layout state warm
    // while hidden, but does not retain Retina render trees or decoded icons.
    var presentationResourcesActive = false

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    // Both window levels display this exact, already-composited desktop image.
    // Independent visual-effect backdrops cannot agree at their shared edge.
    private(set) var desktopBackdropImage: NSImage?
    private(set) var desktopImage: NSImage?

    /// The window transition scales the complete foreground around the display
    /// center. Counter-scaling this full-screen wallpaper keeps the desktop
    /// spatially fixed while icons and controls converge or disperse.
    var presentationBackgroundLayer: CALayer? { wallpaperView.layer }

    func resetForNewPresentation() {
        searchField.resetForPresentation()
        window?.makeFirstResponder(self)
        searchDidChange()
    }

    func refreshApplicationsFromDisk() async {
        let discovery = await catalog.refreshOutcome()
        applications = discovery.applications
        do {
            let reconciliation = try await layoutStore.reconcileAndCommit(
                applications: discovery.applications, completeness: discovery.completeness)
            layoutDocument = reconciliation.document
        } catch {
            layoutDocument =
                LauncherLayoutReconciler.reconcile(
                    LauncherLayoutDocument(), with: discovery.applications, completeness: discovery.completeness
                ).document
        }

        selectedIndex = -1
        if searchField.stringValue.isEmpty, let metrics = currentMetrics {
            let pages = ResolvedLaunchpadItemFactory.makePages(
                document: layoutDocument, applications: applications, query: "", pageCapacity: metrics.itemsPerPage)
            currentPage = min(currentPage, max(0, pages.pageCount - 1))
        } else {
            currentPage = 0
        }
        resetPageTransition()
        closeFolder(animated: false)
        invalidatePageSurfaceCache()
        needsLayout = true

        if presentationResourcesActive { scheduleIdleFirstPageIconWarm() }
    }

    func prepareForPresentation(displayContext: DisplayContext) {
        // Rehydrate at the display's real backing scale only when the launcher
        // is about to become visible. This preserves full Retina quality while
        // keeping the background agent independent of 1x/2x display cost.
        presentationResourcesActive = true

        if self.displayContext != displayContext { update(displayContext: displayContext) } else { updateWallpaper() }

        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func releasePresentationResourcesForIdle() {
        guard presentationResourcesActive else { return }
        presentationResourcesActive = false

        // Stop work which could repopulate decoded icons after the cache is
        // emptied. The application/layout model remains resident and cheap.
        cancelIconPrewarming()
        iconPrewarmTasks.cancelPresentation()
        folderPresentation.cancelIconLoading()

        resetIdlePagingState()

        discardIdleInteractionState()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Detach every AppKit hit target before releasing the page objects.
        for surface in pageSurfaces.values {
            detachButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.shouldRasterize = false
            surface.layer.removeFromSuperlayer()
        }

        // Preview/drag page trees can be attached directly to rootLayer and
        // are not necessarily present in pageSurfaces. Keep only the two fixed
        // structural layers while the launcher is idle.
        for layer in rootLayer.sublayers ?? [] where layer !== fixedBackgroundLayer && layer !== fixedOverlayLayer {
            layer.removeAllAnimations()
            layer.shouldRasterize = false
            layer.removeFromSuperlayer()
        }

        dragOverlayLayer.removeAllAnimations()
        dragOverlayLayer.sublayers?.forEach { layer in
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }

        pageIndicatorLayer.string = nil
        wallpaperView.layer?.contents = nil
        CATransaction.commit()

        pageSurfaces.removeAll(keepingCapacity: false)
        activeSurface = nil
        renderedConfiguration = nil
        currentMetrics = nil

        // pageContentLayer is merely a handle used by transition code. Give it
        // a tiny empty layer rather than retaining the previously active tree.
        pageContentLayer = CALayer()
        pageContentLayer.frame = bounds
        pageContentLayer.contentsScale = displayContext.backingScaleFactor

        desktopImage = nil
        desktopBackdropImage = nil

        // Keep only first-page standalone icons plus tiny 64px previews for
        // each first-page folder's nine visible children. Later-page icons and
        // full-size folder contents remain presentation-only.
        iconPrewarmTasks.cancelIdleFirstPage()
        iconCache.removeTransient()
        contentRevision &+= 1
        needsLayout = false
        scheduleIdleFirstPageIconWarm()
    }

    private func resetIdlePagingState() {
        pagingDisplayLink?.isPaused = true
        interactivePageGeneration &+= 1
        interactivePageSwipe = nil
        pendingPageDirection = 0
        pageScrollGesture = PageScrollGesture()
        pageSwipeInputGate = PageSwipeInputGate()
        pageTransitionAnimator.reset(contentLayer: pageContentLayer, canvasBounds: bounds)

    }

    private func discardIdleInteractionState() {
        // A dismissal may race with a drag/folder gesture. Do not animate a
        // rollback while hidden: discard transient presentation state and let
        // the next opening rebuild from the committed layout document.
        dragSession?.edgePagingTask?.cancel()
        dragSession?.proxyLayer.removeAllAnimations()
        dragSession?.proxyLayer.removeFromSuperlayer()
        dragSession = nil
        dragVisuals.discard()
        dragCommit.discard()
        folderReorderCommit.discard()
        pendingPress = nil
        pendingFolderPress = nil
        if let folderItemDragSession { cancelFolderItemDragEdgePaging(folderItemDragSession) }

        // A presentation can disappear while a drag is still active (display
        // change, launcher dismissal, termination). End the tracking state
        // silently before detaching the preserved AppKit mouse owner.
        dragInteraction.discardPointerForIdle()

        folderItemDragSession = nil
        dragInteraction.finish()
        isCommittingLayout = false
        isFinishingDragVisuals = false

        if openFolderID != nil { closeFolder(animated: false) }
        removeFolderButtons()
        cleanupFolderOverlay()

    }

    init(frame frameRect: NSRect, displayContext: DisplayContext) {
        self.displayContext = displayContext
        super.init(frame: frameRect)
        wantsLayer = true
        configureCanvas()
        setAccessibilityRole(.group)
        setAccessibilityLabel("LaunchPane")
        searchField.onTextChanged = { [weak self] in self?.searchDidChange() }
        searchField.onCancel = { [weak self] in self?.requestClose() }
        searchField.onResetRequested = { [weak self] in self?.confirmResetLaunchpad() }
        addSubview(searchField)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { nil }

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
        applicationDirectoryMonitor.start()

        Task { [weak self] in
            guard let self else { return }
            await refreshApplicationsFromDisk()
            isLoadingApplications = false
            selectedIndex = -1
            resetPageTransition()
            invalidatePageSurfaceCache()
            needsLayout = true

            // The hidden agent warms page-one standalone icons plus only the
            // nine tiny preview children of each first-page folder. No render
            // tree or later-page icon is retained.
            scheduleIdleFirstPageIconWarm()
        }
    }

    override func layout() {
        super.layout()
        guard presentationResourcesActive else { return }
        render()
    }

    func update(displayContext: DisplayContext) {
        // A display move can change backingScaleFactor. Restart the session-wide
        // HQ warm so every cached icon is guaranteed to satisfy the new screen.
        iconPrewarmTasks.cancelPresentation()
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
        guard !isPageTransitionActive, dragSession == nil, !isFinishingDragVisuals, !isResettingLayout else { return }
        let point = convert(event.locationInWindow, from: nil)
        if openFolderID != nil {
            // The native title sits above the translucent panel. Treat it as an
            // interactive control before applying the "outside panel closes" rule.
            if folderPresentation.folderTitleEditor != nil {
                finishFolderTitleEditing(commit: true)
            } else if folderPresentation.folderTitleHitFrame.contains(point) {
                startFolderTitleEditing()
                return
            }

            if !folderPresentation.folderPanelFrame.contains(point) { closeFolder() }
            return
        }

        if let fallbackEntry = visibleRootEntry(at: point) {
            // Normally an AppTileButton/FolderTileButton receives this event.
            // Reaching the root means a transient hit-target lifecycle gap. Never
            // interpret a geometrically valid tile click as a background dismiss.
            if case .folder(let folder) = fallbackEntry.item {
                openFolder(folder.id, sourceFrame: visibleIconFrame(for: fallbackEntry))
            }
            return
        }

        requestClose()
    }

    // LAUNCHPANE_VISIBLE_ROOT_ENTRY_ACCESS_REPAIR_V1
    fileprivate func visibleRootEntry(at point: CGPoint) -> LaunchpadPageEntry? {
        guard openFolderID == nil, let activeSurface else { return nil }
        return activeSurface.entries.first { entry in
            let frame = visibleIconFrame(for: entry).insetBy(dx: -4, dy: -4)
            return frame.contains(point)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !isFinishingDragVisuals, !isResettingLayout else { return }

        if event.keyCode == 53, dragInteraction.state != .idle {
            cancelDragInteraction()
            return
        }
        if openFolderID != nil {
            handleFolderKeyDown(event)
            return
        }

        switch event.keyCode {
        case 53: requestClose()
        case 123: moveSelection(.left)
        case 124: moveSelection(.right)
        case 125: moveSelection(.down)
        case 126: moveSelection(.up)
        case 36, 76: activateSelectedItem()
        default: focusSearch(with: event)
        }
    }

    private func handleFolderKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: closeFolder()
        case 123: moveFolderSelection(.left)
        case 124: moveFolderSelection(.right)
        case 125: moveFolderSelection(.down)
        case 126: moveFolderSelection(.up)
        case 36, 76: activateSelectedFolderItem()
        case 116: changeFolderPage(by: -1)
        case 121: changeFolderPage(by: 1)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard dragInteraction.state == .idle, !isCommittingLayout, !isFinishingDragVisuals, !isResettingLayout else {
            return
        }

        if openFolderID != nil {
            // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
            // Match root paging input semantics. Precise trackpad gestures are
            // direct-manipulation and are sampled onto the physical display's
            // refresh boundary. Wheel/phase-less input keeps the discrete path.
            if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
                if folderPaging.inputGate.consumes(
                    phase: PageScrollPhase(event.phase), momentum: PageScrollMomentum(event.momentumPhase),
                    isAnimating: folderPaging.animator.isAnimating
                        || folderPaging.swipe?.phase == .settling) {
                    return
                }
            }

            if handleInteractiveFolderPageSwipe(event) { return }

            if let direction = folderPaging.scrollGesture.consume(event) { changeFolderPage(by: direction) }
            return
        }

        // Finish the current transition without snapping back on a new gesture.
        // Keep rejecting that gesture's remainder even if settling ends midway.
        // Phase-less wheels must still update the discrete gesture's idle clock,
        // otherwise a long burst could be mistaken for a second page turn.
        if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            if pageSwipeInputGate.consumes(
                phase: PageScrollPhase(event.phase), momentum: PageScrollMomentum(event.momentumPhase),
                isAnimating: pageTransitionAnimator.isAnimating || interactivePageSwipe?.phase == .settling) {
                return
            }
        }

        // Precise trackpad gestures use direct manipulation:
        // the page follows the fingers, then settles after release.
        if handleInteractivePageSwipe(event) { return }

        // Mouse wheels / phase-less events keep the discrete fallback.
        if let direction = pageScrollGesture.consume(event) { changePage(by: direction, queuesDuringTransition: false) }
    }
}

extension LaunchpadRootView {
    var layoutPreferences: UserLayoutPreferences {
        UserLayoutPreferences(isRightToLeft: userInterfaceLayoutDirection == .rightToLeft)
    }

    var resolvedItems: [ResolvedLaunchpadItem] {
        ResolvedLaunchpadItemFactory.makeItems(
            document: layoutDocument, applications: applications, query: searchField.stringValue)
    }

    fileprivate var isSearchActive: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate func configureCanvas() {
        // Host the provider's cached material pixels directly. NSImageView
        // draws the same image into an additional full-screen backing store.
        // Set the layer BEFORE wantsLayer to opt into AppKit layer hosting.
        wallpaperView.layer = CALayer()
        wallpaperView.wantsLayer = true
        wallpaperView.layerContentsRedrawPolicy = .never
        wallpaperView.layer?.contentsGravity = .resize
        wallpaperView.layer?.masksToBounds = true
        wallpaperView.setAccessibilityHidden(true)
        addSubview(wallpaperView)

        // Do not decode/render wallpaper pixels while the process is only an
        // idle agent. prepareForPresentation() hydrates them just before show.

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
        fixedOverlayLayer.addSublayer(folderPresentation.folderOverlayLayer)
        fixedOverlayLayer.addSublayer(dragOverlayLayer)
        folderPresentation.folderOverlayLayer.isHidden = true
    }

    fileprivate func updateWallpaper() {
        let images = DesktopWallpaperProvider.images(for: displayContext.displayID)
        desktopImage = images?.desktop
        desktopBackdropImage = images?.frosted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperView.layer?.contents = images?.frosted.cgImage(forProposedRect: nil, context: nil, hints: nil)
        wallpaperView.layer?.contentsScale = displayContext.backingScaleFactor
        wallpaperView.layer?.backgroundColor = DesktopWallpaperProvider.fallbackColor.cgColor
        CATransaction.commit()
    }

    func pageProjection(metrics: GridMetrics, document: LauncherLayoutDocument? = nil)
        -> ResolvedLaunchpadPages {
        ResolvedLaunchpadItemFactory.makePages(
            document: document ?? layoutDocument, applications: applications, query: searchField.stringValue,
            pageCapacity: metrics.itemsPerPage)
    }

    func render() {
        guard !isPageTransitionActive, dragSession == nil, !isCommittingLayout, !isFinishingDragVisuals,
            !isResettingLayout
        else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1

        updateCanvasGeometry(scale: scale)

        let items = resolvedItems
        let metrics = solver.solve(display: displayContext, requested: layoutPreferences, itemCount: items.count)
        currentMetrics = metrics
        positionSearchField(in: metrics.searchReservedFrame)

        let configuration = PageSurfaceConfiguration(
            bounds: bounds, scale: scale, contentRevision: contentRevision, metrics: metrics)
        if configuration != renderedConfiguration {
            rebuildPageSurfaces(items: items, metrics: metrics, scale: scale, configuration: configuration)
        }

        let pageCount = pageProjection(metrics: metrics).pageCount
        currentPage = min(currentPage, max(0, pageCount - 1))
        let direction = pendingPageDirection
        pendingPageDirection = 0

        activatePageSurface(at: currentPage, direction: direction, scale: scale)
        updatePageIndicator(pageCount: pageCount, metrics: metrics, scale: scale)
        updateSelectionAppearance()

        if !isPageTransitionActive {
            stageAdjacentPageSurfaces(scale: scale)
            scheduleIconPrewarming(metrics: metrics, scale: scale)
            scheduleSessionHighQualityIconWarm(metrics: metrics, scale: scale)
        }
    }

    fileprivate func updateCanvasGeometry(scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperView.frame = bounds
        if let wallpaperLayer = wallpaperView.layer {
            // Relayout can occur during an opening/closing reversal. Assigning
            // frame while the inverse scale is active changes the layer bounds
            // and breaks the shared wallpaper coordinates at the menu seam.
            wallpaperLayer.bounds = wallpaperView.bounds
            wallpaperLayer.position = CGPoint(
                x: wallpaperView.frame.minX + wallpaperView.frame.width * wallpaperLayer.anchorPoint.x,
                y: wallpaperView.frame.minY + wallpaperView.frame.height * wallpaperLayer.anchorPoint.y)
            wallpaperLayer.contentsScale = displayContext.backingScaleFactor
        }
        canvasView.frame = bounds
        rootLayer.frame = bounds
        rootLayer.contentsScale = scale
        fixedBackgroundLayer.frame = bounds
        fixedOverlayLayer.frame = bounds
        folderPresentation.folderOverlayLayer.frame = bounds
        dragOverlayLayer.frame = bounds
        pageIndicatorLayer.contentsScale = scale
        CATransaction.commit()
    }

    func rebuildPageSurfaces(
        items: [ResolvedLaunchpadItem], metrics: GridMetrics, scale: CGFloat, configuration: PageSurfaceConfiguration
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
            guard retired.insert(ObjectIdentifier(surface)).inserted else { continue }
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
        for pageIndex in 0..<pageCount {
            pageSurfaces[pageIndex] = makePageSurface(
                pageIndex: pageIndex, items: items, metrics: metrics, scale: scale)
        }
        renderedConfiguration = configuration
    }

    func makePageSurface(
        pageIndex: Int, items: [ResolvedLaunchpadItem], metrics: GridMetrics, scale: CGFloat,
        projection: ResolvedLaunchpadPages? = nil
    ) -> LaunchpadPageSurface {
        let layer = CALayer()
        layer.frame = bounds
        layer.contentsScale = scale
        let surface = LaunchpadPageSurface(pageIndex: pageIndex, layer: layer)

        guard !items.isEmpty else {
            addStatusText(
                isLoadingApplications ? "Loading applications…" : "No matching applications", to: layer, scale: scale)
            return surface
        }

        let projection = projection ?? pageProjection(metrics: metrics)
        let range = projection.range(forPage: pageIndex)
        let startIndex = range.lowerBound
        let endIndex = range.upperBound
        guard startIndex < endIndex else { return surface }
        let visibleCount = endIndex - startIndex
        let centersSearchResults = isSearchActive

        for (localIndex, item) in items[startIndex..<endIndex].enumerated() {
            let frames =
                centersSearchResults
                ? metrics.centeredItemFrames(forItemAt: localIndex, visibleItemCount: visibleCount)
                : metrics.itemFrames(forItemAt: localIndex)
            guard let frames else { continue }
            let entry = makePageEntry(
                item: item, absoluteIndex: startIndex + localIndex, frames: frames, metrics: metrics, scale: scale)
            layer.addSublayer(entry.tileLayer)
            surface.entries.append(entry)
        }
        return surface
    }

    fileprivate func makePageEntry(
        item: ResolvedLaunchpadItem, absoluteIndex: Int, frames: GridItemFrames, metrics: GridMetrics, scale: CGFloat
    ) -> LaunchpadPageEntry {
        let presentation: LaunchpadTilePresentation
        switch item {
        case .application(let application):
            presentation = .application(
                AppTilePresentationFactory.make(
                    AppTileRenderInput(
                        application: application, cellFrame: frames.cell, iconFrame: frames.icon,
                        labelFrame: frames.label, scale: scale, selected: absoluteIndex == selectedIndex,
                        icon: iconCache.cgImage(for: application, pointSize: metrics.iconSize, scale: scale))))
        case .folder(let folder):
            let miniaturePointSize = AppTilePresentationFactory.folderMiniatureIconPointSize(
                forRootIconSize: metrics.iconSize)
            let childIcons = folder.applications.prefix(AppTilePresentationFactory.folderMaximumVisibleChildren)
                .compactMap { iconCache.cgImage(for: $0, pointSize: miniaturePointSize, scale: scale) }
            presentation = .folder(
                AppTilePresentationFactory.make(
                    FolderTileRenderInput(
                        folderID: folder.id, title: folder.title, cellFrame: frames.cell, iconFrame: frames.icon,
                        labelFrame: frames.label, scale: scale, selected: absoluteIndex == selectedIndex,
                        childIcons: childIcons, layoutDirection: userInterfaceLayoutDirection)))
        }

        let entry = LaunchpadPageEntry(
            item: item, absoluteIndex: absoluteIndex, frames: frames, presentation: presentation)
        configurePageEntry(entry)
        return entry
    }

    fileprivate func configurePageEntry(_ entry: LaunchpadPageEntry) {
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
        button.onPointerDown = { [weak self, weak entry] event in self?.tilePointerDown(entry: entry, event: event) }
        button.onPointerDragged = { [weak self] update in self?.tilePointerDragged(update) }
        button.onPointerUp = { [weak self] release in self?.tilePointerUp(release) }
        button.onPointerCancelled = { [weak self] in self?.tilePointerCancelled() }
    }

    fileprivate func activatePageSurface(at pageIndex: Int, direction: Int, scale: CGFloat) {
        guard let incomingSurface = pageSurfaces[pageIndex] else { return }
        let outgoingSurface = activeSurface

        if outgoingSurface === incomingSurface {
            attachButtons(to: incomingSurface, hidden: false)
            return
        }

        if let outgoingSurface { attachButtons(to: outgoingSurface, hidden: true) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingSurface.layer.frame = bounds
        incomingSurface.layer.contentsScale = scale
        incomingSurface.layer.opacity = openFolderID == nil ? 1 : 0.10
        incomingSurface.layer.isHidden = false
        if incomingSurface.layer.superlayer == nil {
            rootLayer.insertSublayer(incomingSurface.layer, below: fixedOverlayLayer)
        }
        CATransaction.commit()

        pageContentLayer = incomingSurface.layer
        activeSurface = incomingSurface

        let transition = outgoingSurface.flatMap { _ in
            LaunchpadVisualStyle.pageTransition(direction: direction, displayWidth: bounds.width)
        }

        guard let outgoingSurface, let transition else {
            attachButtons(to: incomingSurface, hidden: false)
            setPageHitTargetsEnabled(true)
            return
        }

        beginPageTransition(
            from: outgoingSurface.layer, to: incomingSurface.layer, direction: direction, style: transition)
    }

    // LAUNCHPANE_ULTRA_SMOOTH_PAGING_V1
    //
    // Keep currentPage and the immediate neighbours already attached one viewport
    // off-screen. A trackpad gesture then starts by changing only two CALayer
    // positions; it does not construct a page tree or churn the NSView hierarchy.
    func stageAdjacentPageSurfaces(scale: CGFloat) {
        // LAUNCHPANE_PAGING_LONG_SESSION_PERF_V1
        //
        // Paging visuals and pointer hit-targets have different lifetimes:
        //
        // - CALayers: keep current +/- 1 staged for instant interactive paging.
        // - NSButtons/NSTrackingAreas: keep ONLY the current page attached.
        //
        // Previously every visited adjacent page's hidden buttons stayed in the
        // NSView hierarchy. Because each tile owns an NSTrackingArea, repeated
        // paging steadily increased AppKit hit-testing / tracking bookkeeping.
        guard interactivePageSwipe == nil, !pageTransitionAnimator.isAnimating else { return }

        let restingPosition = CGPoint(x: bounds.midX, y: bounds.midY)
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
                    x: restingPosition.x + CGFloat(pageDistance) * width, y: restingPosition.y)
                surface.layer.opacity = 1
                surface.layer.isHidden = false

                if surface.layer.superlayer == nil { rootLayer.insertSublayer(surface.layer, below: fixedOverlayLayer) }
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
                attachButtons(to: surface, hidden: false)
            } else {
                detachButtons(from: surface)
            }
        }

        #if DEBUG
            if ProcessInfo.processInfo.environment["LAUNCHPANE_PAGING_DIAGNOSTICS"] == "1" {
                let attachedTileButtons = pageSurfaces.values.reduce(into: 0) { total, surface in
                    total += surface.entries.reduce(into: 0) { pageTotal, entry in
                        if entry.button.superview != nil { pageTotal += 1 }
                    }
                }

                let stagedPageLayers = pageSurfaces.values.reduce(into: 0) { total, surface in
                    if surface.layer.superlayer != nil { total += 1 }
                }

                // Count from the actual compositor tree as well as the cache. A
                // dropped cache entry must not hide an attached, retired page tree.
                let trackedPageLayers = Set(pageSurfaces.values.map { ObjectIdentifier($0.layer) })
                let orphanPageTrees = (rootLayer.sublayers ?? []).filter {
                    $0 !== fixedBackgroundLayer && $0 !== fixedOverlayLayer
                        && !trackedPageLayers.contains(ObjectIdentifier($0)) && !($0.sublayers?.isEmpty ?? true)
                }.count

                print(
                    "[PagingPerf] current=\(currentPage) " + "buttons=\(attachedTileButtons) "
                        + "stagedLayers=\(stagedPageLayers) " + "orphanPageTrees=\(orphanPageTrees) "
                        + "pages=\(pageSurfaces.count)")
            }
        #endif
    }

    func attachButtons(to surface: LaunchpadPageSurface, hidden: Bool) {
        for entry in surface.entries {
            let button = entry.button
            if button.superview == nil { addSubview(button, positioned: .below, relativeTo: searchField) }
            button.frame = entry.frames.icon
            button.isEnabled = !hidden
            button.isHidden = hidden || openFolderID != nil
        }
    }

    func detachButtons(from surface: LaunchpadPageSurface) {
        for entry in surface.entries { entry.button.removeFromSuperview() }
    }

    func updatePageIndicator(pageCount: Int, metrics: GridMetrics, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageIndicatorLayer.frame = metrics.pageIndicatorReservedFrame
        pageIndicatorLayer.string = (0..<pageCount).map { $0 == currentPage ? "●" : "○" }.joined(separator: "  ")
        pageIndicatorLayer.contentsScale = scale
        CATransaction.commit()
    }

    fileprivate func addStatusText(_ text: String, to layer: CALayer, scale: CGFloat) {
        let statusLayer = CATextLayer()
        statusLayer.frame = CGRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
        statusLayer.string = text
        statusLayer.alignmentMode = .center
        statusLayer.fontSize = 16
        statusLayer.foregroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        statusLayer.contentsScale = scale
        layer.addSublayer(statusLayer)
    }

    fileprivate func positionSearchField(in reservedFrame: CGRect) {
        let size = LaunchpadVisualStyle.searchFieldSize(forDisplayWidth: bounds.width)
        searchField.frame = CGRect(
            x: bounds.midX - size.width / 2, y: reservedFrame.midY - size.height / 2, width: size.width,
            height: size.height)
    }

    fileprivate func animatePressed(on iconLayer: CALayer?, isPressed: Bool) {
        guard let iconLayer else { return }

        let targetOpacity: Float = isPressed ? 0.78 : 1.0

        let currentOpacity = iconLayer.presentation()?.opacity ?? iconLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.opacity = targetOpacity
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "opacity")

        animation.fromValue = currentOpacity
        animation.toValue = targetOpacity

        animation.duration = isPressed ? 0.07 : 0.10

        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        iconLayer.add(animation, forKey: "iconPressedOpacity")
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

extension LaunchpadRootView {
    fileprivate func moveSelection(_ movement: GridNavigationMovement) {
        guard !isPageTransitionActive, let metrics = currentMetrics else { return }
        let items = resolvedItems
        let currentSelection =
            items.indices.contains(selectedIndex)
            ? selectedIndex : pageProjection(metrics: metrics).range(forPage: currentPage).first
        guard
            let index = GridSelectionNavigator.nextIndex(
                from: currentSelection, movement: movement,
                context: GridNavigationContext(
                    currentPage: currentPage, itemsPerPage: metrics.itemsPerPage, columns: metrics.columns,
                    itemCount: items.count, isRightToLeft: metrics.isRightToLeft))
        else { return }
        select(index: index, itemsPerPage: metrics.itemsPerPage)
    }

    fileprivate func select(index: Int, itemsPerPage: Int) {
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
            for entry in surface.entries { entry.selectionLayer.opacity = entry.absoluteIndex == selectedIndex ? 1 : 0 }
        }
    }

    func changePage(by offset: Int, queuesDuringTransition: Bool = true) {
        guard interactivePageSwipe == nil else { return }
        if pageTransitionAnimator.isAnimating {
            if queuesDuringTransition { _ = pageTransitionAnimator.queueLatestIfAnimating(direction: offset) }
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

    fileprivate func activateSelectedItem() {
        guard !isPageTransitionActive else { return }
        let items = resolvedItems
        guard items.indices.contains(selectedIndex) else { return }
        activate(items[selectedIndex])
    }

    fileprivate func activate(_ item: ResolvedLaunchpadItem) {
        switch item {
        case .application(let application): launch(application)
        case .folder(let folder): openFolder(folder.id, sourceFrame: folderSourceFrame(for: folder.id))
        }
    }

    func launch(_ application: ApplicationRecord) {
        if NSWorkspace.shared.open(application.bundleURL) { requestClose() }
    }

    @objc func applicationButtonPressed(_ sender: AppTileButton) {
        guard !isPageTransitionActive, dragSession == nil, !isFinishingDragVisuals, !suppressesResignActiveDismissal
        else { return }
        launch(sender.application)
    }

    @objc fileprivate func folderButtonPressed(_ sender: FolderTileButton) {
        guard !isPageTransitionActive, dragSession == nil, !isFinishingDragVisuals else { return }
        openFolder(sender.folderID, sourceFrame: sender.frame)
    }

    fileprivate func focusSearch(with event: NSEvent) {
        let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.isDisjoint(with: commandModifiers), let characters = event.characters,
            !characters.isEmpty, characters.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            super.keyDown(with: event)
            return
        }

        searchField.focus(in: window)
        searchField.insertText(characters)
    }

    fileprivate func searchDidChange() {
        cancelDragInteraction(animated: false)
        closeFolder(animated: false)
        resetPageTransition()
        pageScrollGesture = PageScrollGesture()
        currentPage = 0
        selectedIndex = -1
        invalidatePageSurfaceCache()
        needsLayout = true
    }

    fileprivate func requestClose() {
        // The Folder -> root ownership handoff is not a user dismissal gesture.
        // Ignore any transient click-through/activation side effect until the
        // committed root surface owns both visuals and AppKit hit targets.
        guard !suppressesResignActiveDismissal else { return }
        cancelDragInteraction(animated: false)
        (window as? LaunchpadWindow)?.dismiss()
    }

    fileprivate func confirmResetLaunchpad() {
        guard !isResettingLayout, !isPageTransitionActive, dragSession == nil, !isCommittingLayout,
            !isFinishingDragVisuals, let window
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

    fileprivate func resetLaunchpad() async {
        cancelDragInteraction(animated: false)
        closeFolder(animated: false)
        searchField.resetForPresentation()
        window?.makeFirstResponder(self)
        setPageHitTargetsEnabled(false)
        let discovery = await catalog.refreshOutcome()
        do {
            let resetDocument = try await layoutStore.reset(
                applications: discovery.applications, completeness: discovery.completeness)
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

    fileprivate func presentResetFailure(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launchpad Couldn’t Be Reset"
        if error as? LauncherLayoutStoreError == .incompleteCatalogForReset {
            alert.informativeText =
                "The application scan was incomplete, so your current layout was kept unchanged. "
                + "Try again in a moment."
        } else {
            alert.informativeText = "Your current layout was kept unchanged."
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

extension LaunchpadRootView {
    fileprivate func tilePointerDown(entry: LaunchpadPageEntry?, event: NSEvent) {
        guard let entry, !isSearchActive, openFolderID == nil, !isPageTransitionActive, !isCommittingLayout,
            !isFinishingDragVisuals, dragInteraction.pointerDown(on: entry.item.id)
        else { return }

        pendingPress = PendingTilePress(entry: entry, point: convert(event.locationInWindow, from: nil))

        animatePressed(on: entry.iconLayer, isPressed: true)
    }

    fileprivate func tilePointerDragged(_ update: TilePointerDragUpdate) {
        guard update.hasExceededActivationDistance else { return }
        let point = convert(update.event.locationInWindow, from: nil)
        if dragSession == nil { beginDragInteraction(at: point) }
        updateDragInteraction(at: point)
    }

    fileprivate func tilePointerUp(_ release: TilePointerRelease) {
        defer { pendingPress = nil }
        guard release.wasDrag else {
            if let pendingPress { animatePressed(on: pendingPress.entry.iconLayer, isPressed: false) }

            dragInteraction.finish()
            return
        }
        completeDragInteraction(at: convert(release.event.locationInWindow, from: nil))
    }

    fileprivate func tilePointerCancelled() {
        if dragSession != nil {
            cancelDragInteraction()
        } else {
            if let pendingPress { animatePressed(on: pendingPress.entry.iconLayer, isPressed: false) }

            pendingPress = nil
            dragInteraction.finish()
        }
    }

    fileprivate func beginDragInteraction(at point: CGPoint) {
        guard let pendingPress, let originalSurface = activeSurface, dragInteraction.beginDragging(),
            let draft = try? LauncherLayoutDraft(
                document: layoutDocument.normalizedForPageCapacity(currentMetrics?.itemsPerPage ?? 1))
        else { return }

        cancelIconPrewarming()

        let pointerOffset = CGVector(
            dx: pendingPress.point.x - pendingPress.entry.frames.cell.midX,
            dy: pendingPress.point.y - pendingPress.entry.frames.cell.midY)

        let proxyLayer = makeDragProxy(for: pendingPress.entry, initialPoint: pendingPress.point)

        let session = LaunchpadDragSession(
            sourceEntry: pendingPress.entry, draft: draft, proxyLayer: proxyLayer, pointerOffset: pointerOffset,
            originalSurface: originalSurface, sourcePage: currentPage)

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
        DragProxyPresentation.animateDragLift(
            proxyLayer, from: pendingPress.entry.frames.cell.center, to: point, offset: pointerOffset)
        CATransaction.commit()
    }

    fileprivate func updateDragInteraction(at point: CGPoint, allowsEdgePaging: Bool = true) {
        guard let session = dragSession else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.proxyLayer.position = CGPoint(
            x: point.x - session.pointerOffset.dx, y: point.y - session.pointerOffset.dy)
        CATransaction.commit()
        session.lastPointerPoint = point
        guard !session.isEdgePageTransitionActive else { return }

        // Once native-style folder creation has opened the provisional folder,
        // root-page reorder/edge logic is suspended. The drag proxy remains the
        // only moving visual and continues to follow the original pointer owner.
        if session.folderCreationPreview != nil { return }

        if allowsEdgePaging && !session.hasReleased { updateDragEdgePaging(at: point, session: session) }
        // An edge is outside the icon grid, but a page already reached by this
        // drag has a valid landing slot. Keep it valid even on the first/last page.
        if session.hasCrossedPages, let metrics = currentMetrics, dragEdgeDirection(at: point,
            metrics: metrics) != nil {
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

        updateDragIntent(session)
    }

    fileprivate func updateDragIntent(_ session: LaunchpadDragSession) {
        let hits = dragHitTargets(session)
        let candidate = hits.merge ?? (hits.insertion == .outside ? nil : hits.insertion)
        let generation = session.intentState.generation
        let decision = session.intentState.update(
            candidate: candidate, at: CACurrentMediaTime(),
            // Movement toward an icon must reach its merge zone before a
            // gutter insertion can displace it. Stationary timer samples do not
            // restart the dwell, preserving deliberate reorder holds.
            restartDwell: candidate?.isInsertion == true && hits.isMovingTowardMerge)
        session.previousIntentIconFrame = draggedIconFrame(for: session)
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
            if case .ready(let ready) = decision, !ready.isInsertion { target = ready } else { target = hits.insertion }
            applyDragPreviewTarget(target, session: session)
            return
        }

        switch decision {
        case .hold:
            // Do not materialize the insertion fallback while acquiring a
            // folder, even when this drag has not created its first preview.
            let heldTarget: LauncherDropTarget =
                session.previewLocation.map { .pageInsertion(page: $0.page, index: $0.index) } ?? .outside
            setDragTarget(candidate == nil ? .outside : heldTarget, session: session)
            scheduleDragIntent(session)
        case .ready(let target):
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

    // LAUNCHPANE_NATIVE_FOLDER_CREATION_V2
    @discardableResult fileprivate func beginFolderCreationPreview(
        _ target: LauncherDropTarget, session: LaunchpadDragSession
    ) -> Bool {
        guard session.folderCreationPreview == nil, case .application(let sourceIdentity) = session.sourceEntry.item.id
        else { return false }

        let surface = session.previewSurface ?? activeSurface
        let targetFrame: CGRect? = {
            guard let surface else { return nil }
            return surface.entries.first { entry in
                switch target {
                case .application(let identity): return entry.item.id == .application(identity)
                case .folder(let folderID): return entry.item.id == .folder(folderID)
                case .insertion, .pageInsertion, .outside: return false
                }
            }.map { visibleIconFrame(for: $0) }
        }()

        let folderID: UUID
        do {
            switch target {
            case .application(let targetIdentity):
                folderID = UUID()
                try session.draft.mergeApplications(
                    source: sourceIdentity, target: targetIdentity, folderID: folderID, customTitle: "Untitled")
            case .folder(let existingFolderID):
                folderID = existingFolderID
                try session.draft.addApplication(sourceIdentity, toFolder: existingFolderID)
            case .insertion, .pageInsertion, .outside: return false
            }
        } catch { return false }

        session.intentTask?.cancel()
        session.intentTask = nil
        session.folderSpringOpenTask?.cancel()
        session.folderSpringOpenTask = nil
        setDragTarget(target, session: session)
        session.folderCreationPreview = FolderCreationPreview(
            folderID: folderID, target: target, sourceIdentity: sourceIdentity)
        folderHiddenApplicationID = sourceIdentity

        folderPresentation.folderAnimationSourceFrame = targetFrame
        openFolderID = folderID
        folderPaging.selectPage(0, selectedIndex: -1)
        folderPaging.scrollGesture = PageScrollGesture()
        searchField.isHidden = true
        setPageHitTargetsEnabled(false, preserving: session.sourceEntry.button)
        setFolderBackgroundVisible(true, animated: true)
        renderFolderOverlay(animated: true)
        return true
    }

    fileprivate func applyDragPreviewTarget(_ target: LauncherDropTarget, session: LaunchpadDragSession) {
        if case .pageInsertion(let page, let index) = target, let metrics = currentMetrics {
            updateDragPreviewLayout(
                session, location: DragPageLocation(page: page, index: index), animated: true, metrics: metrics)
        }
        setDragTarget(target, session: session)
    }

    fileprivate func setDragTarget(_ target: LauncherDropTarget, session: LaunchpadDragSession) {
        session.target = target
        _ = dragInteraction.update(target: target)
        updateDropHighlight(target)
    }

    fileprivate func clearDragIntent(_ session: LaunchpadDragSession) {
        session.intentTask?.cancel()
        session.intentTask = nil
        session.folderSpringOpenTask?.cancel()
        session.folderSpringOpenTask = nil
        session.intentState.reset()
    }

    fileprivate func scheduleDragIntent(_ session: LaunchpadDragSession) {
        guard session.intentTask == nil, let deadline = session.intentState.deadline, !session.hasReleased else {
            return
        }
        let generation = session.intentState.generation
        session.intentTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .seconds(max(0, deadline - CACurrentMediaTime())))
            guard !Task.isCancelled, let self, let session, self.dragSession === session, !session.hasReleased,
                !session.isEdgePageTransitionActive, session.intentState.generation == generation
            else { return }

            session.intentTask = nil
            // Re-sample visible target geometry: an in-flight reflow may have
            // moved it since the last pointer event. Time alone cannot arm it.
            self.updateDragInteraction(at: session.lastPointerPoint)
        }
    }

    fileprivate func scheduleFolderSpringOpen(_ target: LauncherDropTarget, session: LaunchpadDragSession) {
        guard session.folderCreationPreview == nil, session.folderSpringOpenTask == nil, !session.hasReleased,
            !session.isEdgePageTransitionActive, session.intentState.isReady, session.intentState.candidate == target,
            let beganAt = session.intentState.beganAt, !target.isInsertion, target != .outside
        else { return }

        let generation = session.intentState.generation
        let deadline = beganAt + FolderSpringOpenMetrics.dwell
        session.folderSpringOpenTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .seconds(max(0, deadline - CACurrentMediaTime())))
            guard !Task.isCancelled, let self, let session, self.dragSession === session, !session.hasReleased,
                !session.isEdgePageTransitionActive, session.folderCreationPreview == nil,
                session.intentState.generation == generation, session.intentState.isReady,
                session.intentState.candidate == target, self.dragHitTargets(session).merge == target
            else { return }

            session.folderSpringOpenTask = nil
            _ = self.beginFolderCreationPreview(target, session: session)
        }
    }

    enum DragEdgeMetrics {
        // LAUNCHPANE_ADAPTIVE_EDGE_PAGING_ZONE_V11
        //
        // Keep edge paging proportional to the current logical display width.
        // Previously the 4% rule was capped at only 96pt, which meant a native
        // 3840pt-wide 4K display received the same narrow zone as much smaller
        // displays. A 192pt ceiling preserves the existing 4% behaviour on
        // normal displays while allowing large canvases to scale naturally.
        //
        // Examples:
        //   1710pt ->  68.4pt
        //   1920pt ->  76.8pt
        //   2560pt -> 102.4pt
        //   3008pt -> 120.3pt
        //   3440pt -> 137.6pt
        //   3840pt -> 153.6pt
        static let minimumWidth: CGFloat = 56
        static let maximumWidth: CGFloat = 192
        static let widthFraction: CGFloat = 0.04
        static let dwell: Duration = .milliseconds(400)
        static let pageDuration: CFTimeInterval = 0.45
    }

    // LAUNCHPANE_FOLDER_DRAG_EDGE_PAGING_V18
    // Folder-local drag paging deliberately uses the Folder panel rather than
    // the full display. The hot zone scales with the panel so native 4K gets a
    // comfortably larger target while smaller displays keep the same feel.
    private enum FolderDragEdgePagingMetrics {
        static let minimumWidth: CGFloat = 88
        static let maximumWidth: CGFloat = 176
        static let widthFraction: CGFloat = 0.08
        static let minimumExitGrace: CGFloat = 18
        static let maximumExitGrace: CGFloat = 30
        static let exitGraceFraction: CGFloat = 0.015
        static let dwell: Duration = .milliseconds(350)
        static let settlePoll: Duration = .milliseconds(8)
    }

    private enum FolderSpringOpenMetrics {
        // Total stable overlap before spring-loading the folder. The shorter
        // LauncherDragIntentState merge dwell only arms a closed-folder drop.
        // LAUNCHPANE_FOLDER_SPRING_OPEN_DWELL_100_V2
        static let dwell: TimeInterval = 1.0
    }

    fileprivate func dragEdgeDirection(at point: CGPoint, metrics: GridMetrics) -> Int? {
        let edgeWidth = min(
            DragEdgeMetrics.maximumWidth,
            max(DragEdgeMetrics.minimumWidth, bounds.width * DragEdgeMetrics.widthFraction))
        guard point.y >= metrics.contentFrame.minY, point.y <= metrics.contentFrame.maxY, point.x >= bounds.minX,
            point.x <= bounds.maxX
        else { return nil }
        if point.x <= bounds.minX + edgeWidth { return metrics.isRightToLeft ? 1 : -1 }
        if point.x >= bounds.maxX - edgeWidth { return metrics.isRightToLeft ? -1 : 1 }
        return nil
    }

    fileprivate func updateDragEdgePaging(at point: CGPoint, session: LaunchpadDragSession) {
        guard let metrics = currentMetrics, !session.isEdgePageTransitionActive, !session.hasReleased else { return }
        let direction = dragEdgeDirection(at: point, metrics: metrics)
        // Existing pages may be traversed freely. Offer one temporary trailing
        // page, not an unbounded train of empty pages while the pointer rests.
        let existingCount = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage).pages
            .count
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
            guard !Task.isCancelled, let self, let session, self.dragSession === session, !session.hasReleased,
                !session.isEdgePageTransitionActive, session.edgePagingDirection == direction,
                let metrics = self.currentMetrics,
                self.dragEdgeDirection(at: session.lastPointerPoint, metrics: metrics) == direction
            else { return }
            session.edgePagingTask = nil
            self.performDragEdgePageTurn(direction: direction, session: session)
        }
    }

    func projectedDocument(
        _ session: LaunchpadDragSession, location: DragPageLocation, metrics: GridMetrics
    ) -> LauncherLayoutDocument? {
        guard var draft = try? LauncherLayoutDraft(document: session.projectionBaselineDocument) else { return nil }
        do {
            try draft.moveRootItem(
                session.sourceEntry.item.id, toPage: location.page, at: location.index,
                pageCapacity: metrics.itemsPerPage)
            return draft.document
        } catch { return nil }
    }

    fileprivate func performDragEdgePageTurn(direction: Int, session: LaunchpadDragSession) {
        guard dragSession === session, !session.hasReleased, !session.isEdgePageTransitionActive,
            let metrics = currentMetrics, let outgoing = session.previewSurface ?? activeSurface
        else { return }
        let baseline = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage)
        let targetPage = currentPage + direction
        guard (0...baseline.pages.count).contains(targetPage) else { return }
        let targetItems = baseline.pages.indices.contains(targetPage) ? baseline.pages[targetPage] : []
        let sourceID = session.sourceEntry.item.id
        let targetCount = targetItems.filter { item in
            switch (item, sourceID) {
            case (.application(let ref), .application(let id)): return ref.identity != id
            case (.folder(let folder), .folder(let id)): return folder.id != id
            default: return true
            }
        }.count
        // Reserve an actual slot on a full page, so the dragged app stays here;
        // the previous final app overflows forward. A partial page may append.
        let location = DragPageLocation(
            page: targetPage, index: direction > 0 ? min(targetCount, metrics.itemsPerPage - 1) : 0)
        guard let document = projectedDocument(session, location: location, metrics: metrics) else { return }
        let projection = pageProjection(metrics: metrics, document: document)
        let scale = window?.backingScaleFactor ?? 1
        let incoming = makePageSurface(
            pageIndex: targetPage, items: projection.items, metrics: metrics, scale: scale, projection: projection)
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

        let transition = prepareDragEdgeTransition(
            outgoing: outgoing, incoming: incoming, metrics: metrics, direction: direction)
        let finish: @MainActor () -> Void = { [weak self, weak session] in
            guard let self, let session, self.dragSession === session, session.edgeGeneration == generation else {
                return
            }
            self.finishDragEdgeTransition(
                session, transition: transition, pageCount: projection.pageCount, scale: scale)
        }
        animateDragEdgeTransition(transition, finish: finish)
    }

    fileprivate struct DragEdgeTransition {
        let outgoing: LaunchpadPageSurface
        let incoming: LaunchpadPageSurface
        let metrics: GridMetrics
        let resting: CGPoint
        let distance: CGFloat
    }

    fileprivate func prepareDragEdgeTransition(
        outgoing: LaunchpadPageSurface, incoming: LaunchpadPageSurface, metrics: GridMetrics, direction: Int
    ) -> DragEdgeTransition {
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

        return DragEdgeTransition(
            outgoing: outgoing, incoming: incoming, metrics: metrics, resting: resting, distance: distance)
    }

    fileprivate func finishDragEdgeTransition(
        _ session: LaunchpadDragSession, transition: DragEdgeTransition, pageCount: Int, scale: CGFloat
    ) {
        let outgoing = transition.outgoing
        let incoming = transition.incoming
        let resting = transition.resting
        let targetPage = incoming.pageIndex
        let metrics = transition.metrics
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
        self.updatePageIndicator(pageCount: pageCount, metrics: metrics, scale: scale)
        if let point = session.pendingCompletionPoint {
            session.pendingCompletionPoint = nil
            self.completeDragInteraction(at: point)
        } else {
            // Re-arm from this page; no exit/re-entry requirement.
            self.updateDragInteraction(at: session.lastPointerPoint)
        }
    }

    fileprivate func animateDragEdgeTransition(
        _ transition: DragEdgeTransition, finish: @escaping @MainActor () -> Void
    ) {
        let outgoing = transition.outgoing
        let incoming = transition.incoming
        let resting = transition.resting
        let distance = transition.distance
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }
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

    func visibleIconFrame(for entry: LaunchpadPageEntry) -> CGRect {
        let visibleCenter = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position
        return entry.frames.icon.offsetBy(
            dx: visibleCenter.x - entry.frames.cell.midX, dy: visibleCenter.y - entry.frames.cell.midY)
    }

    fileprivate func draggedIconFrame(for session: LaunchpadDragSession) -> CGRect {
        let frames = session.originalFramesByIdentifier[session.sourceEntry.item.id] ?? session.sourceEntry.frames
        // The dragged end follows this event, not last frame's presentation.
        // Immutable grab geometry also survives in-place reflow and page turns.
        let center = CGPoint(
            x: session.lastPointerPoint.x - session.pointerOffset.dx,
            y: session.lastPointerPoint.y - session.pointerOffset.dy)
        return frames.icon.offsetBy(dx: center.x - frames.cell.midX, dy: center.y - frames.cell.midY)
    }
    private func dragHitTargets(_ session: LaunchpadDragSession) -> DragTargetResolver.Result {
        guard let metrics = currentMetrics else { return DragTargetResolver.Result(insertion: .outside, merge: nil) }
        let source = session.sourceEntry
        let draggedFrame = draggedIconFrame(for: session)
        let insertion = dragInsertionTarget(session, draggedFrame: draggedFrame, metrics: metrics)

        guard case .application = source.item, let surface = session.previewSurface ?? activeSurface else {
            return DragTargetResolver.Result(insertion: insertion, merge: nil)
        }
        let targets = surface.entries.filter { $0.item.id != source.item.id && $0.tileLayer.superlayer != nil }.map {
            let iconFrame = visibleIconFrame(for: $0)
            let cellFrame = $0.frames.cell.offsetBy(
                dx: iconFrame.midX - $0.frames.icon.midX, dy: iconFrame.midY - $0.frames.icon.midY)
            return FolderMergeGeometry.Target(id: $0.item.id, iconFrame: iconFrame, cellFrame: cellFrame)
        }
        return DragTargetResolver.resolveMerge(
            insertion: insertion,
            motion: .init(icon: draggedFrame, previousIcon: session.previousIntentIconFrame),
            candidate: session.intentState.candidate, targets: targets)
    }

    fileprivate func dragInsertionTarget(_ session: LaunchpadDragSession, draggedFrame: CGRect, metrics: GridMetrics)
        -> LauncherDropTarget {
        let source = session.sourceEntry
        let point = draggedFrame.center
        let baseline = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage)
        let pageItems = baseline.pages.indices.contains(currentPage) ? baseline.pages[currentPage] : []
        let pageIDs = pageItems.map { item -> LauncherLayoutItemIdentifier in
            switch item {
            case .application(let reference): return .application(reference.identity)
            case .folder(let folder): return .folder(folder.id)
            }
        }
        guard metrics.contentFrame.contains(point),
            let rawSlot = (0..<metrics.itemsPerPage).first(where: {
                metrics.cellFrame(forItemAt: $0)?.contains(point) == true
            }) else { return .outside }
        let surface = session.previewSurface ?? session.originalSurface
        let sourceCenter = surface.entries.first(where: { $0.item.id == source.item.id })?.frames.cell.center
        let projection = pageProjection(metrics: metrics, document: baseline)
        let visibleIDs = projection.pages.indices.contains(currentPage) ? projection.pages[currentPage].map(\.id) : []
        let context = DragTargetResolver.InsertionContext(
            source: source.item.id, page: currentPage,
            activeDragPage: session.previewLocation?.page ?? session.sourcePage,
            sourceCenter: sourceCenter, pageIdentifiers: pageIDs, visibleIdentifiers: visibleIDs, metrics: metrics)
        return DragTargetResolver.resolveInsertion(rawSlot: rawSlot, draggedIcon: draggedFrame, context: context)
    }

    fileprivate func completeDragInteraction(at point: CGPoint) {
        guard let dragSession else {
            dragInteraction.finish()
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
            // LAUNCHPANE_SPRING_OPEN_COMMIT_LOCK_V1
            // Spring-open is the irreversible mouse-up intent boundary.
            //
            // beginFolderCreationPreview() has already mutated the draft by
            // inserting/merging the source App into this Folder, and
            // updateDragInteraction() deliberately suspends root reorder/edge
            // logic while folderCreationPreview exists. Re-checking the current
            // pointer against folderPresentation.folderPanelFrame here created a contradictory
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
        guard dragSession.draft.hasChanges, dragInteraction.beginCommit() else {
            cancelDragInteraction()
            return
        }

        let committingSession = dragSession
        let draft = committingSession.draft
        let commitContext = LaunchpadDragCommitContext(session: committingSession)
        dragCommit.begin(commitContext)
        isCommittingLayout = true
        finishDragVisuals(dragSession, committed: true, animated: true) { [weak self, weak commitContext] in
            guard let self, let commitContext else { return }
            dragCommit.markVisualsFinished(commitContext)
            finishDragCommitIfReady(commitContext)
        }
        self.dragSession = nil
        pendingPress = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            await persistDragCommit(commitContext, draft: draft)
        }
    }

    func refreshCommittedPageCacheForCrossPageMergeIfNeeded(
        _ session: LaunchpadDragSession, keeping previewSurface: LaunchpadPageSurface, metrics: GridMetrics
    ) {
        guard session.hasCrossedPages else { return }

        switch session.target {
        case .application, .folder: break
        case .insertion, .pageInsertion, .outside: return
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
            guard pageIndex != currentPage || surface !== previewSurface else { continue }
            detachButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.opacity = 0
            surface.layer.isHidden = true
            surface.layer.removeFromSuperlayer()
        }

        var refreshedSurfaces: [Int: LaunchpadPageSurface] = [:]
        refreshedSurfaces.reserveCapacity(pageCount)

        for pageIndex in 0..<pageCount {
            if pageIndex == currentPage {
                refreshedSurfaces[pageIndex] = previewSurface
            } else {
                refreshedSurfaces[pageIndex] = makePageSurface(
                    pageIndex: pageIndex, items: items, metrics: metrics, scale: scale, projection: projection)
            }
        }

        pageSurfaces = refreshedSurfaces
        activeSurface = previewSurface
        pageContentLayer = previewSurface.layer

        updatePageIndicator(pageCount: pageCount, metrics: metrics, scale: scale)
    }

    func adoptCommittedPreviewIfPossible(_ session: LaunchpadDragSession) -> Bool {
        let canAdoptTarget: Bool
        switch session.target {
        case .insertion, .pageInsertion, .application, .folder: canAdoptTarget = true
        case .outside: canAdoptTarget = false
        }

        guard canAdoptTarget, let previewSurface = session.previewSurface, let metrics = currentMetrics else {
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

        guard pageSurfaces.count == pageCount else { return false }

        for pageIndex in 0..<pageCount {
            let candidateSurface: LaunchpadPageSurface? =
                pageIndex == currentPage ? previewSurface : pageSurfaces[pageIndex]

            guard let candidateSurface else { return false }

            let range = projection.range(forPage: pageIndex)
            let startIndex = range.lowerBound
            let endIndex = range.upperBound

            let expectedIDs: [LauncherLayoutItemIdentifier]

            if startIndex < endIndex { expectedIDs = items[startIndex..<endIndex].map(\.id) } else { expectedIDs = [] }

            // `entries` intentionally keeps object identity while tiles reflow,
            // so array order itself is not authoritative. `absoluteIndex` is.
            let actualIDs = candidateSurface.entries.sorted { $0.absoluteIndex < $1.absoluteIndex }.map { $0.item.id }

            guard actualIDs == expectedIDs else { return false }
        }

        // The live preview is already the committed page.
        //
        // Rebuilding here would create another CALayer tree containing the same
        // icons while the preview's presentation tree is still retiring.
        if let cachedSurface = pageSurfaces[currentPage], cachedSurface !== previewSurface {
            detachButtons(from: cachedSurface)

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            cachedSurface.layer.removeAllAnimations()

            cachedSurface.layer.opacity = 0

            cachedSurface.layer.isHidden = true

            cachedSurface.layer.removeFromSuperlayer()

            CATransaction.commit()
        }

        pageSurfaces[currentPage] = previewSurface

        activeSurface = previewSurface

        pageContentLayer = previewSurface.layer

        // A commit is allowed to replace the root surface while a spring-open
        // Folder is still on screen, but it must NOT change who owns the stage.
        // Apply the Folder visibility rule to the newly adopted surface before
        // returning so there is no one-frame root-grid flash.
        setFolderBackgroundVisible(openFolderID != nil, animated: false)
        setPageHitTargetsEnabled(openFolderID == nil)

        return true
    }

    fileprivate func applyDropTarget(_ target: LauncherDropTarget, to session: LaunchpadDragSession) throws {
        switch target {
        case .pageInsertion(let page, let index):
            try session.draft.moveRootItem(
                session.sourceEntry.item.id, toPage: page, at: index, pageCapacity: currentMetrics?.itemsPerPage ?? 1)
        case .insertion(let destination):
            try session.draft.moveRootItem(session.sourceEntry.item.id, toPositionOf: destination)
        case .application(let targetIdentity):
            guard case .application(let sourceIdentity) = session.sourceEntry.item.id else { return }
            try session.draft.mergeApplications(source: sourceIdentity, target: targetIdentity, customTitle: "Untitled")
        case .folder(let folderID):
            guard case .application(let sourceIdentity) = session.sourceEntry.item.id else { return }
            try session.draft.addApplication(sourceIdentity, toFolder: folderID)
        case .outside: return
        }
    }

    fileprivate func cancelDragInteraction(animated: Bool = true) {
        pendingPress = nil

        if folderItemDragSession != nil {
            cancelFolderItemDragBeforeExit(animated: animated)
            return
        }

        guard !isFinishingDragVisuals else { return }
        guard let dragSession else {
            if dragInteraction.state != .idle {
                _ = dragInteraction.beginRollback()
                dragInteraction.finish()
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

        if dragSession.folderCreationPreview != nil { closeFolder(animated: false) }

        _ = dragInteraction.beginRollback()
        dragSession.draft.rollback()
        isFinishingDragVisuals = true
        if dragSession.hasCrossedPages {
            finishCrossPageRollback(dragSession, animated: animated) { [weak self] in
                guard let self else { return }
                isFinishingDragVisuals = false
                dragInteraction.finish()
                setPageHitTargetsEnabled(true)
                needsLayout = true
            }
            self.dragSession = nil
            return
        }
        setPageHitTargetsEnabled(false)
        finishDragVisuals(dragSession, committed: false, animated: animated) { [weak self] in
            guard let self else { return }
            isFinishingDragVisuals = false
            dragInteraction.finish()
            setPageHitTargetsEnabled(true)
            needsLayout = true
        }
        self.dragSession = nil
    }

    /// Refresh the steady-state icon backing store before landing. The label is
    /// a separate child layer, so its merge fade can never leave a spatial ghost.

}

extension LaunchpadRootView {
    // MARK: - Folder child drag -> root drag handoff

    func folderItemPointerDown(
        folderID: UUID, absoluteIndex: Int, frames: GridItemFrames,
        presentation: AppTilePresentation, event: NSEvent
    ) {
        let application = presentation.button.application
        guard openFolderID == folderID, dragSession == nil, folderItemDragSession == nil, !isCommittingLayout,
            !isFinishingDragVisuals, dragInteraction.pointerDown(on: .application(application.id))
        else { return }

        if folderPresentation.folderTitleEditor != nil { finishFolderTitleEditing(commit: true) }

        let entry = LaunchpadPageEntry(
            item: .application(application), absoluteIndex: absoluteIndex, frames: frames,
            presentation: .application(presentation))
        pendingFolderPress = PendingFolderTilePress(
            folderID: folderID, entry: entry, point: convert(event.locationInWindow, from: nil))
        animatePressed(on: entry.iconLayer, isPressed: true)
    }

    func folderItemPointerDragged(_ update: TilePointerDragUpdate) {
        let point = convert(update.event.locationInWindow, from: nil)

        if let session = dragSession, session.sourceOrigin.folderID != nil {
            updateDragInteraction(at: point)
            return
        }

        guard update.hasExceededActivationDistance else { return }
        if folderItemDragSession == nil { beginFolderItemDrag(at: point) }
        updateFolderItemDrag(at: point)
    }

    // LAUNCHPANE_FOLDER_POINTER_RELEASE_OWNERSHIP_V20
    //
    // A Folder child can remain the AppKit mouse owner even after its visual
    // presentation has been replaced by a root preview. Never remove that
    // NSView synchronously from inside its own mouseUp/cancel callback. AppKit
    // is still unwinding the event dispatch stack at that point. Hide/disable
    // it immediately, then retire the view on the next MainActor turn.
    func retireFolderTrackingButtonAfterPointerCallback(_ button: PointerTrackingTileButton) {
        dragInteraction.retireAfterPointerCallback(button)
    }

    func retireFolderExtractionPointerOwnerAfterCommit(_ session: LaunchpadDragSession) {
        guard session.sourceOrigin.folderID != nil else { return }

        // The Folder-owned AppKit view is intentionally retained beyond
        // mouseUp. Root landing and layout persistence can continue to use
        // the source session for several frames, and releasing the last
        // pointer owner before that handoff completes can transiently
        // deactivate the accessory app. Retire it only when the root commit
        // has reached its final presentation state.
        let pointerOwner = dragInteraction.preservedButton ?? (session.sourceEntry.button as? AppTileButton)

        guard let pointerOwner else {
            dragInteraction.endExtraction()
            return
        }

        // Use the same retirement path as Folder-local reorder. Keeping the
        // preserved owner alive through removal plus one extra main turn
        // closes both extraction and in-Folder release races with one invariant.
        retireFolderTrackingButtonAfterPointerCallback(pointerOwner)
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

            // LAUNCHPANE_FOLDER_EXTRACTION_ACTIVATION_SHIELD_V21
            // Do not retire the Folder-owned pointer view here. The root drag
            // commit is still landing/persisting after mouseUp returns. Keep a
            // hidden, disabled ownership sentinel until finishDragCommitIfReady()
            // finalizes the root presentation.
            trackingButton.isEnabled = false
            trackingButton.isHidden = true
            return
        }

        if let context = folderItemDragSession {
            let center = CGPoint(x: point.x - context.pointerOffset.dx, y: point.y - context.pointerOffset.dy)
            context.lastPointerPoint = point
            context.lastProxyCenter = center

            // LAUNCHPANE_FOLDER_DRAG_EDGE_PAGING_V18
            // mouseUp can arrive while the edge-triggered page is still
            // settling. AppKit has already completed pointer tracking, so
            // retain the release point and commit only after the new page is
            // stationary. This avoids landing against a moving surface.
            if context.isEdgePageTurnInFlight || folderPaging.animator.isAnimating {
                context.pendingReleasePoint = point
                context.edgePagingDirection = nil
                return
            }

            cancelFolderItemDragEdgePaging(context)
            if folderPresentation.folderPanelFrame.contains(center) {
                completeFolderItemReorder(context, at: center)
            } else {
                cancelFolderItemDragBeforeExit(animated: true)
            }
            return
        }

        if let pendingFolderPress { animatePressed(on: pendingFolderPress.entry.iconLayer, isPressed: false) }
        dragInteraction.finish()
    }

    func folderItemPointerCancelled() {
        if let session = dragSession, session.sourceOrigin.folderID != nil {
            // cancelDragInteraction() owns Folder-extraction teardown. It now
            // retires the pointer owner after this cancellation callback exits.
            cancelDragInteraction()
            return
        }
        if let context = folderItemDragSession {
            cancelFolderItemDragEdgePaging(context)
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }
        if let pendingFolderPress { animatePressed(on: pendingFolderPress.entry.iconLayer, isPressed: false) }
        pendingFolderPress = nil
        dragInteraction.finish()
    }

    fileprivate func beginFolderItemDrag(at point: CGPoint) {
        guard let pendingFolderPress, let sourceButton = pendingFolderPress.entry.button as? AppTileButton,
            let sourceTileParent = pendingFolderPress.entry.tileLayer.superlayer,
            let sourceFolder = resolvedFolder(id: pendingFolderPress.folderID), dragInteraction.beginDragging()
        else { return }

        let sourceTileIndex =
            sourceTileParent.sublayers?.firstIndex(where: { $0 === pendingFolderPress.entry.tileLayer })
            ?? (sourceTileParent.sublayers?.count ?? 0)
        let pointerOffset = CGVector(
            dx: pendingFolderPress.point.x - pendingFolderPress.entry.frames.cell.midX,
            dy: pendingFolderPress.point.y - pendingFolderPress.entry.frames.cell.midY)
        let proxy = makeDragProxy(for: pendingFolderPress.entry, initialPoint: pendingFolderPress.point)
        let context = FolderItemDragSession(
            folderID: pendingFolderPress.folderID, sourceEntry: pendingFolderPress.entry, proxyLayer: proxy,
            pointerOffset: pointerOffset, trackingButton: sourceButton,
            sourceAbsoluteIndex: pendingFolderPress.entry.absoluteIndex,
            baselineApplications: sourceFolder.applications, sourcePage: folderPaging.page,
            sourceTileParent: sourceTileParent,
            sourceTileIndex: sourceTileIndex)
        folderItemDragSession = context
        context.lastPointerPoint = point
        context.lastProxyCenter = CGPoint(x: point.x - context.pointerOffset.dx, y: point.y - context.pointerOffset.dy)

        // A Folder page turn may retire the presentation surface that
        // originally owned mouseDown. Preserve that exact AppKit button for
        // the entire drag and hide the source identity from any page surface
        // rebuilt while we travel across pages.
        dragInteraction.preserve(sourceButton)
        if case .application(let application) = pendingFolderPress.entry.item {
            folderHiddenApplicationID = application.id
        }

        // Proxy acquisition and source detachment happen in one display
        // transaction. The folder never renders a duplicate source app and
        // the detached source remains fully opaque for later release snapshots.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragOverlayLayer.addSublayer(proxy)
        pendingFolderPress.entry.tileLayer.opacity = 1
        pendingFolderPress.entry.tileLayer.removeFromSuperlayer()
        DragProxyPresentation.animateDragLift(
            proxy, from: pendingFolderPress.entry.frames.cell.center, to: point, offset: pointerOffset)
        CATransaction.commit()
    }

    fileprivate func updateFolderItemDrag(at point: CGPoint) {
        guard let context = folderItemDragSession else { return }
        let center = CGPoint(x: point.x - context.pointerOffset.dx, y: point.y - context.pointerOffset.dy)
        context.lastPointerPoint = point
        context.lastProxyCenter = center

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.proxyLayer.position = center
        CATransaction.commit()

        // LAUNCHPANE_FOLDER_DRAG_EDGE_PAGING_V18
        // During the short page transition, the drag proxy remains the
        // pointer-owned foreground object. Do not reinterpret transient
        // positions as extraction/reorder until the new page has settled.
        if context.isEdgePageTurnInFlight || folderPaging.animator.isAnimating { return }

        if updateFolderItemDragEdgePaging(at: center, context: context) { return }

        guard let geometry = folderReorderGeometry() else {
            promoteFolderItemDragToRoot(context, at: point)
            return
        }

        // Give edge paging a small horizontal ownership grace outside the
        // rounded panel. This prevents tiny pointer overshoot from turning a
        // deliberate page gesture into a Folder -> Root extraction. Vertical
        // exits remain immediate.
        if folderDragRetentionFrame(metrics: geometry.metrics).contains(center) {
            if folderPresentation.folderPanelFrame.contains(center) {
                updateFolderItemDragDestination(at: center, context: context)
            }
            return
        }

        cancelFolderItemDragEdgePaging(context)
        promoteFolderItemDragToRoot(context, at: point)
    }

    fileprivate func folderDragEdgeWidth(metrics: FolderGridMetrics) -> CGFloat {
        min(
            FolderDragEdgePagingMetrics.maximumWidth,
            max(
                FolderDragEdgePagingMetrics.minimumWidth,
                metrics.panelFrame.width * FolderDragEdgePagingMetrics.widthFraction))
    }

    fileprivate func folderDragHorizontalExitGrace(metrics: FolderGridMetrics) -> CGFloat {
        min(
            FolderDragEdgePagingMetrics.maximumExitGrace,
            max(
                FolderDragEdgePagingMetrics.minimumExitGrace,
                metrics.panelFrame.width * FolderDragEdgePagingMetrics.exitGraceFraction))
    }

    fileprivate func folderDragRetentionFrame(metrics: FolderGridMetrics) -> CGRect {
        let grace = folderDragHorizontalExitGrace(metrics: metrics)
        return CGRect(
            x: metrics.panelFrame.minX - grace, y: metrics.panelFrame.minY, width: metrics.panelFrame.width + grace * 2,
            height: metrics.panelFrame.height)
    }

    fileprivate func folderDragEdgeDirection(at center: CGPoint, metrics: FolderGridMetrics) -> Int? {
        let panel = metrics.panelFrame
        let grace = folderDragHorizontalExitGrace(metrics: metrics)
        guard center.y >= panel.minY, center.y <= panel.maxY, center.x >= panel.minX - grace,
            center.x <= panel.maxX + grace
        else { return nil }

        let edgeWidth = folderDragEdgeWidth(metrics: metrics)
        if center.x <= panel.minX + edgeWidth { return metrics.isRightToLeft ? 1 : -1 }
        if center.x >= panel.maxX - edgeWidth { return metrics.isRightToLeft ? -1 : 1 }
        return nil
    }

    func cancelFolderItemDragEdgePaging(_ context: FolderItemDragSession) {
        context.edgePagingGeneration &+= 1
        context.edgePagingTask?.cancel()
        context.edgePagingTask = nil
        context.edgePagingDirection = nil
        context.isEdgePageTurnInFlight = false
    }

    @discardableResult fileprivate func updateFolderItemDragEdgePaging(
        at center: CGPoint, context: FolderItemDragSession
    ) -> Bool {
        guard folderItemDragSession === context, let geometry = folderReorderGeometry(),
            geometry.folder.id == context.folderID, !context.isEdgePageTurnInFlight,
            !folderPaging.animator.isAnimating, folderPaging.swipe == nil
        else { return false }

        guard let direction = folderDragEdgeDirection(at: center, metrics: geometry.metrics) else {
            if context.edgePagingTask != nil || context.edgePagingDirection != nil {
                cancelFolderItemDragEdgePaging(context)
            }
            return false
        }

        let targetPage = folderPaging.page + direction
        guard (0..<geometry.metrics.pageCount).contains(targetPage) else {
            if context.edgePagingTask != nil || context.edgePagingDirection != nil {
                cancelFolderItemDragEdgePaging(context)
            }
            return false
        }

        guard context.edgePagingDirection != direction || context.edgePagingTask == nil else { return true }

        cancelFolderItemDragEdgePaging(context)
        context.edgePagingDirection = direction
        let generation = context.edgePagingGeneration
        context.edgePagingTask = Task { @MainActor [weak self, weak context] in
            try? await Task.sleep(for: FolderDragEdgePagingMetrics.dwell)
            guard !Task.isCancelled, let self, let context, self.folderItemDragSession === context,
                context.edgePagingGeneration == generation, context.edgePagingDirection == direction,
                !context.isEdgePageTurnInFlight, !self.folderPaging.animator.isAnimating,
                let geometry = self.folderReorderGeometry(),
                self.folderDragEdgeDirection(at: context.lastProxyCenter, metrics: geometry.metrics) == direction
            else { return }

            self.performFolderItemDragEdgePageTurn(direction: direction, context: context)
        }
        return true
    }

    fileprivate func performFolderItemDragEdgePageTurn(direction: Int, context: FolderItemDragSession) {
        guard folderItemDragSession === context, let geometry = folderReorderGeometry(),
            geometry.folder.id == context.folderID, let viewportLayer = folderPaging.viewportLayer,
            !folderPaging.animator.isAnimating, folderPaging.swipe == nil,
            let outgoing = folderPaging.surfaces[folderPaging.page]
        else { return }

        let targetPage = folderPaging.page + direction
        guard (0..<geometry.metrics.pageCount).contains(targetPage),
            let destinationAbsoluteIndex = folderDragDestinationIndexForEdgeTurn(
                direction: direction, targetPage: targetPage, context: context, metrics: geometry.metrics),
            let projected = projectedFolder(context, destinationAbsoluteIndex: destinationAbsoluteIndex)
        else {
            cancelFolderItemDragEdgePaging(context)
            return
        }

        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        let built = makeFolderPageLayer(
            folder: projected, metrics: geometry.metrics, pageIndex: targetPage, scale: scale)
        let incoming = FolderPageSurface(
            pageIndex: targetPage, layer: built.layer, presentations: built.presentations,
            applications: built.applications)
        hideFolderDragSource(in: incoming, context: context)

        context.edgePagingTask = nil
        context.edgePagingDirection = nil
        context.isEdgePageTurnInFlight = true
        context.hasCrossedPages = true
        context.edgePagingGeneration &+= 1
        let generation = context.edgePagingGeneration
        let previousDestination = context.destinationAbsoluteIndex
        context.destinationAbsoluteIndex = destinationAbsoluteIndex

        let pageStart = targetPage * geometry.metrics.itemsPerPage
        _ = dragInteraction.update(
            target: .pageInsertion(page: targetPage, index: max(0, destinationAbsoluteIndex - pageStart)))

        folderPresentation.cancelIconLoading()
        for presentation in outgoing.presentations { presentation.button.isHidden = true }

        let transition = prepareFolderDragEdgeTransition(
            outgoing: outgoing, incoming: incoming, metrics: geometry.metrics, direction: direction,
            viewportLayer: viewportLayer)
        let finish: @MainActor () -> Void = { [weak self, weak context] in
            guard let self, let context, self.folderItemDragSession === context,
                context.edgePagingGeneration == generation
            else { return }
            self.finishFolderDragEdgeTransition(
                context, transition: transition, previousDestination: previousDestination)
        }
        animateFolderDragEdgeTransition(transition, finish: finish)
    }

    fileprivate struct FolderDragEdgeTransition {
        let outgoing: FolderPageSurface
        let incoming: FolderPageSurface
        let metrics: FolderGridMetrics
        let resting: CGPoint
        let width: CGFloat
        let visualDirection: CGFloat
    }

    fileprivate func prepareFolderDragEdgeTransition(
        outgoing: FolderPageSurface, incoming: FolderPageSurface, metrics: FolderGridMetrics, direction: Int,
        viewportLayer: CALayer
    ) -> FolderDragEdgeTransition {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stalePageIndices = folderPaging.surfaces.compactMap { pageIndex, surface in
            surface === outgoing ? nil : pageIndex
        }
        for pageIndex in stalePageIndices {
            guard let surface = folderPaging.surfaces.removeValue(forKey: pageIndex) else { continue }
            detachFolderButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.removeFromSuperlayer()
        }
        let resting = metrics.panelFrame.center
        let width = max(1, metrics.panelFrame.width)
        let visualDirection = CGFloat(metrics.isRightToLeft ? -direction : direction)
        outgoing.layer.removeAllAnimations()
        outgoing.layer.position = resting
        outgoing.layer.opacity = 1
        outgoing.layer.isHidden = false
        incoming.layer.removeAllAnimations()
        incoming.layer.position = CGPoint(x: resting.x + visualDirection * width, y: resting.y)
        incoming.layer.opacity = 1
        incoming.layer.isHidden = false
        if incoming.layer.superlayer == nil { viewportLayer.addSublayer(incoming.layer) }
        CATransaction.commit()

        return FolderDragEdgeTransition(
            outgoing: outgoing, incoming: incoming, metrics: metrics, resting: resting, width: width,
            visualDirection: visualDirection)
    }

    fileprivate func finishFolderDragEdgeTransition(
        _ context: FolderItemDragSession, transition: FolderDragEdgeTransition, previousDestination: Int
    ) {
        let outgoing = transition.outgoing
        let incoming = transition.incoming
        let resting = transition.resting
        let metrics = transition.metrics
        let targetPage = incoming.pageIndex
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.layer.removeAllAnimations()
        outgoing.layer.removeFromSuperlayer()
        incoming.layer.removeAllAnimations()
        incoming.layer.position = resting
        incoming.layer.isHidden = false
        CATransaction.commit()

        self.detachFolderButtons(from: outgoing)
        self.folderPaging.surfaces.removeAll(keepingCapacity: true)
        self.folderPaging.surfaces[targetPage] = incoming
        self.folderPaging.selectPage(targetPage)
        self.folderPresentation.folderPresentations = incoming.presentations
        self.contextualizeFolderDragSurfaceButtons(incoming, context: context)
        self.updateFolderPageIndicator(pageCount: metrics.pageCount)

        context.edgePagingTask = nil
        context.edgePagingDirection = nil
        context.isEdgePageTurnInFlight = false

        self.previewFolderItemReorder(
            context, destinationAbsoluteIndex: context.destinationAbsoluteIndex,
            previousDestinationAbsoluteIndex: previousDestination, animated: false)

        if let releasePoint = context.pendingReleasePoint {
            context.pendingReleasePoint = nil
            let releaseCenter = CGPoint(
                x: releasePoint.x - context.pointerOffset.dx, y: releasePoint.y - context.pointerOffset.dy)
            if self.folderDragRetentionFrame(metrics: metrics).contains(releaseCenter) {
                self.completeFolderItemReorder(
                    context, at: self.clampedFolderDragPointToGrid(releaseCenter, metrics: metrics))
            } else {
                self.cancelFolderItemDragBeforeExit(animated: true)
            }
            return
        }

        self.updateFolderItemDrag(at: context.lastPointerPoint)
    }

    fileprivate func animateFolderDragEdgeTransition(
        _ transition: FolderDragEdgeTransition, finish: @escaping @MainActor () -> Void
    ) {
        let outgoing = transition.outgoing
        let incoming = transition.incoming
        let resting = transition.resting
        let width = transition.width
        let visualDirection = transition.visualDirection
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }

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
        let outgoingEnd = CGPoint(x: resting.x - visualDirection * width, y: resting.y)
        outgoing.layer.position = outgoingEnd
        incoming.layer.position = resting
        outgoing.layer.add(animation(resting, outgoingEnd), forKey: "folderDragEdgePageOut")
        incoming.layer.add(
            animation(CGPoint(x: resting.x + visualDirection * width, y: resting.y), resting),
            forKey: "folderDragEdgePageIn")
        CATransaction.commit()
    }

    func hideFolderDragSource(in incoming: FolderPageSurface, context: FolderItemDragSession) {
        if case .application(let sourceApplication) = context.sourceEntry.item,
            let sourcePresentation = incoming.presentations.first(where: {
                $0.button.application.id == sourceApplication.id
            }) {
            sourcePresentation.tileLayer.opacity = 0
            sourcePresentation.button.isHidden = true
        }

    }

    fileprivate func contextualizeFolderDragSurfaceButtons(
        _ surface: FolderPageSurface, context: FolderItemDragSession) {
        for presentation in surface.presentations {
            presentation.button.isHidden = true
            if presentation.button !== context.trackingButton { presentation.button.removeFromSuperview() }
        }
    }

    fileprivate func clampedFolderDragPointToGrid(_ point: CGPoint, metrics: FolderGridMetrics) -> CGPoint {
        CGPoint(
            x: min(max(point.x, metrics.gridFrame.minX), metrics.gridFrame.maxX),
            y: min(max(point.y, metrics.gridFrame.minY), metrics.gridFrame.maxY))
    }

    fileprivate func updateFolderItemDragDestination(at center: CGPoint, context: FolderItemDragSession) {
        guard let destination = folderReorderTargetIndex(at: center, context: context),
            destination != context.destinationAbsoluteIndex
        else { return }

        let previousDestination = context.destinationAbsoluteIndex
        context.destinationAbsoluteIndex = destination
        if let geometry = folderReorderGeometry() {
            _ = dragInteraction.update(
                target: .pageInsertion(page: folderPaging.page, index: max(0, destination - geometry.pageStartIndex)))
        }
        previewFolderItemReorder(
            context, destinationAbsoluteIndex: destination, previousDestinationAbsoluteIndex: previousDestination)
    }

    struct FolderReorderGeometry {
        let folder: ResolvedLaunchpadFolder
        let metrics: FolderGridMetrics
        let pageStartIndex: Int
        let visibleCount: Int
    }

    func folderReorderGeometry() -> FolderReorderGeometry? {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return nil }

        let allMetrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let pageStartIndex = folderPaging.page * allMetrics.itemsPerPage
        guard pageStartIndex < folder.applications.count else { return nil }
        let pageEndIndex = min(pageStartIndex + allMetrics.itemsPerPage, folder.applications.count)
        let visibleCount = pageEndIndex - pageStartIndex

        // LAUNCHPANE_FOLDER_PAGE_LOCAL_LAYOUT_V16
        // The open Folder panel uses one stable full-folder lattice on every
        // page. Reorder hit-testing must use that exact same lattice too;
        // solving a second, smaller Folder for a partial page makes its cells
        // disagree with the visuals after page one.
        return FolderReorderGeometry(
            folder: folder, metrics: allMetrics, pageStartIndex: pageStartIndex, visibleCount: visibleCount)
    }

    // LAUNCHPANE_FOLDER_DRAG_ROOT_PARITY_V19
    fileprivate func projectedFolderApplications(_ context: FolderItemDragSession, destinationAbsoluteIndex: Int)
        -> [ApplicationRecord]? {
        guard case .application(let sourceApplication) = context.sourceEntry.item else { return nil }
        var applications = context.baselineApplications
        guard let sourceIndex = applications.firstIndex(where: { $0.id == sourceApplication.id }) else { return nil }
        let source = applications.remove(at: sourceIndex)
        guard destinationAbsoluteIndex >= 0, destinationAbsoluteIndex <= applications.endIndex else { return nil }
        applications.insert(source, at: destinationAbsoluteIndex)
        return applications
    }

    fileprivate func projectedFolder(_ context: FolderItemDragSession, destinationAbsoluteIndex: Int)
        -> ResolvedLaunchpadFolder? {
        guard let folder = resolvedFolder(id: context.folderID),
            let applications = projectedFolderApplications(context, destinationAbsoluteIndex: destinationAbsoluteIndex)
        else { return nil }
        return ResolvedLaunchpadFolder(id: folder.id, title: folder.title, applications: applications)
    }

    fileprivate func folderPageVisibleCount(applicationsCount: Int, page: Int, capacity: Int) -> Int {
        guard capacity > 0, page >= 0 else { return 0 }
        let start = page * capacity
        guard start < applicationsCount else { return 0 }
        return min(capacity, applicationsCount - start)
    }

    fileprivate func folderDragDestinationIndexForEdgeTurn(
        direction: Int, targetPage: Int, context: FolderItemDragSession, metrics: FolderGridMetrics
    ) -> Int? {
        guard case .application(let sourceApplication) = context.sourceEntry.item else { return nil }
        var remaining = context.baselineApplications
        guard let sourceIndex = remaining.firstIndex(where: { $0.id == sourceApplication.id }) else { return nil }
        remaining.remove(at: sourceIndex)
        let pageStart = targetPage * metrics.itemsPerPage
        guard pageStart <= remaining.count else { return nil }
        let targetCount = folderPageVisibleCount(
            applicationsCount: remaining.count, page: targetPage, capacity: metrics.itemsPerPage)
        let localIndex = direction > 0 ? min(targetCount, max(0, metrics.itemsPerPage - 1)) : 0
        return min(remaining.count, pageStart + localIndex)
    }

    fileprivate func stabilizedFolderReorderLocalSlot(
        rawSlot: Int, center: CGPoint, context: FolderItemDragSession, geometry: FolderReorderGeometry
    ) -> Int {
        let currentLocalIndex = context.destinationAbsoluteIndex - geometry.pageStartIndex
        guard (0..<geometry.visibleCount).contains(currentLocalIndex), rawSlot != currentLocalIndex,
            let rawCell = geometry.metrics.cellFrame(forItemAt: rawSlot)
        else { return rawSlot }

        return GridReorderInsertion.resolve(
            rawSlot: rawSlot, currentSlot: currentLocalIndex, draggedCenterX: center.x, targetCell: rawCell,
            isRightToLeft: geometry.metrics.isRightToLeft)
    }

    fileprivate func folderReorderTargetIndex(at center: CGPoint, context: FolderItemDragSession) -> Int? {
        guard let geometry = folderReorderGeometry(), geometry.folder.id == context.folderID,
            geometry.metrics.gridFrame.contains(center),
            let rawSlot = (0..<geometry.visibleCount).first(where: {
                geometry.metrics.cellFrame(forItemAt: $0)?.contains(center) == true
            })
        else { return context.destinationAbsoluteIndex }

        let slot = stabilizedFolderReorderLocalSlot(
            rawSlot: rawSlot, center: center, context: context, geometry: geometry)
        return geometry.pageStartIndex + min(slot, geometry.visibleCount - 1)
    }

    fileprivate func previewFolderItemReorder(
        _ context: FolderItemDragSession, destinationAbsoluteIndex: Int, previousDestinationAbsoluteIndex: Int? = nil,
        animated: Bool = true
    ) {
        guard let geometry = folderReorderGeometry(),
            let projectedApplications = projectedFolderApplications(
                context, destinationAbsoluteIndex: destinationAbsoluteIndex),
            case .application(let sourceApplication) = context.sourceEntry.item
        else { return }

        let pageStart = geometry.pageStartIndex
        let pageEnd = min(pageStart + geometry.metrics.itemsPerPage, projectedApplications.count)
        guard pageStart <= pageEnd else { return }
        let pageApplications = Array(projectedApplications[pageStart..<pageEnd])
        let targetLocalIndexByIdentity = Dictionary(
            uniqueKeysWithValues: pageApplications.enumerated().map { ($0.element.id, $0.offset) })

        let previousAbsoluteIndex = previousDestinationAbsoluteIndex ?? context.destinationAbsoluteIndex
        let transition = LaunchpadVisualStyle.dragReflowTransition(
            movedForward: destinationAbsoluteIndex > previousAbsoluteIndex)
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let reflowBatchMediaTime = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for presentation in folderPresentation.folderPresentations {
            let identity = presentation.button.application.id
            if identity == sourceApplication.id {
                presentation.tileLayer.opacity = 0
                presentation.button.isHidden = true
                continue
            }
            guard let targetLocalIndex = targetLocalIndexByIdentity[identity],
                let targetFrames = folderPageItemFrames(
                    localIndex: targetLocalIndex, visibleCount: pageApplications.count, metrics: geometry.metrics)
            else { continue }

            let visiblePosition = presentation.tileLayer.presentation()?.position ?? presentation.tileLayer.position
            presentation.tileLayer.removeAnimation(forKey: "dragReflowPosition")
            presentation.tileLayer.position = targetFrames.cell.center
            presentation.tileLayer.opacity = 1
            presentation.button.frame = targetFrames.icon

            guard shouldAnimate, visiblePosition != targetFrames.cell.center else { continue }
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: visiblePosition)
            move.toValue = NSValue(point: targetFrames.cell.center)
            move.duration = transition.duration
            move.timingFunction = transition.timingFunction
            move.beginTime = presentation.tileLayer.convertTime(reflowBatchMediaTime, from: nil)
            presentation.tileLayer.add(move, forKey: "dragReflowPosition")
        }

        CATransaction.commit()
    }

    func restoreFolderItemReorderPreview(_ context: FolderItemDragSession, animated: Bool) {
        let previousDestination = context.destinationAbsoluteIndex
        context.destinationAbsoluteIndex = context.sourceAbsoluteIndex
        previewFolderItemReorder(
            context, destinationAbsoluteIndex: context.sourceAbsoluteIndex,
            previousDestinationAbsoluteIndex: previousDestination, animated: animated)
    }

    /// Adopt the already-visible reorder instead of replacing the folder's
    /// panel, icon bitmaps, and raster caches at the end of the landing.
    /// Called inside the same disabled-actions transaction that retires the proxy.
    func adoptCommittedFolderReorder(_ context: FolderItemDragSession) -> Bool {
        guard openFolderID == context.folderID, let geometry = folderReorderGeometry(),
            let surface = folderPaging.surfaces[folderPaging.page], surface.layer.superlayer != nil,
            let expected = projectedFolderApplications(
                context, destinationAbsoluteIndex: context.destinationAbsoluteIndex),
            geometry.folder.applications.map(\.id) == expected.map(\.id)
        else { return false }

        let applications = Array(
            geometry.folder.applications[geometry.pageStartIndex..<geometry.pageStartIndex + geometry.visibleCount])
        let folderID = context.folderID
        let byIdentity = Dictionary(
            uniqueKeysWithValues: folderPresentation.folderPresentations.map { ($0.button.application.id, $0) })
        let presentations = applications.compactMap { byIdentity[$0.id] }
        let frames = applications.indices.compactMap {
            folderPageItemFrames(localIndex: $0, visibleCount: applications.count, metrics: geometry.metrics)
        }
        guard presentations.count == applications.count, frames.count == applications.count else { return false }

        retireOffscreenFolderReorderPages()
        folderHiddenApplicationID = nil
        for (index, presentation) in presentations.enumerated() {
            let application = applications[index]
            let itemFrames = frames[index]
            let absoluteIndex = geometry.pageStartIndex + index
            if presentation.tileLayer.superlayer !== surface.layer { surface.layer.addSublayer(presentation.tileLayer) }
            presentation.tileLayer.position = itemFrames.cell.center
            presentation.tileLayer.opacity = 1
            if application.id == context.trackingButton.application.id {
                presentation.iconLayer.removeAnimation(forKey: "iconPressedOpacity")
                presentation.iconLayer.opacity = 1
                presentation.iconLayer.setAffineTransform(.identity)
            }
            presentation.button.frame = itemFrames.icon
            rebindFolderPointerDown(
                presentation, folderID: folderID, application: application, absoluteIndex: absoluteIndex,
                frames: itemFrames)
            if presentation.button.superview == nil { addSubview(presentation.button) }
            presentation.button.isEnabled = true
            presentation.button.isHidden = false
        }
        folderPresentation.folderPresentations = presentations
        folderPaging.replaceCurrentSurface(
            layer: surface.layer, presentations: presentations, applications: applications)
        updateFolderSelectionAppearance(itemsPerPage: geometry.metrics.itemsPerPage)
        stageAdjacentFolderPageSurfaces(
            folder: geometry.folder, metrics: geometry.metrics,
            scale: window?.backingScaleFactor ?? displayContext.backingScaleFactor)

        finishFolderTrackingAfterReorder(context, presentations: presentations)
        return true
    }

    fileprivate func retireOffscreenFolderReorderPages() {
        // Offscreen pages still describe the old order; retire only those.
        for (page, cached) in folderPaging.surfaces where page != folderPaging.page {
            detachFolderButtons(from: cached)
            cached.layer.removeAllAnimations()
            cached.layer.removeFromSuperlayer()
        }
    }

    fileprivate func rebindFolderPointerDown(
        _ presentation: AppTilePresentation, folderID: UUID, application: ApplicationRecord, absoluteIndex: Int,
        frames: GridItemFrames
    ) {
        // Closures created when the folder opened capture the old slot.
        // Rebind the committed geometry before allowing the next drag.
        presentation.button.onPointerDown = { [weak self, weak presentation] event in
            guard let self, let presentation else { return }
            self.folderItemPointerDown(
                folderID: folderID, absoluteIndex: absoluteIndex, frames: frames,
                presentation: presentation, event: event)
        }
    }

    fileprivate func finishFolderTrackingAfterReorder(
        _ context: FolderItemDragSession, presentations: [AppTilePresentation]
    ) {
        if presentations.contains(where: { $0.button === context.trackingButton }) {
            // Same-page reorder keeps the original button as a live target.
            context.trackingButton.endPointerTrackingWithoutCallback()
            dragInteraction.preserve(nil)
            dragInteraction.endExtraction()
        } else {
            context.sourceEntry.tileLayer.removeFromSuperlayer()
            retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
        }
    }

    func updateFolderDropPreview(_ context: FolderItemDragSession, at center: CGPoint) {
        if let destination = folderReorderTargetIndex(at: center, context: context) {
            let previousDestination = context.destinationAbsoluteIndex
            context.destinationAbsoluteIndex = destination
            previewFolderItemReorder(
                context, destinationAbsoluteIndex: destination, previousDestinationAbsoluteIndex: previousDestination)
        }

    }

    fileprivate func promoteFolderItemDragToRoot(_ context: FolderItemDragSession, at point: CGPoint) {
        guard folderItemDragSession === context, let metrics = currentMetrics, let originalSurface = activeSurface,
            case .application(let application) = context.sourceEntry.item
        else { return }

        cancelFolderItemDragEdgePaging(context)
        context.pendingReleasePoint = nil

        let draft: LauncherLayoutDraft
        do {
            var candidate = try LauncherLayoutDraft(
                document: layoutDocument.normalizedForPageCapacity(metrics.itemsPerPage))
            try candidate.extractApplication(
                application.id, fromFolder: context.folderID, pageCapacity: metrics.itemsPerPage)
            draft = candidate
        } catch {
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }

        let session = LaunchpadDragSession(
            sourceEntry: context.sourceEntry, draft: draft, proxyLayer: context.proxyLayer,
            pointerOffset: context.pointerOffset, originalSurface: originalSurface, sourcePage: currentPage,
            sourceOrigin: .folder(context.folderID), projectionBaselineDocument: draft.document)
        session.lastPointerPoint = point
        dragSession = session
        folderItemDragSession = nil
        pendingFolderPress = nil
        dragInteraction.beginExtraction()

        // Build the root projection while the folder overlay still owns the
        // screen. The preview is based on draft.document, where the dragged
        // child has already been removed from its folder. It starts hidden and
        // becomes the root surface that closeFolder() fades in, so the stale
        // pre-extraction folder miniature is never exposed.
        prepareFolderExtractionRootPreview(session, metrics: metrics)

        closeFolder(animated: true, preservingTrackedButton: context.trackingButton)
        updateDragInteraction(at: point)
    }

    fileprivate func prepareFolderExtractionRootPreview(_ session: LaunchpadDragSession, metrics: GridMetrics) {
        let baseline = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage)
        let sourceID = session.sourceEntry.item.id

        var sourceLocation: DragPageLocation?
        for (pageIndex, page) in baseline.pages.enumerated() {
            if let itemIndex = page.firstIndex(where: { item in
                switch (item, sourceID) {
                case (.application(let reference), .application(let identity)): return reference.identity == identity
                case (.folder(let folder), .folder(let folderID)): return folder.id == folderID
                default: return false
                }
            }) {
                sourceLocation = DragPageLocation(page: pageIndex, index: itemIndex)
                break
            }
        }

        guard let sourceLocation else { return }

        updateDragPreviewLayout(session, location: sourceLocation, animated: false, metrics: metrics)
        setDragTarget(.pageInsertion(page: sourceLocation.page, index: sourceLocation.index), session: session)

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

    fileprivate func nearestFolderExtractionInsertionTarget(at point: CGPoint, session: LaunchpadDragSession)
        -> LauncherDropTarget? {
        guard session.sourceOrigin.folderID != nil, let metrics = currentMetrics, bounds.contains(point) else {
            return nil
        }

        let baseline = session.projectionBaselineDocument.normalizedForPageCapacity(metrics.itemsPerPage)
        let pageItems = baseline.pages.indices.contains(currentPage) ? baseline.pages[currentPage] : []
        let pageIDs = pageItems.map { item -> LauncherLayoutItemIdentifier in
            switch item {
            case .application(let reference): .application(reference.identity)
            case .folder(let folder): .folder(folder.id)
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
        let visibleIDs = projection.pages.indices.contains(currentPage) ? projection.pages[currentPage].map(\.id) : []
        guard
            let index = ResolvedLaunchpadInsertionIndex.resolve(
                visibleSlot: min(nearestSlot, countWithoutSource), pageIdentifiers: pageIDs,
                visibleIdentifiers: visibleIDs, sourceIdentifier: sourceID)
        else { return nil }
        return .pageInsertion(page: currentPage, index: index)
    }

    // LAUNCHPANE_FOLDER_DRAG_ROOT_PARITY_V19

    fileprivate func cancelFolderExtractionDrag(_ session: LaunchpadDragSession, animated: Bool) {
        guard let folderID = session.sourceOrigin.folderID else { return }
        session.edgePagingTask?.cancel()
        clearDragIntent(session)
        session.pendingCompletionPoint = nil
        session.edgeGeneration &+= 1
        session.draft.rollback()

        folderPresentation.invalidateAnimation()
        cleanupFolderOverlay()
        session.proxyLayer.removeAllAnimations()
        session.proxyLayer.removeFromSuperlayer()

        // LAUNCHPANE_FOLDER_EXTRACTION_POINTER_OWNERSHIP_V17
        //
        // Escape/programmatic rollback can run while the preserved button
        // still owns mouseDown. removeFromSuperview() would otherwise call
        // viewWillMove(toWindow: nil) -> cancelPointerTracking() ->
        // onPointerCancelled and recursively enter cancellation again.
        retireFolderTrackingButtonAfterPointerCallback(session.sourceEntry.button)

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
        dragInteraction.finish()

        if let metrics = currentMetrics {
            updatePageIndicator(
                pageCount: pageProjection(metrics: metrics).pageCount, metrics: metrics,
                scale: window?.backingScaleFactor ?? 1)
        }
        openFolder(folderID, sourceFrame: folderSourceFrame(for: folderID))
    }

    // LAUNCHPANE_PROGRESSIVE_FOLDER_ICON_WARM_V6

    // LAUNCHPANE_FOLDER_PAGE_LOCAL_LAYOUT_V16
    // Resolve every page against the stable full-folder grid, but always map the
    // page's applications from local slot zero. This deliberately does not reuse
    // a page-global/absolute index. A sparse second page therefore occupies
    // slots 0, 1, 2... of the same lattice used by a full first page.

    // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14

    // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15

    // LAUNCHPANE_FOLDER_OPEN_FPS_V13

}

extension ResolvedLaunchpadItem {
    fileprivate var applicationsForIconRendering: [ApplicationRecord] {
        switch self {
        case .application(let application): [application]
        case .folder(let folder): folder.applications
        }
    }
}

extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

private enum LaunchpadRuntimePaths {
    static var layoutFileURL: URL {
        guard let overridePath = ProcessInfo.processInfo.environment["LAUNCHPANE_LAYOUT_PATH"], !overridePath.isEmpty
        else { return LauncherLayoutStore.defaultFileURL }
        return URL(fileURLWithPath: overridePath)
    }
}
