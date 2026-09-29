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
    private let pageIndicatorLayer = CATextLayer()
    private let dragOverlayLayer = CALayer()
    var pageContentLayer = CALayer()
    let pageTransitionAnimator = PageTransitionAnimator()
    private let searchField = LaunchpadSearchField(frame: .zero)
    var displayContext: DisplayContext
    private lazy var applicationDirectoryMonitor = ApplicationDirectoryMonitor { [weak self] in
        Task { @MainActor [weak self] in await self?.refreshApplicationsFromDisk() }
    }

    var applications: [ApplicationRecord] = []
    var layoutDocument = LauncherLayoutDocument()
    var pageSurfaces: [Int: LaunchpadPageSurface] = [:]
    var activeSurface: LaunchpadPageSurface?
    private var renderedConfiguration: PageSurfaceConfiguration?
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
        pageTransitionAnimator.isAnimating || interactivePageSwipe != nil || folderPageTransitionAnimator.isAnimating
            || interactiveFolderPageSwipe != nil
    }

    private var dragStateMachine = LauncherDragStateMachine()
    private var pendingPress: PendingTilePress?
    private var dragSession: LaunchpadDragSession?
    private var dragCommitContext: LaunchpadDragCommitContext?
    private var isCommittingLayout = false
    private var isFinishingDragVisuals = false
    private var isResettingLayout = false

    let folderPresentation = FolderPresentation()

    var openFolderID: UUID?
    private var folderPage = 0
    private var folderSelectedIndex = -1
    private var folderPageScrollGesture = PageScrollGesture()
    private var folderPageSwipeInputGate = PageSwipeInputGate()
    var interactiveFolderPageSwipe: InteractiveFolderPageSwipe?
    private var interactiveFolderPageGeneration = 0
    private var folderPageSurfaces: [Int: FolderPageSurface] = [:]

    // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14
    // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
    // Folder paging uses the exact same compositor animator and motion profile
    // as root paging. Only the travel distance changes from the full display
    // width to the open folder panel width.
    private let folderPageTransitionAnimator = PageTransitionAnimator()
    private weak var folderPageViewportLayer: CALayer?
    private weak var folderPageContentLayer: CALayer?
    private weak var folderPageIndicatorLayer: CATextLayer?

    private var folderHiddenApplicationID: ApplicationIdentity?

    // LAUNCHPANE_FOLDER_INTERACTION_V1
    // Folder title editing is an AppKit control layered above the Core Animation
    // folder chrome. Folder-child dragging owns its gesture until the child
    // actually crosses the panel boundary, then hands the same mouse gesture to
    // the existing root drag/reflow state machine.
    var isCommittingFolderTitle = false
    private var pendingFolderPress: PendingFolderTilePress?
    private var folderItemDragSession: FolderItemDragSession?

    // LAUNCHPANE_FOLDER_EXTRACTION_POINTER_OWNERSHIP_V17
    //
    // Folder -> root extraction crosses two presentation trees while the same
    // physical mouseDown is still active. The exact NSButton that received that
    // mouseDown must remain mounted until AppKit delivers the matching mouseUp
    // or an explicit cancellation.
    //
    // Visual Folder cleanup may retire CALayers and every other hit target, but
    // it must never remove this pointer owner mid-gesture.
    private var preservedFolderTrackingButton: AppTileButton?

    // LAUNCHPANE_FOLDER_EXTRACTION_ACTIVATION_SHIELD_V21
    //
    // Folder -> root extraction temporarily keeps an AppKit button from the
    // closing Folder alive while the root drag pipeline takes over. AppKit can
    // emit a transient didResignActive during that ownership handoff even though
    // the user never switched applications. Keep a narrowly-scoped shield until
    // both pointer ownership and the root drag commit have finished.
    private var folderExtractionActivationShield = false

    // LAUNCHPANE_FOLDER_DRAG_RELEASE_OWNERSHIP_V22
    //
    // A Folder-child drag temporarily owns one AppKit NSButton independently
    // from the Folder page surface that is being reordered/rebuilt. Releasing
    // that button used to create a tiny ownership gap at the end of the landing
    // animation. On an LSUIElement/accessory app, AppKit can report a transient
    // resign-active in exactly that gap, which Launchpad interprets as an
    // external app switch and dismisses the whole window.
    //
    // Suppress dismissal for the complete internal handoff, not only for
    // Folder -> root extraction. The predicate is intentionally state-derived
    // so it cannot remain stuck after an interaction finishes.
    var suppressesResignActiveDismissal: Bool {
        folderExtractionActivationShield || folderItemDragSession != nil || preservedFolderTrackingButton != nil
            || (openFolderID != nil && isCommittingLayout)
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
        dragCommitContext = nil
        pendingPress = nil
        pendingFolderPress = nil
        if let folderItemDragSession { cancelFolderItemDragEdgePaging(folderItemDragSession) }

        // A presentation can disappear while a drag is still active (display
        // change, launcher dismissal, termination). End the tracking state
        // silently before detaching the preserved AppKit mouse owner.
        preservedFolderTrackingButton?.endPointerTrackingWithoutCallback()
        preservedFolderTrackingButton?.removeFromSuperview()
        preservedFolderTrackingButton = nil
        folderExtractionActivationShield = false

        folderItemDragSession = nil
        dragStateMachine = LauncherDragStateMachine()
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

        if event.keyCode == 53, dragStateMachine.state != .idle {
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
        guard dragStateMachine.state == .idle, !isCommittingLayout, !isFinishingDragVisuals, !isResettingLayout else {
            return
        }

        if openFolderID != nil {
            // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
            // Match root paging input semantics. Precise trackpad gestures are
            // direct-manipulation and are sampled onto the physical display's
            // refresh boundary. Wheel/phase-less input keeps the discrete path.
            if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
                if folderPageSwipeInputGate.consumes(
                    phase: PageScrollPhase(event.phase), momentum: PageScrollMomentum(event.momentumPhase),
                    isAnimating: folderPageTransitionAnimator.isAnimating
                        || interactiveFolderPageSwipe?.phase == .settling) {
                    return
                }
            }

            if handleInteractiveFolderPageSwipe(event) { return }

            if let direction = folderPageScrollGesture.consume(event) { changeFolderPage(by: direction) }
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

    fileprivate var resolvedItems: [ResolvedLaunchpadItem] {
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

    fileprivate func rebuildPageSurfaces(
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

    fileprivate func makePageSurface(
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

    fileprivate func animateHover(on iconLayer: CALayer?, isHovering: Bool) {
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

    @objc fileprivate func applicationButtonPressed(_ sender: AppTileButton) {
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
            !isFinishingDragVisuals, dragStateMachine.pointerDown(on: entry.item.id)
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

            dragStateMachine.finish()
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
            dragStateMachine.finish()
        }
    }

    fileprivate func beginDragInteraction(at point: CGPoint) {
        guard let pendingPress, let originalSurface = activeSurface, dragStateMachine.beginDragging(),
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
        animateDragLift(proxyLayer, from: pendingPress.entry.frames.cell.center, to: point, offset: pointerOffset)
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
        folderPage = 0
        folderSelectedIndex = -1
        folderPageScrollGesture = PageScrollGesture()
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
        _ = dragStateMachine.update(target: target)
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

    private enum DragEdgeMetrics {
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

    private enum DragProxyMetrics {
        static let labelLayerName = "LaunchPaneDragProxyLabel"
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

    fileprivate func projectedDocument(
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

    fileprivate func updateDragPreviewLayout(
        _ session: LaunchpadDragSession, location: DragPageLocation, animated: Bool, metrics: GridMetrics
    ) {
        let previousLocation = session.previewLocation
        guard previousLocation != location,
            let document = projectedDocument(session, location: location, metrics: metrics)
        else { return }
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
        let previousRank =
            (previousLocation?.page ?? session.sourcePage) * metrics.itemsPerPage + (previousLocation?.index ?? 0)
        let transition = LaunchpadVisualStyle.dragReflowTransition(
            movedForward: location.page * metrics.itemsPerPage + location.index > previousRank)
        let scale = window?.backingScaleFactor ?? 1
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let workingSurface: LaunchpadPageSurface = {
            if session.usesInPlacePreview { return session.originalSurface }

            if let previewSurface = session.previewSurface { return previewSurface }

            return session.originalSurface
        }()

        let workingIDs = Set(workingSurface.entries.map { $0.item.id })

        let targetIDs = Set(targetFrames.keys)

        let animation = DragReflowAnimation(transition: transition, enabled: shouldAnimate, scale: scale)
        if workingIDs == targetIDs {
            reflowExistingDragSurface(
                session, surface: workingSurface, targetFrames: targetFrames, targetIndices: targetIndices,
                animation: animation)
            return
        }
        let newSurface = makePageSurface(
            pageIndex: currentPage, items: items, metrics: metrics, scale: scale, projection: projection)
        replaceDragPreviewSurface(
            session, previousSurface: workingSurface, newSurface: newSurface, animation: animation)
    }

    fileprivate struct DragReflowAnimation {
        let transition: LaunchpadVisualStyle.DragReflowTransition
        let enabled: Bool
        let scale: CGFloat
    }

    fileprivate func reflowExistingDragSurface(
        _ session: LaunchpadDragSession, surface workingSurface: LaunchpadPageSurface,
        targetFrames: [LauncherLayoutItemIdentifier: GridItemFrames],
        targetIndices: [LauncherLayoutItemIdentifier: Int], animation: DragReflowAnimation
    ) {
        let transition = animation.transition
        let shouldAnimate = animation.enabled
        if session.previewSurface == nil {
            session.usesInPlacePreview = true

            activeSurface = session.originalSurface

            pageContentLayer = session.originalSurface.layer
        }

        CATransaction.begin()

        CATransaction.setDisableActions(true)

        // One wall-clock start for the complete reflow batch. Every displaced
        // tile converts this exact media time into its own layer time.
        let reflowBatchMediaTime = CACurrentMediaTime()

        workingSurface.layer.opacity = 1

        workingSurface.layer.isHidden = false

        for entry in workingSurface.entries {
            guard let targetFrame = targetFrames[entry.item.id], let targetIndex = targetIndices[entry.item.id] else {
                continue
            }

            // 取真正螢幕上目前的位置。
            //
            // 如果使用者很快從 A -> B -> C，
            // 新動畫直接從 presentation position
            // 接續，不跳回上一個 model position。
            let visiblePosition = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position

            entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

            entry.tileLayer.removeAnimation(forKey: "dragRollbackPosition")

            entry.tileLayer.removeAnimation(forKey: "dragReflowOpacity")

            entry.tileLayer.position = targetFrame.cell.center

            entry.tileLayer.opacity = 1

            entry.frames = targetFrame

            entry.absoluteIndex = targetIndex

            if entry.item.id == session.sourceEntry.item.id {
                // Source item 仍然只有 drag proxy
                // 是唯一 visual owner。
                //
                // source NSButton 不在 drag 中移動，
                // 避免 AppKit mouse tracking view
                // 在 mouseDown -> mouseUp 中途換 frame。
                entry.tileLayer.removeFromSuperlayer()

                continue
            }

            entry.button.frame = targetFrame.icon

            guard shouldAnimate, visiblePosition != targetFrame.cell.center else { continue }

            let move = CABasicAnimation(keyPath: "position")

            move.fromValue = NSValue(point: visiblePosition)

            move.toValue = NSValue(point: targetFrame.cell.center)

            move.duration = transition.duration

            move.timingFunction = transition.timingFunction

            move.beginTime = entry.tileLayer.convertTime(reflowBatchMediaTime, from: nil)

            entry.tileLayer.add(move, forKey: "dragReflowPosition")
        }

        CATransaction.commit()

    }

    fileprivate func replaceDragPreviewSurface(
        _ session: LaunchpadDragSession, previousSurface: LaunchpadPageSurface, newSurface: LaunchpadPageSurface,
        animation: DragReflowAnimation
    ) {
        let transition = animation.transition
        var oldPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]

        for entry in previousSurface.entries {
            oldPositions[entry.item.id] = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position
        }

        CATransaction.begin()

        CATransaction.setDisableActions(true)

        let fallbackReflowBatchMediaTime = CACurrentMediaTime()

        newSurface.layer.frame = bounds

        newSurface.layer.contentsScale = animation.scale

        newSurface.layer.opacity = 1

        newSurface.layer.isHidden = false

        for entry in newSurface.entries {
            let targetPosition = entry.tileLayer.position

            if entry.item.id == session.sourceEntry.item.id {
                entry.tileLayer.removeFromSuperlayer()

                continue
            }

            guard animation.enabled else { continue }

            let startPosition: CGPoint

            if let oldPosition = oldPositions[entry.item.id] {
                startPosition = oldPosition
            } else {
                startPosition = CGPoint(x: targetPosition.x + transition.enteringItemOffset, y: targetPosition.y)

                let fade = CABasicAnimation(keyPath: "opacity")

                fade.fromValue = 0
                fade.toValue = 1

                fade.duration = transition.enteringItemFadeDuration

                fade.timingFunction = transition.timingFunction

                fade.beginTime = entry.tileLayer.convertTime(fallbackReflowBatchMediaTime, from: nil)

                entry.tileLayer.add(fade, forKey: "dragReflowOpacity")
            }

            guard startPosition != targetPosition else { continue }

            let move = CABasicAnimation(keyPath: "position")

            move.fromValue = NSValue(point: startPosition)

            move.toValue = NSValue(point: targetPosition)

            move.duration = transition.duration

            move.timingFunction = transition.timingFunction

            move.beginTime = entry.tileLayer.convertTime(fallbackReflowBatchMediaTime, from: nil)

            entry.tileLayer.add(move, forKey: "dragReflowPosition")
        }

        // 如果未來真的進入 fallback，
        // 舊 surface 必須先失去 render ownership。
        previousSurface.layer.removeAllAnimations()

        previousSurface.layer.opacity = 0

        previousSurface.layer.isHidden = true

        previousSurface.layer.removeFromSuperlayer()

        rootLayer.insertSublayer(newSurface.layer, below: fixedOverlayLayer)

        CATransaction.commit()

        session.previewSurface = newSurface

        session.usesInPlacePreview = false
    }

    fileprivate func visibleIconFrame(for entry: LaunchpadPageEntry) -> CGRect {
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
    // Root and folder reorder share the same model-cell midpoint rule,
    // including diagonal entry from another row and coarse pointer updates.
    fileprivate func stabilizedReorderVisibleSlot(
        rawSlot: Int, draggedFrame: CGRect, session: LaunchpadDragSession, metrics: GridMetrics
    ) -> Int {
        let surface = session.previewSurface ?? session.originalSurface
        let activeDragPage = session.previewLocation?.page ?? session.sourcePage

        guard activeDragPage == currentPage,
            let layoutSource = surface.entries.first(where: { $0.item.id == session.sourceEntry.item.id }),
            let currentSlot = (0..<metrics.itemsPerPage).first(where: {
                metrics.cellFrame(forItemAt: $0)?.contains(layoutSource.frames.cell.center) == true
            }), rawSlot != currentSlot
        else { return rawSlot }

        guard let rawCell = metrics.cellFrame(forItemAt: rawSlot) else { return rawSlot }

        return GridReorderInsertion.resolve(
            rawSlot: rawSlot, currentSlot: currentSlot, draggedCenterX: draggedFrame.midX, targetCell: rawCell,
            isRightToLeft: metrics.isRightToLeft)
    }

    private struct DragHitTargets {
        let insertion: LauncherDropTarget
        let merge: LauncherDropTarget?
        var isMovingTowardMerge = false
    }

    private func dragHitTargets(_ session: LaunchpadDragSession) -> DragHitTargets {
        guard let metrics = currentMetrics else { return DragHitTargets(insertion: .outside, merge: nil) }
        let source = session.sourceEntry
        let draggedFrame = draggedIconFrame(for: session)
        let insertion = dragInsertionTarget(session, draggedFrame: draggedFrame, metrics: metrics)

        guard case .application = source.item, let surface = session.previewSurface ?? activeSurface else {
            return DragHitTargets(insertion: insertion, merge: nil)
        }
        let retaining: LauncherLayoutItemIdentifier?
        switch session.intentState.candidate {
        case .application(let identity): retaining = .application(identity)
        case .folder(let folderID): retaining = .folder(folderID)
        default: retaining = nil
        }
        let targets = surface.entries.filter { $0.item.id != source.item.id && $0.tileLayer.superlayer != nil }.map {
            let iconFrame = visibleIconFrame(for: $0)
            let cellFrame = $0.frames.cell.offsetBy(
                dx: iconFrame.midX - $0.frames.icon.midX, dy: iconFrame.midY - $0.frames.icon.midY)
            return FolderMergeGeometry.Target(id: $0.item.id, iconFrame: iconFrame, cellFrame: cellFrame)
        }
        // Only visible icons participate. Old snapshot slots remain exclusively
        // rollback data, never invisible merge anchors after an exchange.
        let selected = FolderMergeGeometry.target(draggedIcon: draggedFrame, targets: targets, retaining: retaining)
        let merge: LauncherDropTarget?
        switch selected {
        case .application(let identity): merge = .application(identity)
        case .folder(let folderID): merge = .folder(folderID)
        case nil: merge = nil
        }
        if merge == nil, FolderMergeGeometry.isApproachingTarget(draggedIcon: draggedFrame, targets: targets) {
            return DragHitTargets(insertion: .outside, merge: nil)
        }
        let approaching = FolderMergeGeometry.isMovingTowardTarget(
            draggedIcon: draggedFrame, previousDraggedIcon: session.previousIntentIconFrame, targets: targets)
        return DragHitTargets(insertion: insertion, merge: merge, isMovingTowardMerge: approaching)
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
        let countWithoutSource = pageIDs.filter { $0 != source.item.id }.count
        return {
            guard metrics.contentFrame.contains(point),
                let rawSlot = (0..<metrics.itemsPerPage).first(where: {
                    metrics.cellFrame(forItemAt: $0)?.contains(point) == true
                })
            else { return .outside }
            let slot = stabilizedReorderVisibleSlot(
                rawSlot: rawSlot, draggedFrame: draggedFrame, session: session, metrics: metrics)
            let projection = pageProjection(metrics: metrics, document: baseline)
            let visibleIDs =
                projection.pages.indices.contains(currentPage) ? projection.pages[currentPage].map(\.id) : []
            guard
                let index = ResolvedLaunchpadInsertionIndex.resolve(
                    visibleSlot: min(slot, countWithoutSource), pageIdentifiers: pageIDs,
                    visibleIdentifiers: visibleIDs, sourceIdentifier: source.item.id)
            else { return .outside }
            return .pageInsertion(page: currentPage, index: index)
        }()

    }

    fileprivate func applyDropHighlight(to entry: LaunchpadPageEntry, mergeTarget: LauncherLayoutItemIdentifier?) {
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
        entry.selectionLayer.backgroundColor =
            NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.normalSelectionBackgroundOpacity).cgColor
        entry.selectionLayer.borderColor =
            NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.normalSelectionBorderOpacity).cgColor
        entry.selectionLayer.borderWidth = FolderMergeVisualMetrics.normalSelectionBorderWidth
        entry.selectionLayer.setAffineTransform(.identity)

        if isApplicationTarget {
            // App -> App: keep both app icons visible. Add a compact,
            // folder-colored rounded surface behind the target and only fade
            // the two names. This reads as "these apps will group" instead of
            // prematurely replacing the target with a folder.
            entry.selectionLayer.backgroundColor =
                NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.folderBackgroundOpacity).cgColor
            entry.selectionLayer.borderColor =
                NSColor.white.withAlphaComponent(FolderMergeVisualMetrics.folderBorderOpacity).cgColor
            entry.selectionLayer.borderWidth = FolderMergeVisualMetrics.folderBorderWidth
            entry.selectionLayer.setAffineTransform(
                .init(
                    scaleX: FolderMergeVisualMetrics.appTargetFrameScale,
                    y: FolderMergeVisualMetrics.appTargetFrameScale))
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
            entry.iconLayer.setAffineTransform(
                .init(scaleX: FolderMergeVisualMetrics.folderTargetScale, y: FolderMergeVisualMetrics.folderTargetScale)
            )
            setMergeLabelOpacity(entry.labelLayer, to: 0)
        } else {
            entry.selectionLayer.opacity = entry.absoluteIndex == selectedIndex ? 1 : 0
            entry.iconLayer.opacity = 1
            entry.iconLayer.setAffineTransform(.identity)
            setMergeLabelOpacity(entry.labelLayer, to: 1)
        }
    }

    fileprivate func updateDropHighlight(_ target: LauncherDropTarget) {
        let surface = dragSession?.previewSurface ?? activeSurface
        guard let surface else { return }

        let mergeTarget: LauncherLayoutItemIdentifier?
        switch target {
        case .application(let identity): mergeTarget = .application(identity)
        case .folder(let folderID): mergeTarget = .folder(folderID)
        case .insertion, .pageInsertion, .outside: mergeTarget = nil
        }

        if let session = dragSession {
            let keepHiddenForMergeLanding: Bool
            if session.hasReleased {
                switch session.target {
                case .application, .folder: keepHiddenForMergeLanding = true
                case .insertion, .pageInsertion, .outside: keepHiddenForMergeLanding = false
                }
            } else {
                keepHiddenForMergeLanding = false
            }
            updateDragProxyMergeLabel(session, hidden: mergeTarget != nil || keepHiddenForMergeLanding)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(FolderMergeVisualMetrics.transitionDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        for entry in surface.entries { applyDropHighlight(to: entry, mergeTarget: mergeTarget) }

        CATransaction.commit()
    }

    fileprivate func setMergeLabelOpacity(_ labelLayer: CALayer, to targetOpacity: Float) {
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

    fileprivate func updateDragProxyMergeLabel(_ session: LaunchpadDragSession, hidden: Bool) {
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

    fileprivate func freezeMergeLandingTarget(
        _ session: LaunchpadDragSession, surface oldSurface: LaunchpadPageSurface) {
        let landingTargetID: LauncherLayoutItemIdentifier?
        switch session.target {
        case .application(let identity): landingTargetID = .application(identity)
        case .folder(let folderID): landingTargetID = .folder(folderID)
        case .insertion, .pageInsertion, .outside: landingTargetID = nil
        }
        if let landingTargetID, let landingEntry = oldSurface.entries.first(where: { $0.item.id == landingTargetID }) {
            session.mergeLandingTargetIconFrame = visibleIconFrame(for: landingEntry)
        } else {
            session.mergeLandingTargetIconFrame = nil
        }

    }

    fileprivate func preMergePageMapping(_ session: LaunchpadDragSession, metrics: GridMetrics)
        -> [LauncherLayoutItemIdentifier: Int] {
        guard session.hasCrossedPages else { return [:] }

        let preMergeDocument = session.projectedDocument ?? session.projectionBaselineDocument
        let preMergeProjection = pageProjection(metrics: metrics, document: preMergeDocument)

        var result: [LauncherLayoutItemIdentifier: Int] = [:]
        for (pageIndex, page) in preMergeProjection.pages.enumerated() {
            for item in page { result[item.id] = pageIndex }
        }
        return result
    }

    fileprivate func visibleTilePositions(
        in oldSurface: LaunchpadPageSurface
    ) -> [LauncherLayoutItemIdentifier: CGPoint] {
        var oldPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]
        for entry in oldSurface.entries {
            oldPositions[entry.item.id] = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position
        }

        return oldPositions
    }

    fileprivate func prepareFolderMergeReflowPreviewIfNeeded(_ session: LaunchpadDragSession) {
        guard session.folderCreationPreview == nil, let metrics = currentMetrics,
            !session.hasCrossedPages || session.previewSurface != nil
        else { return }

        switch session.target {
        case .application, .folder: break
        case .insertion, .pageInsertion, .outside: return
        }

        let projection = pageProjection(metrics: metrics, document: session.draft.document)
        guard projection.pages.indices.contains(currentPage) else { return }

        let items = projection.items
        let scale = window?.backingScaleFactor ?? 1
        let oldSurface = session.previewSurface ?? session.originalSurface
        guard oldSurface.pageIndex == currentPage else { return }

        // Freeze the merge destination before the final layout starts moving.
        // The source app must finish shrinking into the folder at the folder's
        // current visible position; only after that handoff may the page compact.
        freezeMergeLandingTarget(session, surface: oldSurface)

        let newSurface = makePageSurface(
            pageIndex: currentPage, items: items, metrics: metrics, scale: scale, projection: projection)

        let oldPositions = visibleTilePositions(in: oldSurface)

        let applicationTargetPosition: CGPoint? = {
            guard case .application(let identity) = session.target else { return nil }
            return oldPositions[.application(identity)]
        }()

        // LAUNCHPANE_CROSS_PAGE_ENTERING_HANDOFF_V3
        // oldSurface is the live pre-merge projection after edge paging. Remember
        // which page owned each item so a tile pulled in from an adjacent page
        // can receive a real visual handoff instead of appearing directly on top
        // of the tile that is still occupying the final slot.
        let preMergePageByIdentifier = preMergePageMapping(session, metrics: metrics)

        let transition = LaunchpadVisualStyle.dragReflowTransition(movedForward: false)
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let mergeLandingDuration = LaunchpadVisualStyle.dragCompletionTransition(kind: .merge).duration
        let reflowStartTime =
            CACurrentMediaTime() + mergeLandingDuration + FolderMergeVisualMetrics.postLandingReflowDelay

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        newSurface.layer.frame = bounds
        newSurface.layer.contentsScale = scale
        newSurface.layer.opacity = 1
        newSurface.layer.isHidden = false

        let reflow = MergeReflowContext(
            oldPositions: oldPositions, applicationTargetPosition: applicationTargetPosition,
            pageByIdentifier: preMergePageByIdentifier, metrics: metrics, transition: transition,
            enabled: shouldAnimate, startTime: reflowStartTime)
        for entry in newSurface.entries { animateMergeReflowEntry(entry, session: session, reflow: reflow) }

        restoreMergedFolderScale(session, surface: newSurface, animated: shouldAnimate)

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

    fileprivate func restoreMergedFolderScale(
        _ session: LaunchpadDragSession, surface newSurface: LaunchpadPageSurface, animated shouldAnimate: Bool
    ) {
        // App -> existing Folder leaves the same folder identifier in the final
        // document. Continue the merge-ready +30% presentation back to 1.0 on
        // the new surface instead of snapping smaller at mouse-up.
        if case .folder(let folderID) = session.target,
            let folderEntry = newSurface.entries.first(where: { $0.item.id == .folder(folderID) }), shouldAnimate {
            let scaleDown = CABasicAnimation(keyPath: "transform")
            scaleDown.fromValue = CATransform3DMakeAffineTransform(
                .init(scaleX: FolderMergeVisualMetrics.folderTargetScale, y: FolderMergeVisualMetrics.folderTargetScale)
            )
            scaleDown.toValue = CATransform3DIdentity
            scaleDown.duration = FolderMergeVisualMetrics.transitionDuration
            scaleDown.timingFunction = CAMediaTimingFunction(name: .easeOut)
            folderEntry.iconLayer.add(scaleDown, forKey: "folderMergeCommitScale")
        }

    }

    fileprivate struct MergeReflowContext {
        let oldPositions: [LauncherLayoutItemIdentifier: CGPoint]
        let applicationTargetPosition: CGPoint?
        let pageByIdentifier: [LauncherLayoutItemIdentifier: Int]
        let metrics: GridMetrics
        let transition: LaunchpadVisualStyle.DragReflowTransition
        let enabled: Bool
        let startTime: CFTimeInterval
    }

    fileprivate func animateMergeReflowEntry(
        _ entry: LaunchpadPageEntry, session: LaunchpadDragSession, reflow: MergeReflowContext
    ) {
        let oldPositions = reflow.oldPositions
        let applicationTargetPosition = reflow.applicationTargetPosition
        let preMergePageByIdentifier = reflow.pageByIdentifier
        let metrics = reflow.metrics
        let transition = reflow.transition
        let shouldAnimate = reflow.enabled
        let reflowStartTime = reflow.startTime
        let targetPosition = entry.tileLayer.position
        var startPosition = oldPositions[entry.item.id]

        // App -> App replaces the target application identifier with a new
        // folder identifier. Start that new folder exactly where the target
        // app is visibly sitting so the replacement does not flash in from a
        // different slot while the rest of the page compacts.
        if startPosition == nil, let applicationTargetPosition, case .folder(let folder) = entry.item,
            case .application(let targetIdentity) = session.target,
            folder.applications.contains(where: { $0.id == targetIdentity }) {
            startPosition = applicationTargetPosition
        }

        // A genuine page-entering item has no old position on this surface.
        // Before this fix it therefore appeared immediately at targetPosition while
        // the previous last tile was held at that exact slot until reflowStartTime.
        // Stage it in the adjacent-page direction and keep it invisible until the
        // outgoing tile has visibly vacated the slot.
        if startPosition == nil, let previousPage = preMergePageByIdentifier[entry.item.id],
            previousPage != currentPage {
            let logicalDirection: CGFloat = previousPage > currentPage ? 1 : -1
            let visualDirection = metrics.isRightToLeft ? -logicalDirection : logicalDirection
            let enteringOffset = abs(transition.enteringItemOffset) * visualDirection

            startPosition = CGPoint(x: targetPosition.x + enteringOffset, y: targetPosition.y)

            if shouldAnimate {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = transition.enteringItemFadeDuration
                // Position starts moving with the grid. Opacity deliberately waits
                // for about the first third of the current reflow so two icons never
                // read as owners of the same bottom-right slot.
                fade.beginTime = reflowStartTime + min(transition.duration * 0.33, 0.16)
                fade.timingFunction = transition.timingFunction
                fade.fillMode = .backwards
                entry.tileLayer.add(fade, forKey: "dragReflowOpacity")
            }
        }

        guard shouldAnimate, let startPosition, startPosition != targetPosition else { return }

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: startPosition)
        move.toValue = NSValue(point: targetPosition)
        move.duration = transition.duration
        move.timingFunction = transition.timingFunction
        move.beginTime = reflowStartTime
        move.fillMode = .backwards
        entry.tileLayer.add(move, forKey: "dragReflowPosition")
    }

    fileprivate func mergedFolderEntry(in surface: LaunchpadPageSurface?, for target: LauncherDropTarget)
        -> LaunchpadPageEntry? {
        guard let surface else { return nil }
        switch target {
        case .folder(let folderID): return surface.entries.first { $0.item.id == .folder(folderID) }
        case .application(let targetIdentity):
            return surface.entries.first { entry in
                guard case .folder(let folder) = entry.item else { return false }
                return folder.applications.contains { $0.id == targetIdentity }
            }
        case .insertion, .pageInsertion, .outside: return nil
        }
    }

    fileprivate func mergeLandingScale(session: LaunchpadDragSession) -> CGFloat {
        guard case .application(let sourceIdentity) = session.sourceEntry.item.id else {
            let sourceIconSize = min(session.sourceEntry.frames.icon.width, session.sourceEntry.frames.icon.height)
            return AppTilePresentationFactory.folderMiniatureIconScale(forRootIconSize: sourceIconSize)
        }

        let finalFolder: LauncherFolder?

        switch session.target {
        case .folder(let folderID):
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item, folder.id == folderID else { return nil }
                    return folder
                }.first

        case .application(let targetIdentity):
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item else { return nil }
                    let identities = folder.applications.map(\.identity)
                    guard identities.contains(sourceIdentity), identities.contains(targetIdentity) else { return nil }
                    return folder
                }.first

        case .insertion, .pageInsertion, .outside: finalFolder = nil
        }

        guard let finalFolder, finalFolder.applications.count > AppTilePresentationFactory.folderMaximumVisibleChildren
        else {
            let sourceIconSize = min(session.sourceEntry.frames.icon.width, session.sourceEntry.frames.icon.height)
            return AppTilePresentationFactory.folderMiniatureIconScale(forRootIconSize: sourceIconSize)
        }

        return FolderMergeVisualMetrics.fullFolderAbsorbScale
    }

    fileprivate func mergeLandingDestination(in surface: LaunchpadPageSurface?, session: LaunchpadDragSession)
        -> CGPoint? {
        guard let surface, case .application(let sourceIdentity) = session.sourceEntry.item.id else { return nil }

        let visualEntry: LaunchpadPageEntry?
        let finalFolder: LauncherFolder?

        switch session.target {
        case .folder(let folderID):
            visualEntry = surface.entries.first { $0.item.id == .folder(folderID) }
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item, folder.id == folderID else { return nil }
                    return folder
                }.first

        case .application(let targetIdentity):
            // A same-page committed preview already contains the new folder.
            // Cross-page / conservative paths may still be rendering the target
            // application, so accept either visual owner for the same location.
            visualEntry =
                mergedFolderEntry(in: surface, for: session.target)
                ?? surface.entries.first { $0.item.id == .application(targetIdentity) }
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item else { return nil }
                    let ids = folder.applications.map(\.identity)
                    guard ids.contains(sourceIdentity), ids.contains(targetIdentity) else { return nil }
                    return folder
                }.first

        case .insertion, .pageInsertion, .outside: return nil
        }

        guard let visualEntry else { return nil }

        let landingScale = mergeLandingScale(session: session)
        let landingIconFrame = session.mergeLandingTargetIconFrame ?? visibleIconFrame(for: visualEntry)
        let targetCenter: CGPoint

        if let finalFolder,
            let sourceIndex = finalFolder.applications.firstIndex(where: { $0.identity == sourceIdentity }),
            let childCenter = AppTilePresentationFactory.folderChildCenter(
                iconFrame: landingIconFrame, logicalIndex: sourceIndex, layoutDirection: userInterfaceLayoutDirection) {
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
            y: session.sourceEntry.frames.icon.midY - session.sourceEntry.frames.cell.midY)

        return CGPoint(
            x: targetCenter.x - sourceIconOffset.x * landingScale, y: targetCenter.y - sourceIconOffset.y * landingScale
        )
    }

    fileprivate func completeDragInteraction(at point: CGPoint) {
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
        guard dragSession.draft.hasChanges, dragStateMachine.beginCommit() else {
            cancelDragInteraction()
            return
        }

        let committingSession = dragSession
        let draft = committingSession.draft
        let commitContext = LaunchpadDragCommitContext(session: committingSession)
        dragCommitContext = commitContext
        isCommittingLayout = true
        finishDragVisuals(dragSession, committed: true, animated: true) { [weak self, weak commitContext] in
            guard let self, let commitContext else { return }
            commitContext.completionState.markVisualsFinished()
            finishDragCommitIfReady(commitContext)
        }
        self.dragSession = nil
        pendingPress = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            await persistDragCommit(commitContext, draft: draft)
        }
    }

    fileprivate func persistDragCommit(_ commitContext: LaunchpadDragCommitContext, draft: LauncherLayoutDraft) async {
        let committingSession = commitContext.session
        do {
            layoutDocument = try await layoutStore.commit(draft)
            selectedIndex = -1
            if let metrics = currentMetrics {
                currentPage = min(currentPage, pageProjection(metrics: metrics).pageCount - 1)

                if let previewSurface = committingSession.previewSurface {
                    refreshCommittedPageCacheForCrossPageMergeIfNeeded(
                        committingSession, keeping: previewSurface, metrics: metrics)
                }
            }
            if adoptCommittedPreviewIfPossible(committingSession) {
                commitContext.didAdoptCommittedPreview = true
            } else {
                invalidatePageSurfaceCache()
            }

            commitContext.completionState.markPersistenceFinished()
        } catch {
            _ = dragStateMachine.beginRollback()
            if committingSession.folderCreationPreview != nil { closeFolder(animated: false) }
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

    fileprivate func refreshCommittedPageCacheForCrossPageMergeIfNeeded(
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

    fileprivate func adoptCommittedPreviewIfPossible(_ session: LaunchpadDragSession) -> Bool {
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

    fileprivate func finishDragCommitIfReady(_ context: LaunchpadDragCommitContext) {
        guard dragCommitContext === context, context.completionState.isReadyToFinalize else { return }

        dragCommitContext = nil

        // Keep isCommittingLayout=true until visual ownership AND AppKit hit
        // targets are ready. Unlocking here used to expose a visible tile with no
        // button for one run-loop turn; clicking it fell through to root mouseDown
        // and dismissed Launchpad.

        // When a drag preview has already been proven identical to the committed
        // document, keep that exact layer tree alive. Rebuilding it would flash
        // displaced apps at their final positions after a folder merge.
        if context.didAdoptCommittedPreview, let previewSurface = context.session.previewSurface {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            previewSurface.layer.opacity = openFolderID == nil ? 1 : 0

            previewSurface.layer.isHidden = false

            // Collapse every drag-only presentation state back to its model
            // value before pointer interaction becomes available again.
            for entry in previewSurface.entries {
                entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

                entry.tileLayer.removeAnimation(forKey: "dragReflowOpacity")

                entry.tileLayer.removeAnimation(forKey: "dragRollbackPosition")

                entry.tileLayer.opacity = 1

                entry.iconLayer.removeAnimation(forKey: "iconPressedOpacity")

                entry.iconLayer.opacity = 1

                entry.iconLayer.setAffineTransform(.identity)
            }

            CATransaction.commit()

            activeSurface = previewSurface

            pageContentLayer = previewSurface.layer

            attachButtons(to: previewSurface, hidden: openFolderID != nil)

            // Keep root AppKit ownership disabled while the Folder overlay is
            // open. closeFolder() will restore both root visibility and hit
            // targets through the normal Folder-close handoff.
            setFolderBackgroundVisible(openFolderID != nil, animated: false)
            setPageHitTargetsEnabled(openFolderID == nil)

            updateSelectionAppearance()

            if let metrics = currentMetrics {
                scheduleIconPrewarming(metrics: metrics, scale: window?.backingScaleFactor ?? 1)
            }

            // Preview layer + NSButtons are now atomically ready for input.
            isCommittingLayout = false
            retireFolderExtractionPointerOwnerAfterCommit(context.session)
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
        setFolderBackgroundVisible(openFolderID != nil, animated: false)
        setPageHitTargetsEnabled(openFolderID == nil)
        retireFolderExtractionPointerOwnerAfterCommit(context.session)
        dragStateMachine.finish()
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

    fileprivate func restoreSnapshotUI(afterFailedCommit session: LaunchpadDragSession) {
        currentPage = session.sourcePage
        session.originalSurface.layer.frame = bounds
        session.originalSurface.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Immutable source geometry also matters after crossing pages.
        do {
            CATransaction.begin()

            CATransaction.setDisableActions(true)

            for entry in session.originalSurface.entries {
                guard let originalFrame = session.originalFramesByIdentifier[entry.item.id] else { continue }

                entry.tileLayer.removeAllAnimations()

                entry.iconLayer.removeAllAnimations()

                entry.frames = originalFrame

                entry.absoluteIndex = session.originalIndexByIdentifier[entry.item.id] ?? entry.absoluteIndex

                entry.button.frame = originalFrame.icon

                entry.tileLayer.position = originalFrame.cell.center

                entry.tileLayer.opacity = 1

                entry.iconLayer.opacity = 1

                entry.iconLayer.setAffineTransform(.identity)
            }

            session.originalSurface.layer.opacity = 1

            session.originalSurface.layer.isHidden = false

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
        if session.sourceOrigin.folderID == nil, session.sourceEntry.tileLayer.superlayer == nil {
            session.originalSurface.layer.addSublayer(session.sourceEntry.tileLayer)
        }
        session.sourceEntry.tileLayer.opacity = 1
        session.sourceEntry.iconLayer.opacity = 1
        if session.sourceOrigin.folderID != nil { session.sourceEntry.button.removeFromSuperview() }
        if session.originalSurface.layer.superlayer == nil {
            rootLayer.insertSublayer(session.originalSurface.layer, below: fixedOverlayLayer)
        }
        CATransaction.commit()

        activeSurface = session.originalSurface
        pageContentLayer = session.originalSurface.layer
        attachButtons(to: session.originalSurface, hidden: false)
    }

    fileprivate func cancelDragInteraction(animated: Bool = true) {
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

        if dragSession.folderCreationPreview != nil { closeFolder(animated: false) }

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
        finishDragVisuals(dragSession, committed: false, animated: animated) { [weak self] in
            guard let self else { return }
            isFinishingDragVisuals = false
            dragStateMachine.finish()
            setPageHitTargetsEnabled(true)
            needsLayout = true
        }
        self.dragSession = nil
    }

    fileprivate func finishCrossPageRollback(
        _ session: LaunchpadDragSession, animated: Bool, completion: @escaping () -> Void
    ) {
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
        let configuration = PageSurfaceConfiguration(
            bounds: bounds, scale: scale, contentRevision: contentRevision, metrics: metrics)
        rebuildPageSurfaces(items: resolvedItems, metrics: metrics, scale: scale, configuration: configuration)
        guard let restored = pageSurfaces[currentPage],
            let source = restored.entries.first(where: { $0.item.id == session.sourceEntry.item.id })
        else {
            session.proxyLayer.removeFromSuperlayer()
            completion()
            return
        }
        activeSurface = restored
        pageContentLayer = restored.layer
        rootLayer.insertSublayer(restored.layer, below: fixedOverlayLayer)
        source.tileLayer.removeFromSuperlayer()
        updatePageIndicator(pageCount: pageProjection(metrics: metrics).pageCount, metrics: metrics, scale: scale)
        animateCrossPageRollback(
            session, source: source, restored: restored, animated: animated, completion: completion)
    }

    fileprivate func animateCrossPageRollback(
        _ session: LaunchpadDragSession, source: LaunchpadPageEntry, restored: LaunchpadPageSurface, animated: Bool,
        completion: @escaping () -> Void
    ) {
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

    fileprivate func makeDragProxy(for entry: LaunchpadPageEntry, initialPoint _: CGPoint) -> CALayer {
        let scale = max(1, window?.backingScaleFactor ?? 1)

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

    fileprivate func makeDragProxyLabel(for entry: LaunchpadPageEntry, scale: CGFloat, opacity: Float) -> CATextLayer {
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

    fileprivate func dragProxyLabelLayer(_ proxy: CALayer) -> CATextLayer? {
        proxy.sublayers?.first { $0.name == DragProxyMetrics.labelLayerName } as? CATextLayer
    }

    /// Refresh the steady-state icon backing store before landing. The label is
    /// a separate child layer, so its merge fade can never leave a spatial ghost.
    fileprivate func refreshDragProxyForRelease(
        _ proxy: CALayer, sourceEntry entry: LaunchpadPageEntry, hidesLabel: Bool = false
    ) {
        let scale = max(1, window?.backingScaleFactor ?? 1)

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

    fileprivate func snapshotImage(of layer: CALayer, scale: CGFloat) -> CGImage? {
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

    fileprivate func copiedLayer(_ source: CALayer) -> CALayer {
        let copy = CALayer(layer: source)
        copy.sublayers = source.sublayers?.map(copiedLayer)
        return copy
    }

    fileprivate func animateDragLift(_ layer: CALayer, from _: CGPoint, to point: CGPoint, offset: CGVector) {
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

    fileprivate func animateMergeProxyIntoFolder(
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

    fileprivate func restoreInPlaceDragTiles(
        _ session: LaunchpadDragSession, shouldAnimate: Bool, animation: DragLandingAnimation
    ) {
        let surface = session.originalSurface
        let sourceID = session.sourceEntry.item.id
        let duration = animation.duration
        let completionTransition = animation.transition
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

        CATransaction.setDisableActions(true)

        for entry in surface.entries {
            guard let originalFrame = session.originalFramesByIdentifier[entry.item.id] else { continue }

            let visiblePosition = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position

            entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

            entry.tileLayer.removeAnimation(forKey: "dragRollbackPosition")

            entry.tileLayer.removeAnimation(forKey: "dragReflowOpacity")

            entry.frames = originalFrame

            entry.absoluteIndex = session.originalIndexByIdentifier[entry.item.id] ?? entry.absoluteIndex

            entry.tileLayer.position = originalFrame.cell.center

            entry.tileLayer.opacity = 1

            if entry.item.id == sourceID {
                entry.tileLayer.removeFromSuperlayer()

                continue
            }

            entry.button.frame = originalFrame.icon

            guard shouldAnimate, visiblePosition != originalFrame.cell.center else { continue }

            let rollback = CABasicAnimation(keyPath: "position")

            rollback.fromValue = NSValue(point: visiblePosition)

            rollback.toValue = NSValue(point: originalFrame.cell.center)

            rollback.duration = duration

            rollback.timingFunction = completionTransition.timingFunction

            entry.tileLayer.add(rollback, forKey: "dragRollbackPosition")
        }

        CATransaction.commit()
    }

    fileprivate struct InPlaceDragLanding {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let revealsSource: Bool
    }

    fileprivate func inPlaceDragLanding(_ session: LaunchpadDragSession, committed: Bool) -> InPlaceDragLanding {
        let surface = session.originalSurface
        let proxy = session.proxyLayer
        let sourceID = session.sourceEntry.item.id
        let destination: CGPoint

        let destinationScale: CGFloat

        let destinationOpacity: Float

        let shouldRevealSource: Bool

        if committed {
            switch session.target {
            case .insertion, .pageInsertion:
                destination =
                    surface.entries.first { $0.item.id == sourceID }?.frames.cell.center
                    ?? session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1
                shouldRevealSource = true

            case .application, .folder:
                destination = mergeLandingDestination(in: surface, session: session) ?? proxy.position

                destinationScale = mergeLandingScale(session: session)
                destinationOpacity = 0
                shouldRevealSource = false

            case .outside:
                destination =
                    session.originalFramesByIdentifier[sourceID]?.cell.center ?? session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1
                shouldRevealSource = true
            }
        } else {
            destination =
                session.originalFramesByIdentifier[sourceID]?.cell.center ?? session.sourceEntry.frames.cell.center

            destinationScale = 1
            destinationOpacity = 1
            shouldRevealSource = true

        }

        return InPlaceDragLanding(
            position: destination, scale: destinationScale, opacity: destinationOpacity,
            revealsSource: shouldRevealSource)
    }

    fileprivate func finishInPlaceDragVisuals(
        _ session: LaunchpadDragSession, committed: Bool, animated: Bool, completion: (() -> Void)?
    ) {
        updateDropHighlight(.outside)

        let surface = session.originalSurface

        let proxy = session.proxyLayer

        let sourceID = session.sourceEntry.item.id

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let animation = dragLandingAnimation(session, committed: committed, shouldAnimate: shouldAnimate)

        let landing = inPlaceDragLanding(session, committed: committed)
        let shouldRevealSource = landing.revealsSource
        if !committed { restoreInPlaceDragTiles(session, shouldAnimate: shouldAnimate, animation: animation) }

        // Live source tile 不保留 mouseDown 狀態。
        CATransaction.begin()

        CATransaction.setDisableActions(true)

        surface.layer.opacity = 1

        surface.layer.isHidden = false

        session.sourceEntry.iconLayer.removeAnimation(forKey: "iconPressedOpacity")

        session.sourceEntry.iconLayer.opacity = 1

        session.sourceEntry.iconLayer.setAffineTransform(.identity)

        session.sourceEntry.tileLayer.opacity = 1

        CATransaction.commit()

        activeSurface = surface

        pageContentLayer = surface.layer

        let finalize: @MainActor () -> Void = { [weak proxy, weak sourceLayer = session.sourceEntry.tileLayer] in

            CATransaction.begin()

            CATransaction.setDisableActions(true)

            proxy?.removeAllAnimations()

            proxy?.opacity = 0

            proxy?.removeFromSuperlayer()

            if shouldRevealSource, let sourceLayer {
                sourceLayer.removeAllAnimations()

                sourceLayer.opacity = 1

                if sourceLayer.superlayer == nil {
                    // Proxy 已經先移除，
                    // 然後 live source 接手。
                    //
                    // 同一個 transaction，
                    // 不存在兩個 visual owner。
                    surface.layer.addSublayer(sourceLayer)
                }
            }

            // source NSButton 在 mouse tracking
            // 結束後才移到最後位置。
            if let frame = committed
                ? surface.entries.first(where: { $0.item.id == sourceID })?.frames
                : session.originalFramesByIdentifier[sourceID] {
                session.sourceEntry.button.frame = frame.icon
            }

            CATransaction.commit()

            completion?()
        }

        animateInPlaceLanding(
            proxy, landing: landing, animation: animation, shouldAnimate: shouldAnimate, finalize: finalize)
    }

    fileprivate func animateInPlaceLanding(
        _ proxy: CALayer, landing: InPlaceDragLanding, animation: DragLandingAnimation, shouldAnimate: Bool,
        finalize: @escaping @MainActor () -> Void
    ) {
        let destination = landing.position
        let destinationScale = landing.scale
        let destinationOpacity = landing.opacity
        let completionKind = animation.kind
        let completionTransition = animation.transition
        let duration = animation.duration
        guard shouldAnimate else {
            CATransaction.begin()

            CATransaction.setDisableActions(true)

            proxy.position = destination

            proxy.setAffineTransform(.init(scaleX: destinationScale, y: destinationScale))

            proxy.opacity = destinationOpacity

            CATransaction.commit()

            finalize()

            return
        }

        if completionKind == .merge {
            animateMergeProxyIntoFolder(
                proxy, destination: destination, destinationScale: destinationScale, duration: duration,
                timingFunction: completionTransition.timingFunction)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration))
                finalize()
            }
            return
        }

        CATransaction.begin()

        CATransaction.setAnimationDuration(duration)

        CATransaction.setAnimationTimingFunction(completionTransition.timingFunction)

        proxy.position = destination

        proxy.setAffineTransform(.init(scaleX: destinationScale, y: destinationScale))

        proxy.opacity = destinationOpacity

        CATransaction.commit()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))

            finalize()
        }
    }

    fileprivate func finishFolderCreationPreviewVisuals(
        _ session: LaunchpadDragSession, animated: Bool, completion: (() -> Void)?
    ) {
        guard let preview = session.folderCreationPreview else {
            completion?()
            return
        }

        updateDropHighlight(.outside)
        refreshDragProxyForRelease(session.proxyLayer, sourceEntry: session.sourceEntry, hidesLabel: true)

        let sourcePresentation = folderPresentation.folderPresentations.first {
            $0.button.application.id == preview.sourceIdentity
        }
        let destination =
            preview.sourceLandingCenter ?? sourcePresentation?.tileLayer.frame.center ?? session.proxyLayer.position
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = LaunchpadVisualStyle.dragCompletionTransition(kind: .insertion)
        // LAUNCHPANE_SPRING_OPEN_RELEASE_HANDOFF_V1
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
        CATransaction.setAnimationTimingFunction(transition.timingFunction)
        session.proxyLayer.position = destination
        session.proxyLayer.setAffineTransform(.identity)
        session.proxyLayer.opacity = 1
        CATransaction.commit()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            finalize()
        }
    }

    fileprivate func animateRollbackTiles(
        from previewSurface: LaunchpadPageSurface, to originalSurface: LaunchpadPageSurface,
        excluding sourceID: LauncherLayoutItemIdentifier, transition: LaunchpadVisualStyle.DragCompletionTransition
    ) {
        var originalPositions: [LauncherLayoutItemIdentifier: CGPoint] = [:]
        for entry in originalSurface.entries { originalPositions[entry.item.id] = entry.frames.cell.center }

        for entry in previewSurface.entries where entry.item.id != sourceID {
            guard let targetPosition = originalPositions[entry.item.id] else { continue }

            let visiblePosition = entry.tileLayer.presentation()?.position ?? entry.tileLayer.position

            entry.tileLayer.removeAnimation(forKey: "dragReflowPosition")

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.tileLayer.position = targetPosition
            CATransaction.commit()

            guard visiblePosition != targetPosition else { continue }

            let rollback = CABasicAnimation(keyPath: "position")
            rollback.fromValue = NSValue(point: visiblePosition)
            rollback.toValue = NSValue(point: targetPosition)
            rollback.duration = transition.duration
            rollback.timingFunction = transition.timingFunction
            entry.tileLayer.add(rollback, forKey: "dragRollbackPosition")
        }
    }

    fileprivate struct DragLanding {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        var revealLayer: CALayer?
        var revealSurface: LaunchpadPageSurface?
    }

    fileprivate func promoteDragPreviewSurface(_ session: LaunchpadDragSession) {
        if let previewSurface = session.previewSurface {
            // The preview becomes the sole visual owner while persistence is pending.
            // Remove the old native views before hiding/removing their backing layer so
            // transparent hit targets and accessibility elements cannot survive promotion.
            detachButtons(from: session.originalSurface)

            activeSurface = previewSurface

            pageContentLayer = previewSurface.layer

            // 原 surface 已經不需要顯示，
            // 但保留正確 model state，
            // 以防 layout commit 失敗。
            session.originalSurface.layer.removeFromSuperlayer()

            session.originalSurface.layer.opacity = 1

            session.sourceEntry.tileLayer.opacity = 1
        }
    }

    fileprivate func prepareDragLanding(_ session: LaunchpadDragSession, committed: Bool, shouldAnimate: Bool)
        -> DragLanding {
        let proxy = session.proxyLayer
        let previewSurface = session.previewSurface
        let originalSurface = session.originalSurface
        let sourceID = session.sourceEntry.item.id
        let originalSourceLayer = session.sourceEntry.tileLayer

        let destination: CGPoint
        let destinationScale: CGFloat
        let destinationOpacity: Float

        var revealLayer: CALayer?
        var revealSurface: LaunchpadPageSurface?

        if committed {
            switch session.target {
            case .insertion, .pageInsertion:
                let previewSource = previewSurface?.entries.first { $0.item.id == sourceID }

                destination = previewSource?.frames.cell.center ?? session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1

                revealLayer = previewSource?.tileLayer

                revealSurface = previewSurface

            case .application, .folder:
                destination = mergeLandingDestination(in: previewSurface, session: session) ?? proxy.position

                destinationScale = mergeLandingScale(session: session)
                destinationOpacity = 0

            case .outside:
                destination = session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1
            }

            promoteDragPreviewSurface(session)
        } else {
            destination = session.sourceEntry.frames.cell.center

            destinationScale = 1
            destinationOpacity = 1

            revealLayer = originalSourceLayer

            revealSurface = originalSurface

            if shouldAnimate, previewSurface != nil {
                // Keep the reordered preview visible while every displaced tile
                // travels back. Revealing the original surface here used to show
                // both layouts during the rollback and created a fading ghost.
                originalSurface.layer.opacity = 0
            } else {
                previewSurface?.layer.removeFromSuperlayer()

                originalSurface.layer.opacity = 1
            }

            activeSurface = originalSurface

            pageContentLayer = originalSurface.layer
        }

        return DragLanding(
            position: destination, scale: destinationScale, opacity: destinationOpacity, revealLayer: revealLayer,
            revealSurface: revealSurface)
    }

    fileprivate func promoteStationaryDragLanding(
        _ session: LaunchpadDragSession, committed: Bool, landing: inout DragLanding
    ) {
        let proxy = session.proxyLayer
        if committed, session.target.isInsertion, let liveLayer = landing.revealLayer,
            let liveSurface = landing.revealSurface {
            let visibleProxyPosition = proxy.presentation()?.position ?? proxy.position

            let landingDistance = hypot(
                visibleProxyPosition.x - landing.position.x, visibleProxyPosition.y - landing.position.y)

            // Less than one logical point is visually already landed.
            // Keeping the proxy around at this point only creates a stale frame.
            if landingDistance <= 0.75 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                proxy.removeAllAnimations()
                proxy.removeFromSuperlayer()

                if liveLayer.superlayer == nil { liveSurface.layer.addSublayer(liveLayer) }

                liveLayer.opacity = 1

                CATransaction.commit()

                // The delayed reflow completion must not perform the source-owner
                // handoff a second time.
                landing.revealLayer = nil
                landing.revealSurface = nil
            }
        }

    }

    fileprivate struct DragLandingAnimation {
        let kind: LaunchpadVisualStyle.DragCompletionKind
        let transition: LaunchpadVisualStyle.DragCompletionTransition
        let duration: CFTimeInterval
        let visualDuration: CFTimeInterval
    }

    fileprivate func dragLandingAnimation(_ session: LaunchpadDragSession, committed: Bool, shouldAnimate: Bool)
        -> DragLandingAnimation {
        let previewSurface = session.previewSurface
        let completionKind: LaunchpadVisualStyle.DragCompletionKind

        if !committed {
            completionKind = .rollback
        } else {
            switch session.target {
            case .insertion, .pageInsertion, .outside: completionKind = .insertion
            case .application, .folder: completionKind = .merge
            }
        }

        let completionTransition = LaunchpadVisualStyle.dragCompletionTransition(kind: completionKind)

        let duration: CFTimeInterval = shouldAnimate ? completionTransition.duration : 0

        let visualCompletionDuration: CFTimeInterval = {
            guard shouldAnimate, committed, previewSurface != nil else { return duration }

            switch session.target {
            case .application, .folder:
                // The source proxy can finish its short merge landing first, but
                // keep the preview alive until surrounding apps complete the same
                // reflow used by ordinary App exchanges.
                return duration + FolderMergeVisualMetrics.postLandingReflowDelay
                    + LaunchpadVisualStyle.dragReflowTransition(movedForward: false).duration
            case .insertion, .pageInsertion, .outside: return duration
            }
        }()

        return DragLandingAnimation(
            kind: completionKind, transition: completionTransition, duration: duration,
            visualDuration: visualCompletionDuration)
    }

    fileprivate func finishDragVisuals(
        _ session: LaunchpadDragSession, committed: Bool, animated: Bool, completion: (() -> Void)? = nil
    ) {
        if committed, session.folderCreationPreview != nil {
            finishFolderCreationPreviewVisuals(session, animated: animated, completion: completion)
            return
        }
        // Same-page reorder uses one persistent page tree.
        // Never enter the legacy preview/original surface
        // handoff path for this gesture.
        if session.usesInPlacePreview {
            finishInPlaceDragVisuals(session, committed: committed, animated: animated, completion: completion)
            return
        }

        updateDropHighlight(.outside)

        let proxy = session.proxyLayer

        // Mouse-up ends the pressed state immediately.
        //
        // The proxy may stay alive while surrounding tiles finish their reflow,
        // but its bitmap must no longer contain the mouse-down opacity / hover
        // transform. Otherwise the stale snapshot looks like an afterimage after
        // the user has already released the icon.
        refreshDragProxyForRelease(
            proxy, sourceEntry: session.sourceEntry, hidesLabel: session.isSourceLabelHiddenForMerge)

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let animation = dragLandingAnimation(session, committed: committed, shouldAnimate: shouldAnimate)

        var landing = prepareDragLanding(session, committed: committed, shouldAnimate: shouldAnimate)
        let destination = landing.position
        let destinationScale = landing.scale
        let destinationOpacity = landing.opacity

        session.sourceEntry.iconLayer.opacity = 1

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
        promoteStationaryDragLanding(session, committed: committed, landing: &landing)
        let revealLayer = landing.revealLayer
        let revealSurface = landing.revealSurface

        guard shouldAnimate else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            proxy.position = destination

            proxy.setAffineTransform(.init(scaleX: destinationScale, y: destinationScale))

            proxy.opacity = destinationOpacity

            proxy.removeFromSuperlayer()

            if let revealLayer, revealLayer.superlayer == nil, let revealSurface {
                revealSurface.layer.addSublayer(revealLayer)
            }
            revealLayer?.opacity = 1

            CATransaction.commit()
            completion?()
            return
        }

        animateDragLanding(
            session, committed: committed, landing: landing, animation: animation, completion: completion)
    }

    fileprivate func animateDragLanding(
        _ session: LaunchpadDragSession, committed: Bool, landing: DragLanding, animation: DragLandingAnimation,
        completion: (() -> Void)?
    ) {
        let proxy = session.proxyLayer
        let previewSurface = session.previewSurface
        let originalSurface = session.originalSurface
        let sourceID = session.sourceEntry.item.id
        let revealLayer = landing.revealLayer
        let revealSurface = landing.revealSurface
        let finishPresentation = { [weak proxy, weak revealLayer] in

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy?.removeFromSuperlayer()
            if !committed {
                previewSurface?.layer.removeFromSuperlayer()
                originalSurface.layer.opacity = 1
            }
            if let revealLayer, revealLayer.superlayer == nil, let revealSurface {
                revealSurface.layer.addSublayer(revealLayer)
            }
            revealLayer?.opacity = 1
            CATransaction.commit()
            completion?()
        }

        CATransaction.begin()

        CATransaction.setAnimationDuration(animation.duration)

        CATransaction.setAnimationTimingFunction(animation.transition.timingFunction)

        if !committed, let previewSurface {
            animateRollbackTiles(
                from: previewSurface, to: originalSurface, excluding: sourceID, transition: animation.transition)
        }

        if animation.kind == .merge {
            CATransaction.commit()

            animateMergeProxyIntoFolder(
                proxy, destination: landing.position, destinationScale: landing.scale, duration: animation.duration,
                timingFunction: animation.transition.timingFunction)
        } else {
            proxy.position = landing.position

            proxy.setAffineTransform(.init(scaleX: landing.scale, y: landing.scale))

            proxy.opacity = landing.opacity

            CATransaction.commit()
        }

        // A rollback can have displaced preview tiles still moving even when
        // the pointer has already brought the proxy back to its origin. In that
        // case the proxy creates no implicit animation, so a CATransaction
        // completion may fire before the visible rollback finishes. Drive the
        // handoff from the declared transition duration instead.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(animation.visualDuration))
            finishPresentation()
        }
    }

}

extension LaunchpadRootView {
    // MARK: - Folder child drag -> root drag handoff

    fileprivate func folderItemPointerDown(
        folderID: UUID, absoluteIndex: Int, frames: GridItemFrames,
        presentation: AppTilePresentation, event: NSEvent
    ) {
        let application = presentation.button.application
        guard openFolderID == folderID, dragSession == nil, folderItemDragSession == nil, !isCommittingLayout,
            !isFinishingDragVisuals, dragStateMachine.pointerDown(on: .application(application.id))
        else { return }

        if folderPresentation.folderTitleEditor != nil { finishFolderTitleEditing(commit: true) }

        let entry = LaunchpadPageEntry(
            item: .application(application), absoluteIndex: absoluteIndex, frames: frames,
            presentation: .application(presentation))
        pendingFolderPress = PendingFolderTilePress(
            folderID: folderID, entry: entry, point: convert(event.locationInWindow, from: nil))
        animatePressed(on: entry.iconLayer, isPressed: true)
    }

    fileprivate func folderItemPointerDragged(_ update: TilePointerDragUpdate) {
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
    fileprivate func retireFolderTrackingButtonAfterPointerCallback(_ button: PointerTrackingTileButton) {
        button.isEnabled = false
        button.isHidden = true

        Task { @MainActor [weak self, weak button] in
            // A cancellation path can still originate inside the AppKit
            // pointer callback. Yield one MainActor turn before detaching.
            await Task.yield()
            guard let button else { return }
            button.endPointerTrackingWithoutCallback()
            button.removeFromSuperview()

            // LAUNCHPANE_FOLDER_DRAG_RELEASE_OWNERSHIP_V22
            // Keep the pointer-owner sentinel alive for one additional main
            // turn after removal. didResignActive / click-through side effects
            // caused by AppKit teardown can be delivered synchronously or on
            // the following turn; clearing ownership before that reopened the
            // exact dismissal race this helper is meant to close.
            await Task.yield()
            if self?.preservedFolderTrackingButton === button { self?.preservedFolderTrackingButton = nil }
            self?.folderExtractionActivationShield = false
        }
    }

    fileprivate func retireFolderExtractionPointerOwnerAfterCommit(_ session: LaunchpadDragSession) {
        guard session.sourceOrigin.folderID != nil else { return }

        // The Folder-owned AppKit view is intentionally retained beyond
        // mouseUp. Root landing and layout persistence can continue to use
        // the source session for several frames, and releasing the last
        // pointer owner before that handoff completes can transiently
        // deactivate the accessory app. Retire it only when the root commit
        // has reached its final presentation state.
        let pointerOwner = preservedFolderTrackingButton ?? (session.sourceEntry.button as? AppTileButton)

        guard let pointerOwner else {
            folderExtractionActivationShield = false
            return
        }

        // Use the same retirement path as Folder-local reorder. Keeping the
        // preserved owner alive through removal plus one extra main turn
        // closes both extraction and in-Folder release races with one invariant.
        retireFolderTrackingButtonAfterPointerCallback(pointerOwner)
    }

    fileprivate func folderItemPointerUp(_ release: TilePointerRelease) {
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
            if context.isEdgePageTurnInFlight || folderPageTransitionAnimator.isAnimating {
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
        dragStateMachine.finish()
    }

    fileprivate func folderItemPointerCancelled() {
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
        dragStateMachine.finish()
    }

    fileprivate func beginFolderItemDrag(at point: CGPoint) {
        guard let pendingFolderPress, let sourceButton = pendingFolderPress.entry.button as? AppTileButton,
            let sourceTileParent = pendingFolderPress.entry.tileLayer.superlayer,
            let sourceFolder = resolvedFolder(id: pendingFolderPress.folderID), dragStateMachine.beginDragging()
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
            baselineApplications: sourceFolder.applications, sourcePage: folderPage, sourceTileParent: sourceTileParent,
            sourceTileIndex: sourceTileIndex)
        folderItemDragSession = context
        context.lastPointerPoint = point
        context.lastProxyCenter = CGPoint(x: point.x - context.pointerOffset.dx, y: point.y - context.pointerOffset.dy)

        // A Folder page turn may retire the presentation surface that
        // originally owned mouseDown. Preserve that exact AppKit button for
        // the entire drag and hide the source identity from any page surface
        // rebuilt while we travel across pages.
        preservedFolderTrackingButton = sourceButton
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
        animateDragLift(proxy, from: pendingFolderPress.entry.frames.cell.center, to: point, offset: pointerOffset)
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
        if context.isEdgePageTurnInFlight || folderPageTransitionAnimator.isAnimating { return }

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

    fileprivate func cancelFolderItemDragEdgePaging(_ context: FolderItemDragSession) {
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
            !folderPageTransitionAnimator.isAnimating, interactiveFolderPageSwipe == nil
        else { return false }

        guard let direction = folderDragEdgeDirection(at: center, metrics: geometry.metrics) else {
            if context.edgePagingTask != nil || context.edgePagingDirection != nil {
                cancelFolderItemDragEdgePaging(context)
            }
            return false
        }

        let targetPage = folderPage + direction
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
                !context.isEdgePageTurnInFlight, !self.folderPageTransitionAnimator.isAnimating,
                let geometry = self.folderReorderGeometry(),
                self.folderDragEdgeDirection(at: context.lastProxyCenter, metrics: geometry.metrics) == direction
            else { return }

            self.performFolderItemDragEdgePageTurn(direction: direction, context: context)
        }
        return true
    }

    fileprivate func performFolderItemDragEdgePageTurn(direction: Int, context: FolderItemDragSession) {
        guard folderItemDragSession === context, let geometry = folderReorderGeometry(),
            geometry.folder.id == context.folderID, let viewportLayer = folderPageViewportLayer,
            !folderPageTransitionAnimator.isAnimating, interactiveFolderPageSwipe == nil,
            let outgoing = folderPageSurfaces[folderPage]
        else { return }

        let targetPage = folderPage + direction
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
        _ = dragStateMachine.update(
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
        let stalePageIndices = folderPageSurfaces.compactMap { pageIndex, surface in
            surface === outgoing ? nil : pageIndex
        }
        for pageIndex in stalePageIndices {
            guard let surface = folderPageSurfaces.removeValue(forKey: pageIndex) else { continue }
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
        self.folderPageSurfaces.removeAll(keepingCapacity: true)
        self.folderPageSurfaces[targetPage] = incoming
        self.folderPage = targetPage
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

    fileprivate func hideFolderDragSource(in incoming: FolderPageSurface, context: FolderItemDragSession) {
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
            _ = dragStateMachine.update(
                target: .pageInsertion(page: folderPage, index: max(0, destination - geometry.pageStartIndex)))
        }
        previewFolderItemReorder(
            context, destinationAbsoluteIndex: destination, previousDestinationAbsoluteIndex: previousDestination)
    }

    fileprivate struct FolderReorderGeometry {
        let folder: ResolvedLaunchpadFolder
        let metrics: FolderGridMetrics
        let pageStartIndex: Int
        let visibleCount: Int
    }

    fileprivate func folderReorderGeometry() -> FolderReorderGeometry? {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return nil }

        let allMetrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let pageStartIndex = folderPage * allMetrics.itemsPerPage
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

    fileprivate func restoreFolderItemReorderPreview(_ context: FolderItemDragSession, animated: Bool) {
        let previousDestination = context.destinationAbsoluteIndex
        context.destinationAbsoluteIndex = context.sourceAbsoluteIndex
        previewFolderItemReorder(
            context, destinationAbsoluteIndex: context.sourceAbsoluteIndex,
            previousDestinationAbsoluteIndex: previousDestination, animated: animated)
    }

    /// Adopt the already-visible reorder instead of replacing the folder's
    /// panel, icon bitmaps, and raster caches at the end of the landing.
    /// Called inside the same disabled-actions transaction that retires the proxy.
    fileprivate func adoptCommittedFolderReorder(_ context: FolderItemDragSession) -> Bool {
        guard openFolderID == context.folderID, let geometry = folderReorderGeometry(),
            let surface = folderPageSurfaces[folderPage], surface.layer.superlayer != nil,
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
        folderPageContentLayer = surface.layer
        folderPageSurfaces = [
            folderPage: FolderPageSurface(
                pageIndex: folderPage, layer: surface.layer, presentations: presentations, applications: applications)
        ]
        updateFolderSelectionAppearance(itemsPerPage: geometry.metrics.itemsPerPage)
        stageAdjacentFolderPageSurfaces(
            folder: geometry.folder, metrics: geometry.metrics,
            scale: window?.backingScaleFactor ?? displayContext.backingScaleFactor)

        finishFolderTrackingAfterReorder(context, presentations: presentations)
        return true
    }

    fileprivate func retireOffscreenFolderReorderPages() {
        // Offscreen pages still describe the old order; retire only those.
        for (page, cached) in folderPageSurfaces where page != folderPage {
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
            preservedFolderTrackingButton = nil
            folderExtractionActivationShield = false
        } else {
            context.sourceEntry.tileLayer.removeFromSuperlayer()
            retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
        }
    }

    fileprivate func updateFolderDropPreview(_ context: FolderItemDragSession, at center: CGPoint) {
        if let destination = folderReorderTargetIndex(at: center, context: context) {
            let previousDestination = context.destinationAbsoluteIndex
            context.destinationAbsoluteIndex = destination
            previewFolderItemReorder(
                context, destinationAbsoluteIndex: destination, previousDestinationAbsoluteIndex: previousDestination)
        }

    }

    fileprivate func completeFolderItemReorder(_ context: FolderItemDragSession, at center: CGPoint) {
        guard folderItemDragSession === context else { return }
        updateFolderDropPreview(context, at: center)

        guard context.destinationAbsoluteIndex != context.sourceAbsoluteIndex, let geometry = folderReorderGeometry(),
            geometry.folder.id == context.folderID, case .application(let sourceApplication) = context.sourceEntry.item
        else {
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }

        let draft: LauncherLayoutDraft
        do {
            var candidate = try LauncherLayoutDraft(document: layoutDocument)
            try candidate.moveApplication(
                sourceApplication.id, inFolder: context.folderID, toIndex: context.destinationAbsoluteIndex)
            guard candidate.hasChanges else {
                cancelFolderItemDragBeforeExit(animated: true)
                return
            }
            draft = candidate
        } catch {
            NSSound.beep()
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }

        let destinationLocalIndexForState = max(0, context.destinationAbsoluteIndex - geometry.pageStartIndex)
        _ = dragStateMachine.update(target: .pageInsertion(page: folderPage, index: destinationLocalIndexForState))
        guard dragStateMachine.beginCommit() else {
            cancelFolderItemDragBeforeExit(animated: true)
            return
        }

        cancelFolderItemDragEdgePaging(context)
        folderItemDragSession = nil
        pendingFolderPress = nil
        isCommittingLayout = true
        context.trackingButton.isEnabled = false
        context.trackingButton.isHidden = true

        let destinationLocalIndex = context.destinationAbsoluteIndex - geometry.pageStartIndex
        let destinationCenter =
            folderPageItemFrames(
                localIndex: destinationLocalIndex, visibleCount: geometry.visibleCount, metrics: geometry.metrics)?.cell
            .center ?? context.proxyLayer.position

        let (landingStartMediaTime, landingDuration) = animateFolderReorderLanding(context, to: destinationCenter)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await persistFolderReorder(
                context, draft: draft, landingStartMediaTime: landingStartMediaTime, landingDuration: landingDuration)
        }
    }

    fileprivate func animateFolderReorderLanding(_ context: FolderItemDragSession, to destinationCenter: CGPoint) -> (
        CFTimeInterval, CFTimeInterval
    ) {
        // Match the root-grid committed insertion landing exactly.
        // The old Folder-local 0.12 s ease-out made the dragged child snap
        // noticeably faster than the surrounding root-style reflow.
        let landingTransition = LaunchpadVisualStyle.dragCompletionTransition(kind: .insertion)
        let landingDuration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : landingTransition.duration
        let landingStartMediaTime = CACurrentMediaTime()

        CATransaction.begin()
        if landingDuration > 0 {
            CATransaction.setAnimationDuration(landingDuration)
            CATransaction.setAnimationTimingFunction(landingTransition.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        context.proxyLayer.position = destinationCenter
        context.proxyLayer.setAffineTransform(.identity)
        context.proxyLayer.opacity = 1
        CATransaction.commit()

        return (landingStartMediaTime, landingDuration)
    }

    fileprivate func persistFolderReorder(
        _ context: FolderItemDragSession, draft: LauncherLayoutDraft, landingStartMediaTime: CFTimeInterval,
        landingDuration: CFTimeInterval
    ) async {
        do {
            let committedDocument = try await layoutStore.commit(draft)

            // A fast layout-store write must not remove the proxy before
            // the root-style landing animation has visibly completed.
            let elapsed = CACurrentMediaTime() - landingStartMediaTime
            let remaining = max(0, landingDuration - elapsed)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutDocument = committedDocument
            invalidatePageSurfaceCache()
            if !adoptCommittedFolderReorder(context) {
                context.sourceEntry.tileLayer.removeFromSuperlayer()
                folderHiddenApplicationID = nil
                if openFolderID == context.folderID {
                    renderFolderOverlay(animated: false)
                } else {
                    needsLayout = true
                    layoutSubtreeIfNeeded()
                }
                retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
            }
            // The destination owns the full-resolution artwork before
            // its proxy disappears, without implicit layer cross-fades.
            context.proxyLayer.removeAllAnimations()
            context.proxyLayer.removeFromSuperlayer()
            CATransaction.commit()
        } catch {
            NSSound.beep()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            folderHiddenApplicationID = nil
            if openFolderID == context.folderID {
                renderFolderOverlay(animated: false)
            } else {
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
            context.proxyLayer.removeAllAnimations()
            context.proxyLayer.removeFromSuperlayer()
            CATransaction.commit()
            retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
            _ = dragStateMachine.beginRollback()
        }
        isCommittingLayout = false
        dragStateMachine.finish()
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
        folderExtractionActivationShield = true

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

    fileprivate func cancelFolderItemDragBeforeExit(animated: Bool) {
        pendingFolderPress = nil
        guard let context = folderItemDragSession else {
            dragStateMachine.finish()
            return
        }
        cancelFolderItemDragEdgePaging(context)
        if context.hasCrossedPages, folderPage != context.sourcePage {
            finishFolderCrossPageRollback(context, animated: animated)
            return
        }
        folderItemDragSession = nil
        folderHiddenApplicationID = nil
        // Keep preservedFolderTrackingButton until the rollback has restored
        // a live hit target. Clearing it here re-opened the same transient
        // resign-active gap as a committed drop.
        restoreFolderItemReorderPreview(context, animated: animated)
        _ = dragStateMachine.beginRollback()

        let finish = folderRollbackCompletion(context)

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

    fileprivate func folderRollbackCompletion(_ context: FolderItemDragSession) -> @MainActor () -> Void {
        let sourceParent = context.sourceTileParent
        let sourceIndex = context.sourceTileIndex
        let proxy = context.proxyLayer
        let sourceLayer = context.sourceEntry.tileLayer
        let iconLayer = context.sourceEntry.iconLayer
        return { [weak self, weak proxy, weak sourceLayer, weak iconLayer] in
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

            self?.restoreFolderPointerOwnerAfterRollback(context)

            proxy?.removeAllAnimations()
            proxy?.removeFromSuperlayer()
            CATransaction.commit()
            self?.dragStateMachine.finish()
        }

    }

    fileprivate func restoreFolderPointerOwnerAfterRollback(_ context: FolderItemDragSession) {
        // A drag can travel far enough for its original page surface to
        // be evicted and rebuilt. Reveal whichever source presentation
        // is current, and retire the old transparent AppKit pointer owner
        // if that rebuilt surface owns a different button.
        self.folderHiddenApplicationID = nil
        if case .application(let application) = context.sourceEntry.item,
            let livePresentation = self.folderPresentation.folderPresentations.first(where: {
                $0.button.application.id == application.id
            }) {
            livePresentation.tileLayer.opacity = 1
            livePresentation.button.isHidden = false
            livePresentation.button.isEnabled = true
            if livePresentation.button === context.trackingButton {
                // Same surface/button regained ownership; no AppKit view
                // teardown is needed at all.
                context.trackingButton.endPointerTrackingWithoutCallback()
                self.preservedFolderTrackingButton = nil
            } else {
                self.retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
            }
        } else {
            self.retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
        }

    }

    // LAUNCHPANE_FOLDER_DRAG_ROOT_PARITY_V19
    fileprivate func finishFolderCrossPageRollback(_ context: FolderItemDragSession, animated: Bool) {
        guard folderItemDragSession === context, let folder = resolvedFolder(id: context.folderID),
            let viewportLayer = folderPageViewportLayer
        else {
            folderItemDragSession = nil
            dragStateMachine.finish()
            return
        }

        _ = dragStateMachine.beginRollback()
        context.edgePagingGeneration &+= 1
        context.edgePagingTask?.cancel()
        context.edgePagingTask = nil
        context.isEdgePageTurnInFlight = true

        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: context.baselineApplications.count)
        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        let baselineFolder = ResolvedLaunchpadFolder(
            id: folder.id, title: folder.title, applications: context.baselineApplications)
        let built = makeFolderPageLayer(
            folder: baselineFolder, metrics: metrics, pageIndex: context.sourcePage, scale: scale)
        let restored = FolderPageSurface(
            pageIndex: context.sourcePage, layer: built.layer, presentations: built.presentations,
            applications: built.applications)
        hideFolderDragSource(in: restored, context: context)

        let outgoing = folderPageSurfaces[folderPage]
        let resting = metrics.panelFrame.center
        let width = max(1, metrics.panelFrame.width)
        let direction = context.sourcePage < folderPage ? -1 : 1
        let visualDirection = CGFloat(metrics.isRightToLeft ? -direction : direction)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing?.layer.removeAllAnimations()
        outgoing?.layer.position = resting
        outgoing?.layer.isHidden = false
        restored.layer.removeAllAnimations()
        restored.layer.position = CGPoint(x: resting.x + visualDirection * width, y: resting.y)
        restored.layer.isHidden = false
        if restored.layer.superlayer == nil { viewportLayer.addSublayer(restored.layer) }
        CATransaction.commit()

        let transition = FolderRollbackTransition(
            outgoing: outgoing, restored: restored, metrics: metrics, baselineFolder: baselineFolder, scale: scale,
            resting: resting, width: width, visualDirection: visualDirection)
        let finishPageReturn: @MainActor () -> Void = { [weak self, weak context] in
            guard let self, let context, self.folderItemDragSession === context else { return }
            self.finishFolderPageReturn(context, transition: transition, animated: animated)
        }
        animateFolderPageReturn(transition, animated: animated, finishPageReturn: finishPageReturn)
    }

    fileprivate struct FolderRollbackTransition {
        let outgoing: FolderPageSurface?
        let restored: FolderPageSurface
        let metrics: FolderGridMetrics
        let baselineFolder: ResolvedLaunchpadFolder
        let scale: CGFloat
        let resting: CGPoint
        let width: CGFloat
        let visualDirection: CGFloat
    }

    fileprivate func finishFolderPageReturn(
        _ context: FolderItemDragSession, transition: FolderRollbackTransition, animated: Bool
    ) {
        let outgoing = transition.outgoing
        let restored = transition.restored
        let resting = transition.resting
        let metrics = transition.metrics
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing?.layer.removeAllAnimations()
        outgoing?.layer.removeFromSuperlayer()
        restored.layer.removeAllAnimations()
        restored.layer.position = resting
        CATransaction.commit()

        self.folderPage = context.sourcePage
        if let outgoing { self.detachFolderButtons(from: outgoing) }
        self.folderPageSurfaces.removeAll(keepingCapacity: true)
        self.folderPageSurfaces[context.sourcePage] = restored
        self.folderPresentation.folderPresentations = restored.presentations
        self.updateFolderPageIndicator(pageCount: metrics.pageCount)

        let sourceLocalIndex = context.sourceAbsoluteIndex - context.sourcePage * metrics.itemsPerPage
        let destination =
            self.folderPageItemFrames(
                localIndex: sourceLocalIndex, visibleCount: restored.applications.count, metrics: metrics)?.cell.center
            ?? context.sourceEntry.frames.cell.center
        let style = LaunchpadVisualStyle.dragCompletionTransition(kind: .rollback)
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? style.duration : 0

        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(style.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        context.proxyLayer.position = destination
        context.proxyLayer.setAffineTransform(.identity)
        context.proxyLayer.opacity = 1
        CATransaction.commit()

        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            self.finishFolderRollbackLanding(context, transition: transition)
        }
    }

    fileprivate func finishFolderRollbackLanding(
        _ context: FolderItemDragSession, transition: FolderRollbackTransition) {
        let restored = transition.restored
        let metrics = transition.metrics
        let baselineFolder = transition.baselineFolder
        let scale = transition.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.proxyLayer.removeAllAnimations()
        context.proxyLayer.removeFromSuperlayer()
        self.folderHiddenApplicationID = nil
        if case .application(let sourceApplication) = context.sourceEntry.item,
            let livePresentation = restored.presentations.first(where: {
                $0.button.application.id == sourceApplication.id
            }) {
            livePresentation.tileLayer.opacity = 1
            self.attachFolderButtons(to: restored, hidden: false)
        }
        if restored.presentations.contains(where: { $0.button === context.trackingButton }) {
            context.trackingButton.endPointerTrackingWithoutCallback()
            context.trackingButton.isHidden = false
            context.trackingButton.isEnabled = true
            self.preservedFolderTrackingButton = nil
        } else {
            self.retireFolderTrackingButtonAfterPointerCallback(context.trackingButton)
        }
        CATransaction.commit()
        self.folderItemDragSession = nil
        self.pendingFolderPress = nil
        self.dragStateMachine.finish()
        self.stageAdjacentFolderPageSurfaces(folder: baselineFolder, metrics: metrics, scale: scale)
    }

    fileprivate func animateFolderPageReturn(
        _ transition: FolderRollbackTransition, animated: Bool, finishPageReturn: @escaping @MainActor () -> Void
    ) {
        let outgoing = transition.outgoing
        let restored = transition.restored
        let resting = transition.resting
        let width = transition.width
        let visualDirection = transition.visualDirection
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishPageReturn()
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
        CATransaction.setCompletionBlock { Task { @MainActor in finishPageReturn() } }
        let outgoingEnd = CGPoint(x: resting.x - visualDirection * width, y: resting.y)
        outgoing?.layer.position = outgoingEnd
        restored.layer.position = resting
        if let outgoing { outgoing.layer.add(animation(resting, outgoingEnd), forKey: "folderCrossPageRollbackOut") }
        restored.layer.add(
            animation(CGPoint(x: resting.x + visualDirection * width, y: resting.y), resting),
            forKey: "folderCrossPageRollbackIn")
        CATransaction.commit()
    }

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
        dragStateMachine.finish()

        if let metrics = currentMetrics {
            updatePageIndicator(
                pageCount: pageProjection(metrics: metrics).pageCount, metrics: metrics,
                scale: window?.backingScaleFactor ?? 1)
        }
        openFolder(folderID, sourceFrame: folderSourceFrame(for: folderID))
    }

    fileprivate func openFolder(_ folderID: UUID, sourceFrame: CGRect? = nil) {
        guard resolvedFolder(id: folderID) != nil else { return }

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Folder interaction owns the foreground. Stop opportunistic root/session
        // icon decoding before the zoom starts so Core Animation does not compete
        // with AppKit image decode/upload work during the 210ms transition.
        cancelIconPrewarming()
        iconPrewarmTasks.cancelPresentation()

        folderPresentation.folderAnimationSourceFrame = sourceFrame ?? folderSourceFrame(for: folderID)
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

    fileprivate func folderSourceFrame(for folderID: UUID) -> CGRect? {
        activeSurface?.entries.first { $0.item.folderID == folderID }?.frames.icon
    }

    func resolvedFolder(id: UUID) -> ResolvedLaunchpadFolder? {
        let document: LauncherLayoutDocument
        if let session = dragSession, session.folderCreationPreview?.folderID == id {
            document = session.draft.document
        } else {
            document = layoutDocument
        }

        return ResolvedLaunchpadItemFactory.makeItems(document: document, applications: applications, query: "").first {
            $0.id == .folder(id)
        }.flatMap {
            guard case .folder(let folder) = $0 else { return nil }
            return folder
        }
    }

    fileprivate func setFolderBackgroundVisible(_ visible: Bool, animated: Bool) {
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

    fileprivate struct FolderOverlayRenderContext {
        let folder: ResolvedLaunchpadFolder
        let metrics: FolderGridMetrics
        let scale: CGFloat
        let page: Int
        let generation: Int

        var startIndex: Int { page * metrics.itemsPerPage }
        let visibleApplications: [ApplicationRecord]

        init(folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, scale: CGFloat, page: Int, generation: Int) {
            self.folder = folder
            self.metrics = metrics
            self.scale = scale
            self.page = page
            self.generation = generation
            let start = page * metrics.itemsPerPage
            let end = min(start + metrics.itemsPerPage, folder.applications.count)
            visibleApplications = Array(folder.applications[start..<end])
        }
    }

    func renderFolderOverlay(animated: Bool) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else {
            closeFolder(animated: false)
            return
        }
        folderPresentation.invalidateAnimation()
        resetFolderOverlayRendering()
        let scale = window?.backingScaleFactor ?? 1
        // Resolve one geometry for the whole folder so partial pages retain the same grid.
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        folderPage = min(folderPage, max(0, metrics.pageCount - 1))
        folderPresentation.folderPanelFrame = metrics.panelFrame
        let context = FolderOverlayRenderContext(
            folder: folder, metrics: metrics, scale: scale, page: folderPage,
                generation: folderPresentation.folderAnimationGeneration)
        let visualScale = max(1, metrics.iconSize / max(1, solver.tokens.preferredIconSize))
        let (contentLayer, dimLayer) = makeFolderOverlayContainer(
            metrics: metrics, scale: scale, folderVisualScale: visualScale, animated: animated)
        FolderOverlayPresentationFactory.addPanel(to: contentLayer, metrics: metrics, folderVisualScale: visualScale)
        let title = FolderOverlayPresentationFactory.addTitle(
            to: contentLayer, folder: folder, metrics: metrics, scale: scale, folderVisualScale: visualScale)
        folderPresentation.folderTitleLayer = title.layer
        folderPresentation.folderTitleFrame = metrics.titleFrame
        folderPresentation.folderTitleHitFrame = title.hitFrame
        populateFolderOverlay(contentLayer: contentLayer, context: context, animated: animated)
        addFolderPageIndicator(to: contentLayer, context: context, folderVisualScale: visualScale)
        animateFolderOverlay(context: context, contentLayer: contentLayer, dimLayer: dimLayer, animated: animated)
    }

    fileprivate func resetFolderOverlayRendering() {
        folderPresentation.folderIconTask?.cancel()
        cancelInteractiveFolderPageSwipeImmediately()
        folderPageSwipeInputGate = PageSwipeInputGate()
        for surface in folderPageSurfaces.values {
            detachFolderButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.removeFromSuperlayer()
        }
        folderPageSurfaces.removeAll(keepingCapacity: true)

        if let currentFolderPageLayer = folderPageContentLayer {
            folderPageTransitionAnimator.reset(
                contentLayer: currentFolderPageLayer,
                canvasBounds: folderPageViewportLayer?.bounds ?? currentFolderPageLayer.bounds)
        }
        folderPageViewportLayer = nil
        folderPageContentLayer = nil
        folderPageIndicatorLayer = nil

        removeFolderButtons()
        folderPresentation.folderTitleLayer = nil
        folderPresentation.folderTitleFrame = .zero
        folderPresentation.folderTitleHitFrame = .zero
        folderPresentation.folderOverlayLayer.removeAllAnimations()
        folderPresentation.folderOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        folderPresentation.folderOverlayLayer.opacity = 1
        folderPresentation.folderOverlayLayer.isHidden = false

    }

    fileprivate func makeFolderOverlayContainer(
        metrics: FolderGridMetrics, scale: CGFloat, folderVisualScale: CGFloat, animated: Bool
    ) -> (CALayer, CALayer) {
        let sourceFrame = folderPresentation.folderAnimationSourceFrame
        let sourcePoint = sourceFrame?.center ?? metrics.panelFrame.center

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Animate/rasterize only the visual folder region, not a transparent
        // full-screen 4K layer. A small safety inset includes the panel shadow.
        // Keeping the layer's bounds origin in screen coordinates means all
        // existing child frames/reorder positions remain valid unchanged.
        let visualPadding = max(48, 52 * folderVisualScale)
        let proposedVisualBounds = metrics.panelFrame.union(metrics.titleFrame).insetBy(
            dx: -visualPadding, dy: -visualPadding)
        let clippedVisualBounds = proposedVisualBounds.intersection(bounds)
        let folderVisualBounds =
            clippedVisualBounds.isNull || clippedVisualBounds.isEmpty ? proposedVisualBounds : clippedVisualBounds
        let normalizedAnchor = CGPoint(
            x: folderVisualBounds.width > 0
                ? (sourcePoint.x - folderVisualBounds.minX) / folderVisualBounds.width : 0.5,
            y: folderVisualBounds.height > 0
                ? (sourcePoint.y - folderVisualBounds.minY) / folderVisualBounds.height : 0.5)

        let dimLayer = CALayer()
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.clear.cgColor
        dimLayer.opacity = 1
        folderPresentation.folderOverlayLayer.addSublayer(dimLayer)
        folderPresentation.folderDimAnimationLayer = dimLayer

        // All folder visuals live in one tightly-bounded container. Scaling this
        // layer around the source tile makes the panel, title and icons expand
        // together while avoiding a full-screen 4K compositing surface.
        let contentLayer = CALayer()
        contentLayer.bounds = folderVisualBounds
        contentLayer.anchorPoint = normalizedAnchor
        contentLayer.position = sourcePoint
        contentLayer.opacity = 1
        contentLayer.contentsScale = scale

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // During open/close animation flatten the complex subtree (up to 35
        // icons, labels and shadows) into one compositor-friendly surface.
        // Disable it as soon as animation ends so the resting folder stays live
        // and the temporary raster cache is released.
        contentLayer.shouldRasterize = animated
        contentLayer.rasterizationScale = max(1, scale)

        folderPresentation.folderOverlayLayer.addSublayer(contentLayer)
        folderPresentation.folderContentAnimationLayer = contentLayer

        return (contentLayer, dimLayer)
    }

    fileprivate func populateFolderOverlay(contentLayer: CALayer, context: FolderOverlayRenderContext, animated: Bool) {
        let metrics = context.metrics
        let scale = context.scale
        let visibleApplications = context.visibleApplications
        // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14
        // Keep the panel/title fixed while the page contents slide behind a
        // clipped viewport, matching the root Launchpad page composition.
        let pageViewportLayer = CALayer()
        pageViewportLayer.bounds = metrics.panelFrame
        pageViewportLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pageViewportLayer.position = metrics.panelFrame.center
        pageViewportLayer.masksToBounds = true
        pageViewportLayer.contentsScale = scale
        contentLayer.addSublayer(pageViewportLayer)
        folderPageViewportLayer = pageViewportLayer

        let pageLayer = CALayer()
        pageLayer.bounds = metrics.panelFrame
        pageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pageLayer.position = metrics.panelFrame.center
        pageLayer.contentsScale = scale
        pageViewportLayer.addSublayer(pageLayer)
        folderPageContentLayer = pageLayer

        for (localIndex, application) in visibleApplications.enumerated() {
            guard
                let presentation = makeFolderOverlayTile(
                    application: application, localIndex: localIndex, context: context, animated: animated)
            else { continue }
            pageLayer.addSublayer(presentation.tileLayer)
            addSubview(presentation.button)
            folderPresentation.folderPresentations.append(presentation)
        }

        // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
        // Root paging never builds its incoming page at gesture time; surfaces
        // already exist. Keep the current folder page in the same kind of cache
        // and stage its neighbor after the opening animation.
        folderPageSurfaces = [
            folderPage: FolderPageSurface(
                pageIndex: folderPage, layer: pageLayer, presentations: folderPresentation.folderPresentations,
                applications: visibleApplications)
        ]

    }

    fileprivate func makeFolderOverlayTile(
        application: ApplicationRecord, localIndex: Int, context: FolderOverlayRenderContext, animated: Bool
    ) -> AppTilePresentation? {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        let startIndex = context.startIndex
        let visibleApplications = context.visibleApplications
        guard
            let frames = folderPageItemFrames(
                localIndex: localIndex, visibleCount: visibleApplications.count, metrics: metrics)
        else { return nil }
        let presentation = AppTilePresentationFactory.make(
            AppTileRenderInput(
                application: application, cellFrame: frames.cell, iconFrame: frames.icon, labelFrame: frames.label,
                scale: scale, selected: startIndex + localIndex == folderSelectedIndex,
                // LAUNCHPANE_FOLDER_LOW_RES_FALLBACK_V6
                // If the exact HQ bitmap has not landed yet, show the best
                // resident miniature immediately instead of a blank icon.
                icon: iconCache.bestAvailableCGImage(for: application, pointSize: metrics.iconSize, scale: scale)))
        // LAUNCHPANE_FOLDER_CHILD_NO_RASTER_CACHE_V6
        // Folder children are already inside one animated content container
        // and do not participate in root-page swipes. Avoid allocating a
        // second Retina raster surface per child during the open animation.
        presentation.tileLayer.shouldRasterize = false
        presentation.tileLayer.rasterizationScale = 1
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

        presentation.button.onHoverChanged = { [weak iconLayer = presentation.iconLayer, weak self] isHovering in
            self?.animateHover(on: iconLayer, isHovering: isHovering)
        }
        presentation.button.onPointerDown = { [weak self, weak presentation] event in
            guard let self, let presentation else { return }
            self.folderItemPointerDown(
                // LAUNCHPANE_FOLDER_COMPILE_REPAIR_V1
                // This callback belongs to the concrete folder snapshot that
                // renderFolderOverlay() already resolved. Do not pass the
                // mutable optional openFolderID (UUID?) to a UUID parameter.
                folderID: folder.id, absoluteIndex: startIndex + localIndex, frames: frames,
                presentation: presentation, event: event)
        }
        presentation.button.onPointerDragged = { [weak self] update in self?.folderItemPointerDragged(update) }
        presentation.button.onPointerUp = { [weak self] release in self?.folderItemPointerUp(release) }
        presentation.button.onPointerCancelled = { [weak self] in self?.folderItemPointerCancelled() }
        return presentation
    }

    fileprivate func addFolderPageIndicator(
        to contentLayer: CALayer, context: FolderOverlayRenderContext, folderVisualScale: CGFloat
    ) {
        let metrics = context.metrics
        let pageCount = metrics.pageCount
        let scale = context.scale
        if pageCount > 1 {
            let dots = CATextLayer()
            dots.frame = CGRect(
                x: metrics.panelFrame.minX, y: metrics.panelFrame.minY + 7 * folderVisualScale,
                width: metrics.panelFrame.width, height: 18 * folderVisualScale)
            dots.string = (0..<pageCount).map { $0 == folderPage ? "●" : "○" }.joined(separator: "  ")
            dots.alignmentMode = .center
            dots.fontSize = 10 * folderVisualScale
            dots.foregroundColor = NSColor.white.withAlphaComponent(0.64).cgColor
            dots.contentsScale = scale
            contentLayer.addSublayer(dots)
            folderPageIndicatorLayer = dots
        } else {
            folderPageIndicatorLayer = nil
        }

    }

    fileprivate func animateFolderOverlay(
        context: FolderOverlayRenderContext, contentLayer: CALayer, dimLayer: CALayer, animated: Bool
    ) {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        let visibleApplications = context.visibleApplications
        let sourceFrame = folderPresentation.folderAnimationSourceFrame
        guard animated,
            let transition = LaunchpadVisualStyle.folderTransition(
                sourceFrame: sourceFrame, panelFrame: metrics.panelFrame)
        else {
            contentLayer.shouldRasterize = false
            contentLayer.rasterizationScale = 1

            for presentation in folderPresentation.folderPresentations {
                let isDraggedSource = folderHiddenApplicationID == presentation.button.application.id
                presentation.button.isHidden = isDraggedSource
            }

            // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
            // Once there is no full-folder zoom, switch to the same per-tile
            // raster cache used by root pages before any paging begins.
            enableFolderTileRasterCaches(folderPresentation.folderPresentations, scale: scale)

            // A page change has no opening zoom to protect, so remaining HQ
            // icons may start filling immediately.
            warmFolderIcons(visibleApplications, pointSize: metrics.iconSize, scale: scale)
            stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
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
            Task { @MainActor [weak self] in self?.finishFolderOpening(context: context, contentLayer: contentLayer) }
        }
        dimLayer.add(dimFade, forKey: "folderDimIn")
        contentLayer.add(contentAnimation, forKey: "folderExpandIn")
        CATransaction.commit()
    }

    fileprivate func finishFolderOpening(context: FolderOverlayRenderContext, contentLayer: CALayer) {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        let animationGeneration = context.generation
        let visibleApplications = context.visibleApplications
        guard animationGeneration == folderPresentation.folderAnimationGeneration,
            self.openFolderID != nil else { return }
        // Retire the opening presentation before descendant pages ever
        // start moving. This guarantees paging never shares a frame with
        // the just-finished full-folder zoom presentation.
        contentLayer.removeAllAnimations()
        contentLayer.shouldRasterize = false
        contentLayer.rasterizationScale = 1

        // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
        // V13 deliberately used one parent raster for the zoom. Once
        // that animation ends, hand caching back to individual tiles
        // exactly like root pages so horizontal motion stays GPU-cheap.
        self.enableFolderTileRasterCaches(folderPresentation.folderPresentations, scale: scale)

        for presentation in folderPresentation.folderPresentations {
            let isDraggedSource = self.folderHiddenApplicationID == presentation.button.application.id
            presentation.button.isHidden = isDraggedSource
        }

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Resume any missing HQ folder icons only after the zoom reaches
        // its final state. Existing cache/fallback images remain visible
        // during the transition, so frame pacing wins without blanks.
        self.warmFolderIcons(visibleApplications, pointSize: metrics.iconSize, scale: scale)

        // Build the adjacent page after the opening frame has settled.
        // This removes layer/text creation from the first swipe frame.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, animationGeneration == self.folderPresentation.folderAnimationGeneration,
                self.openFolderID == folder.id else {
                return
            }
            self.stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        }
    }

    // LAUNCHPANE_PROGRESSIVE_FOLDER_ICON_WARM_V6
    fileprivate func warmFolderIcons(_ applications: [ApplicationRecord], pointSize: CGFloat, scale: CGFloat) {
        folderPresentation.folderIconTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Warm four icons at a time. Previously the folder waited for every
            // visible child to finish before rebinding even the icons that had
            // already decoded, so one slow bundle could hold the whole page.
            let batchSize = 4
            var batchStart = 0
            while batchStart < applications.count, !Task.isCancelled {
                let batchEnd = min(batchStart + batchSize, applications.count)
                let batch = Array(applications[batchStart..<batchEnd])

                await iconCache.warm(batch, pointSize: pointSize, scale: scale, maximumConcurrentLoads: batchSize)
                guard !Task.isCancelled else { return }

                let loadedIDs = Set(batch.map(\.id))
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for presentation in folderPresentation.folderPresentations
                    where loadedIDs.contains(presentation.button.application.id) {
                    if let image = iconCache.cgImage(
                        for: presentation.button.application, pointSize: pointSize, scale: scale) {
                        presentation.iconLayer.contents = image
                    }
                }
                CATransaction.commit()

                // Give the compositor a chance to present each completed batch
                // before scheduling the next four misses.
                await Task.yield()
                batchStart = batchEnd
            }
        }
    }

    // LAUNCHPANE_FOLDER_PAGE_LOCAL_LAYOUT_V16
    // Resolve every page against the stable full-folder grid, but always map the
    // page's applications from local slot zero. This deliberately does not reuse
    // a page-global/absolute index. A sparse second page therefore occupies
    // slots 0, 1, 2... of the same lattice used by a full first page.
    fileprivate func folderPageItemFrames(localIndex: Int, visibleCount: Int, metrics: FolderGridMetrics)
        -> GridItemFrames? {
        // LAUNCHPANE_FOLDER_PAGE_LOCAL_LAYOUT_V16_COMPILE_REPAIR
        //
        // GridItemFrames belongs to LayoutCore. Its synthesized memberwise
        // initializer is internal to that module, so LaunchPane must not
        // construct it directly. FolderGridMetrics already exposes the public
        // page-local frame calculation we need.
        //
        // visibleCount remains an explicit guard so a sparse later page can
        // never accidentally expose unused slots from the full-folder lattice.
        guard localIndex >= 0, localIndex < visibleCount, localIndex < metrics.itemsPerPage else { return nil }

        return metrics.itemFrames(forItemAt: localIndex)
    }

    fileprivate struct FolderPageContents {
        let layer: CALayer
        let presentations: [AppTilePresentation]
        let applications: [ApplicationRecord]
    }

    // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14
    fileprivate func makeFolderPageLayer(
        folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, pageIndex: Int, scale: CGFloat
    ) -> FolderPageContents {
        let startIndex = pageIndex * metrics.itemsPerPage
        let endIndex = min(startIndex + metrics.itemsPerPage, folder.applications.count)
        let pageLayer = CALayer()
        pageLayer.bounds = metrics.panelFrame
        pageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pageLayer.position = metrics.panelFrame.center
        pageLayer.contentsScale = scale
        guard startIndex < endIndex else {
            return FolderPageContents(layer: pageLayer, presentations: [], applications: [])
        }
        let applications = Array(folder.applications[startIndex..<endIndex])

        var presentations: [AppTilePresentation] = []
        presentations.reserveCapacity(applications.count)

        for (localIndex, application) in applications.enumerated() {
            guard
                let frames = folderPageItemFrames(
                    localIndex: localIndex, visibleCount: applications.count, metrics: metrics)
            else { continue }

            let presentation = AppTilePresentationFactory.make(
                AppTileRenderInput(
                    application: application, cellFrame: frames.cell, iconFrame: frames.icon, labelFrame: frames.label,
                    scale: scale, selected: startIndex + localIndex == folderSelectedIndex,
                    icon: iconCache.bestAvailableCGImage(for: application, pointSize: metrics.iconSize, scale: scale)))

            // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
            // Folder pages use the same per-tile raster strategy as root pages.
            pageLayer.addSublayer(presentation.tileLayer)

            presentation.button.frame = frames.icon
            presentation.button.target = self
            presentation.button.action = #selector(applicationButtonPressed(_:))
            presentation.button.isHidden = true

            let isDraggedSource = folderHiddenApplicationID == application.id
            if isDraggedSource {
                presentation.tileLayer.opacity = 0
                dragSession?.folderCreationPreview?.sourceLandingCenter = frames.cell.center
            }

            presentation.button.onHoverChanged = { [weak iconLayer = presentation.iconLayer, weak self] isHovering in
                self?.animateHover(on: iconLayer, isHovering: isHovering)
            }
            presentation.button.onPointerDown = { [weak self, weak presentation] event in
                guard let self, let presentation else { return }
                self.folderItemPointerDown(
                    folderID: folder.id, absoluteIndex: startIndex + localIndex,
                    frames: frames, presentation: presentation, event: event)
            }
            presentation.button.onPointerDragged = { [weak self] update in self?.folderItemPointerDragged(update) }
            presentation.button.onPointerUp = { [weak self] release in self?.folderItemPointerUp(release) }
            presentation.button.onPointerCancelled = { [weak self] in self?.folderItemPointerCancelled() }

            // Staged pages own no NSView hit targets until they become current.
            presentations.append(presentation)
        }

        return FolderPageContents(layer: pageLayer, presentations: presentations, applications: applications)
    }

    fileprivate func updateFolderPageIndicator(pageCount: Int) {
        guard let dots = folderPageIndicatorLayer else { return }
        dots.string = (0..<pageCount).map { $0 == folderPage ? "●" : "○" }.joined(separator: "  ")
    }

    // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
    fileprivate func folderPageSurface(
        folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, pageIndex: Int, scale: CGFloat
    ) -> FolderPageSurface? {
        if let cached = folderPageSurfaces[pageIndex] { return cached }

        guard (0..<metrics.pageCount).contains(pageIndex) else { return nil }
        let built = makeFolderPageLayer(folder: folder, metrics: metrics, pageIndex: pageIndex, scale: scale)
        let surface = FolderPageSurface(
            pageIndex: pageIndex, layer: built.layer, presentations: built.presentations,
            applications: built.applications)
        folderPageSurfaces[pageIndex] = surface
        return surface
    }

    fileprivate func attachFolderButtons(to surface: FolderPageSurface, hidden: Bool) {
        for presentation in surface.presentations {
            if presentation.button.superview == nil { addSubview(presentation.button) }
            let isDraggedSource = folderHiddenApplicationID == presentation.button.application.id
            presentation.button.isHidden = hidden || isDraggedSource
        }
    }

    fileprivate func detachFolderButtons(from surface: FolderPageSurface) {
        for presentation in surface.presentations {
            // LAUNCHPANE_FOLDER_EXTRACTION_POINTER_OWNERSHIP_V17
            //
            // Folder close/page-cache cleanup may discard the presentation that
            // originally owned mouseDown. Keep that one transparent NSButton in
            // the view hierarchy until real mouseUp/cancel. Removing it here
            // synchronously triggers PointerTrackingTileButton.viewWillMove()
            // and corrupts the in-flight Folder -> root ownership handoff.
            if presentation.button === preservedFolderTrackingButton { continue }
            presentation.button.removeFromSuperview()
        }
    }

    fileprivate func enableFolderTileRasterCaches(_ presentations: [AppTilePresentation], scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        for presentation in presentations {
            presentation.tileLayer.shouldRasterize = true
            presentation.tileLayer.rasterizationScale = scale
        }
    }

    fileprivate func stageAdjacentFolderPageSurfaces(
        folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, scale: CGFloat
    ) {
        guard interactiveFolderPageSwipe == nil, !folderPageTransitionAnimator.isAnimating,
            let viewportLayer = folderPageViewportLayer
        else { return }

        let lower = max(0, folderPage - 1)
        let upper = min(max(0, metrics.pageCount - 1), folderPage + 1)
        let keep = Set(lower...upper)
        let width = max(1, metrics.panelFrame.width)
        let resting = metrics.panelFrame.center

        let stalePageIndices = folderPageSurfaces.keys.filter { !keep.contains($0) }
        for pageIndex in stalePageIndices {
            guard let surface = folderPageSurfaces.removeValue(forKey: pageIndex) else { continue }
            detachFolderButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.removeFromSuperlayer()
        }

        for pageIndex in keep.sorted() {
            guard let surface = folderPageSurface(folder: folder, metrics: metrics, pageIndex: pageIndex, scale: scale)
            else { continue }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer.removeAllAnimations()
            surface.layer.position = CGPoint(x: resting.x + CGFloat(pageIndex - folderPage) * width, y: resting.y)
            surface.layer.opacity = 1

            // LAUNCHPANE_FOLDER_PAGE_LOCAL_LAYOUT_V16
            // Adjacent pages are prebuilt for smooth paging, but they do not
            // need to be visible while resting. Hide them until a transition
            // actually starts so a sparse current page cannot expose content
            // from an off-page surface.
            surface.layer.isHidden = pageIndex != folderPage
            surface.layer.contentsScale = scale
            if surface.layer.superlayer == nil { viewportLayer.addSublayer(surface.layer) }
            CATransaction.commit()

            if pageIndex != folderPage { detachFolderButtons(from: surface) }
        }
    }

    func presentInteractiveFolderPageSwipe(_ swipe: InteractiveFolderPageSwipe) {
        guard swipe.phase == .tracking else { return }
        swipe.needsPresentationUpdate = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipe.outgoingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x + swipe.translation, y: swipe.restingPosition.y)
        swipe.incomingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width + swipe.translation,
            y: swipe.restingPosition.y)
        CATransaction.commit()
    }

    fileprivate func handleInteractiveFolderPageSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return false }

        let disposition = InteractivePageSwipeDecision.disposition(
            hasActiveSwipe: interactiveFolderPageSwipe != nil, phase: PageScrollPhase(event.phase),
            hasHorizontalMovement: event.scrollingDeltaX != 0,
            isHorizontalDominant: abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        switch disposition {
        case .useDiscretePaging:
            if interactiveFolderPageSwipe != nil { cancelInteractiveFolderPageSwipeImmediately() }
            return false
        case .cancel:
            finishInteractiveFolderPageSwipe(commit: false)
            return true
        case .finish: return finishInteractiveFolderPageSwipeAfterRelease()
        case .beginOrUpdate: return continueInteractiveFolderPageSwipe(event)
        }
    }

    fileprivate func finishInteractiveFolderPageSwipeAfterRelease() -> Bool {
        guard let swipe = interactiveFolderPageSwipe else { return false }
        guard swipe.phase == .tracking else { return true }
        let width = max(1, swipe.width)
        let progress = min(1, max(0, -swipe.translation * CGFloat(swipe.direction) / width))
        let forwardVelocity = -swipe.velocity * CGFloat(swipe.direction)
        let normalizedForwardVelocity = forwardVelocity / width
        let projectedProgress = progress + normalizedForwardVelocity * 0.10
        let commit =
            progress >= 0.025 || (progress >= 0.012 && projectedProgress >= 0.040)
            || (progress >= 0.008 && normalizedForwardVelocity >= 0.25)

        finishInteractiveFolderPageSwipe(commit: commit)
        return true
    }

    fileprivate func continueInteractiveFolderPageSwipe(_ event: NSEvent) -> Bool {
        guard interactiveFolderPageSwipe?.phase != .settling else { return true }
        if !event.momentumPhase.isEmpty { return true }

        if event.phase.contains(.began) { cancelInteractiveFolderPageSwipeImmediately() }

        if interactiveFolderPageSwipe == nil {
            let direction = event.scrollingDeltaX < 0 ? 1 : -1
            if beginInteractiveFolderPageSwipe(direction: direction, timestamp: event.timestamp) {
                folderPageScrollGesture = PageScrollGesture()
            }
        }

        if let swipe = interactiveFolderPageSwipe, event.scrollingDeltaX != 0 {
            updateInteractiveFolderPageSwipe(swipe, deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
        }
        return true
    }

    @discardableResult fileprivate func beginInteractiveFolderPageSwipe(
        direction: Int, timestamp: TimeInterval) -> Bool {
        guard !folderPageTransitionAnimator.isAnimating, interactiveFolderPageSwipe == nil, let openFolderID,
            let folder = resolvedFolder(id: openFolderID), let viewportLayer = folderPageViewportLayer
        else { return false }

        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let targetPage = folderPage + direction
        guard (0..<metrics.pageCount).contains(targetPage) else { return false }

        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        guard let outgoingSurface = folderPageSurfaces[folderPage],
            let incomingSurface = folderPageSurface(
                folder: folder, metrics: metrics, pageIndex: targetPage, scale: scale)
        else { return false }

        folderPresentation.cancelIconLoading()
        for presentation in outgoingSurface.presentations { presentation.button.isHidden = true }

        let resting = metrics.panelFrame.center
        let width = max(1, metrics.panelFrame.width)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingSurface.layer.removeAllAnimations()
        incomingSurface.layer.removeAllAnimations()
        outgoingSurface.layer.position = resting
        incomingSurface.layer.position = CGPoint(x: resting.x + CGFloat(direction) * width, y: resting.y)
        outgoingSurface.layer.opacity = 1
        incomingSurface.layer.opacity = 1
        outgoingSurface.layer.isHidden = false
        incomingSurface.layer.isHidden = false
        if incomingSurface.layer.superlayer == nil { viewportLayer.addSublayer(incomingSurface.layer) }
        CATransaction.commit()

        interactiveFolderPageGeneration &+= 1
        interactiveFolderPageSwipe = InteractiveFolderPageSwipe(
            outgoingSurface: outgoingSurface, incomingSurface: incomingSurface, targetPage: targetPage,
            direction: direction, restingPosition: resting, width: width, timestamp: timestamp)
        return true
    }

    fileprivate func updateInteractiveFolderPageSwipe(
        _ swipe: InteractiveFolderPageSwipe, deltaX: CGFloat, timestamp: TimeInterval
    ) {
        guard swipe.phase == .tracking else { return }
        let elapsed = min(1.0 / 24.0, max(1.0 / 240.0, timestamp - swipe.lastTimestamp))
        swipe.lastTimestamp = timestamp

        let trackingGain: CGFloat = 1.60
        let adjustedDelta = deltaX * trackingGain
        let maximumDelta = swipe.width * 0.18
        let boundedDelta = min(maximumDelta, max(-maximumDelta, adjustedDelta))
        let instantaneousVelocity = boundedDelta / elapsed
        let maximumVelocity = swipe.width * 8.0
        let boundedVelocity = min(maximumVelocity, max(-maximumVelocity, instantaneousVelocity))
        let velocityTimeConstant = 0.034
        let velocityAlpha = 1 - exp(-Double(elapsed) / velocityTimeConstant)
        swipe.velocity += (boundedVelocity - swipe.velocity) * CGFloat(velocityAlpha)

        let proposed = swipe.translation + boundedDelta
        if swipe.direction > 0 {
            swipe.translation = min(0, max(-swipe.width, proposed))
        } else {
            swipe.translation = max(0, min(swipe.width, proposed))
        }
        swipe.needsPresentationUpdate = true
        if let pagingDisplayLink {
            pagingDisplayLink.isPaused = false
        } else {
            presentInteractiveFolderPageSwipe(swipe)
        }
    }

    fileprivate func finishInteractiveFolderPageSwipe(commit: Bool) {
        guard let swipe = interactiveFolderPageSwipe, swipe.phase == .tracking else { return }
        if swipe.needsPresentationUpdate { presentInteractiveFolderPageSwipe(swipe) }

        pagingDisplayLink?.isPaused = true
        swipe.phase = .settling
        interactiveFolderPageGeneration &+= 1
        let generation = interactiveFolderPageGeneration

        let finalTranslation = commit ? -CGFloat(swipe.direction) * swipe.width : 0
        let outgoingStart = swipe.outgoingSurface.layer.presentation()?.position ?? swipe.outgoingSurface.layer.position
        let incomingStart = swipe.incomingSurface.layer.presentation()?.position ?? swipe.incomingSurface.layer.position
        let outgoingEnd = CGPoint(x: swipe.restingPosition.x + finalTranslation, y: swipe.restingPosition.y)
        let incomingEnd = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width + finalTranslation,
            y: swipe.restingPosition.y)

        guard
            let transition = LaunchpadVisualStyle.interactivePageSettleTransition(
                direction: swipe.direction, displayWidth: swipe.width, releaseVelocity: swipe.velocity,
                targetDelta: outgoingEnd.x - outgoingStart.x)
        else {
            completeInteractiveFolderPageSwipe(swipe, commit: commit)
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.interactiveFolderPageGeneration,
                    self.interactiveFolderPageSwipe === swipe
                else { return }
                self.completeInteractiveFolderPageSwipe(swipe, commit: commit)
            }
        }
        swipe.outgoingSurface.layer.position = outgoingEnd
        swipe.incomingSurface.layer.position = incomingEnd
        swipe.outgoingSurface.layer.add(
            animation(from: outgoingStart, to: outgoingEnd), forKey: "interactiveFolderPageOut")
        swipe.incomingSurface.layer.add(
            animation(from: incomingStart, to: incomingEnd), forKey: "interactiveFolderPageIn")
        CATransaction.commit()
    }

    fileprivate func completeInteractiveFolderPageSwipe(_ swipe: InteractiveFolderPageSwipe, commit: Bool) {
        pagingDisplayLink?.isPaused = true
        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if commit {
            swipe.incomingSurface.layer.position = swipe.restingPosition
            swipe.outgoingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x - CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
            swipe.incomingSurface.layer.isHidden = false
            swipe.outgoingSurface.layer.isHidden = true
        } else {
            swipe.outgoingSurface.layer.position = swipe.restingPosition
            swipe.incomingSurface.layer.position = CGPoint(
                x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
            swipe.outgoingSurface.layer.isHidden = false
            swipe.incomingSurface.layer.isHidden = true
        }
        CATransaction.commit()

        if commit {
            detachFolderButtons(from: swipe.outgoingSurface)
            folderPage = swipe.targetPage
            folderSelectedIndex = -1
            folderPageContentLayer = swipe.incomingSurface.layer
            folderPresentation.folderPresentations = swipe.incomingSurface.presentations
            attachFolderButtons(to: swipe.incomingSurface, hidden: false)
        } else {
            attachFolderButtons(to: swipe.outgoingSurface, hidden: false)
        }

        interactiveFolderPageSwipe = nil

        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        updateFolderPageIndicator(pageCount: metrics.pageCount)
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)

        if commit { warmFolderIcons(swipe.incomingSurface.applications, pointSize: metrics.iconSize, scale: scale) }
    }

    fileprivate func cancelInteractiveFolderPageSwipeImmediately() {
        guard let swipe = interactiveFolderPageSwipe else { return }
        pagingDisplayLink?.isPaused = true
        interactiveFolderPageGeneration &+= 1
        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipe.outgoingSurface.layer.position = swipe.restingPosition
        swipe.incomingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
        swipe.outgoingSurface.layer.isHidden = false
        swipe.incomingSurface.layer.isHidden = true
        CATransaction.commit()

        interactiveFolderPageSwipe = nil
        attachFolderButtons(to: swipe.outgoingSurface, hidden: false)
    }

    fileprivate struct FolderPageTransitionContext {
        let folder: ResolvedLaunchpadFolder
        let metrics: FolderGridMetrics
        let scale: CGFloat
    }

    fileprivate func finishFolderPageTransition(
        outgoing outgoingSurface: FolderPageSurface, incoming incomingSurface: FolderPageSurface,
        context: FolderPageTransitionContext, queuedDirection: Int
    ) {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingSurface.layer.isHidden = true
        incomingSurface.layer.isHidden = false
        CATransaction.commit()

        self.attachFolderButtons(to: incomingSurface, hidden: false)
        self.warmFolderIcons(incomingSurface.applications, pointSize: metrics.iconSize, scale: scale)
        self.stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        if queuedDirection != 0 { self.changeFolderPage(by: queuedDirection) }
    }

    fileprivate func presentFolderPageWithoutMotion(
        _ incomingSurface: FolderPageSurface, folder: ResolvedLaunchpadFolder,
        metrics: FolderGridMetrics, scale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingSurface.layer.position = metrics.panelFrame.center
        CATransaction.commit()
        attachFolderButtons(to: incomingSurface, hidden: false)
        warmFolderIcons(incomingSurface.applications, pointSize: metrics.iconSize, scale: scale)
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
    }

    fileprivate func transitionFolderPage(to nextPage: Int, direction: Int, selectedIndex: Int?) {
        guard direction != 0, interactiveFolderPageSwipe == nil, let openFolderID,
            let folder = resolvedFolder(id: openFolderID)
        else { return }

        if folderPageTransitionAnimator.isAnimating {
            if selectedIndex == nil { _ = folderPageTransitionAnimator.queueLatestIfAnimating(direction: direction) }
            return
        }

        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        guard nextPage >= 0, nextPage < metrics.pageCount, nextPage != folderPage,
            let viewportLayer = folderPageViewportLayer, let outgoingSurface = folderPageSurfaces[folderPage]
        else { return }

        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        guard
            let incomingSurface = folderPageSurface(folder: folder, metrics: metrics, pageIndex: nextPage, scale: scale)
        else { return }

        folderPresentation.cancelIconLoading()
        detachFolderButtons(from: outgoingSurface)

        folderPage = nextPage
        folderSelectedIndex = selectedIndex ?? -1
        folderPageContentLayer = incomingSurface.layer
        folderPresentation.folderPresentations = incomingSurface.presentations
        updateFolderPageIndicator(pageCount: metrics.pageCount)

        if incomingSurface.layer.superlayer == nil { viewportLayer.addSublayer(incomingSurface.layer) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingSurface.layer.isHidden = false
        incomingSurface.layer.isHidden = false
        CATransaction.commit()

        guard
            let style = LaunchpadVisualStyle.pageTransition(
                direction: direction, displayWidth: metrics.panelFrame.width)
        else {
            presentFolderPageWithoutMotion(incomingSurface, folder: folder, metrics: metrics, scale: scale)
            return
        }

        let request = PageTransitionAnimator.Request(
            outgoingLayer: outgoingSurface.layer, incomingLayer: incomingSurface.layer, direction: direction,
            style: style, canvasBounds: metrics.panelFrame)

        let context = FolderPageTransitionContext(folder: folder, metrics: metrics, scale: scale)
        folderPageTransitionAnimator.start(request) { [weak self] queuedDirection in
            guard let self else { return }

            self.finishFolderPageTransition(
                outgoing: outgoingSurface, incoming: incomingSurface, context: context,
                queuedDirection: queuedDirection)
        }
    }

    fileprivate func changeFolderPage(by offset: Int) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let nextPage = min(max(folderPage + offset, 0), max(0, metrics.pageCount - 1))
        guard nextPage != folderPage else { return }

        transitionFolderPage(to: nextPage, direction: nextPage - folderPage, selectedIndex: nil)
    }

    fileprivate func moveFolderSelection(_ movement: GridNavigationMovement) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let currentSelection = folder.applications.indices.contains(folderSelectedIndex) ? folderSelectedIndex : nil
        guard
            let nextIndex = GridSelectionNavigator.nextIndex(
                from: currentSelection, movement: movement,
                context: GridNavigationContext(
                    currentPage: folderPage, itemsPerPage: metrics.itemsPerPage, columns: metrics.columns,
                    itemCount: folder.applications.count, isRightToLeft: metrics.isRightToLeft))
        else { return }

        let previousPage = folderPage
        let nextPage = nextIndex / metrics.itemsPerPage
        if nextPage != previousPage {
            transitionFolderPage(to: nextPage, direction: nextPage - previousPage, selectedIndex: nextIndex)
        } else {
            folderSelectedIndex = nextIndex
            updateFolderSelectionAppearance(itemsPerPage: metrics.itemsPerPage)
        }
    }

    fileprivate func updateFolderSelectionAppearance(itemsPerPage: Int) {
        let pageStartIndex = folderPage * itemsPerPage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (localIndex, presentation) in folderPresentation.folderPresentations.enumerated() {
            presentation.selectionLayer.opacity = pageStartIndex + localIndex == folderSelectedIndex ? 1 : 0
        }
        CATransaction.commit()
    }

    fileprivate func activateSelectedFolderItem() {
        guard !folderPageTransitionAnimator.isAnimating, interactiveFolderPageSwipe == nil, let openFolderID,
            let folder = resolvedFolder(id: openFolderID), folder.applications.indices.contains(folderSelectedIndex)
        else { return }
        launch(folder.applications[folderSelectedIndex])
    }

    fileprivate func closeFolder(animated: Bool = true, preservingTrackedButton: AppTileButton? = nil) {
        guard openFolderID != nil else { return }
        if folderPresentation.folderTitleEditor != nil { finishFolderTitleEditing(commit: true) }
        folderPresentation.invalidateAnimation()
        let animationGeneration = folderPresentation.folderAnimationGeneration
        let sourceFrame = folderPresentation.folderAnimationSourceFrame
        let panelFrame = folderPresentation.folderPanelFrame
        let contentLayer = folderPresentation.folderContentAnimationLayer
        let dimLayer = folderPresentation.folderDimAnimationLayer

        openFolderID = nil
        folderPage = 0
        folderSelectedIndex = -1
        folderPresentation.folderPanelFrame = .zero
        folderPresentation.cancelIconLoading()
        cancelInteractiveFolderPageSwipeImmediately()

        // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14
        // If Escape/outside-click closes the folder mid-page-slide, stop the
        // nested page animator before starting the folder collapse animation.
        if let currentFolderPageLayer = folderPageContentLayer {
            folderPageTransitionAnimator.reset(
                contentLayer: currentFolderPageLayer,
                canvasBounds: folderPageViewportLayer?.bounds ?? currentFolderPageLayer.bounds)
        }

        if let preservingTrackedButton { preservedFolderTrackingButton = preservingTrackedButton }
        removeFolderButtons(preserving: preservedFolderTrackingButton)
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
        if renderedConfiguration == nil { needsLayout = true }

        guard animated, let contentLayer, let dimLayer,
            let transition = LaunchpadVisualStyle.folderTransition(sourceFrame: sourceFrame, panelFrame: panelFrame)
        else {
            cleanupFolderOverlay()
            resumeRootIconPrewarmingAfterFolder()
            return
        }

        animateFolderClosing(
            contentLayer: contentLayer, dimLayer: dimLayer, transition: transition,
            animationGeneration: animationGeneration)
    }

    fileprivate func animateFolderClosing(
        contentLayer: CALayer, dimLayer: CALayer, transition: LaunchpadVisualStyle.FolderTransition,
        animationGeneration: Int
    ) {
        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Re-flatten the subtree only for the short close animation.
        contentLayer.shouldRasterize = true
        contentLayer.rasterizationScale = max(1, window?.backingScaleFactor ?? 1)

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
        contentLayer.setAffineTransform(CGAffineTransform(scaleX: transition.sourceScale, y: transition.sourceScale))
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, animationGeneration == folderPresentation.folderAnimationGeneration,
                    openFolderID == nil else { return }
                cleanupFolderOverlay()
                resumeRootIconPrewarmingAfterFolder()
            }
        }
        dimLayer.add(dimFade, forKey: "folderDimOut")
        contentLayer.add(contentAnimation, forKey: "folderCollapseOut")
        CATransaction.commit()
    }

    // LAUNCHPANE_FOLDER_OPEN_FPS_V13
    fileprivate func resumeRootIconPrewarmingAfterFolder() {
        guard presentationResourcesActive, openFolderID == nil, let metrics = currentMetrics else { return }

        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        scheduleIconPrewarming(metrics: metrics, scale: scale)
        scheduleSessionHighQualityIconWarm(metrics: metrics, scale: scale)
    }

    fileprivate func cleanupFolderOverlay() {
        if let currentFolderPageLayer = folderPageContentLayer {
            folderPageTransitionAnimator.reset(
                contentLayer: currentFolderPageLayer,
                canvasBounds: folderPageViewportLayer?.bounds ?? currentFolderPageLayer.bounds)
        }
        for surface in folderPageSurfaces.values {
            detachFolderButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.removeFromSuperlayer()
        }
        folderPageSurfaces.removeAll(keepingCapacity: true)
        interactiveFolderPageSwipe = nil
        folderPageSwipeInputGate = PageSwipeInputGate()
        folderPageViewportLayer = nil
        folderPageContentLayer = nil
        folderPageIndicatorLayer = nil

        folderPresentation.clearOverlay()
    }

    fileprivate func removeFolderButtons(preserving preservedButton: AppTileButton? = nil) {
        folderPresentation.removeButtons(preserving: preservedButton ?? preservedFolderTrackingButton)
    }
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
