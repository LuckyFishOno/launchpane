import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func scheduleIdleFirstPageIconWarm() {
        guard !presentationResourcesActive, !applications.isEmpty, !isLoadingApplications else { return }

        let metrics = solver.solve(display: displayContext, requested: layoutPreferences, itemCount: applications.count)
        let pages = ResolvedLaunchpadItemFactory.makePages(
            document: layoutDocument, applications: applications, query: "", pageCapacity: metrics.itemsPerPage)

        let firstPageItems = pages.pages.first ?? []
        var firstPageStandalone: [ApplicationRecord] = []
        var firstPageFolderMiniatures: [ApplicationRecord] = []
        var seenFolderMiniatures: Set<ApplicationIdentity> = []

        for item in firstPageItems {
            switch item {
            case .application(let application): firstPageStandalone.append(application)
            case .folder(let folder):
                for application in folder.applications.prefix(AppTilePresentationFactory.folderMaximumVisibleChildren)
                where seenFolderMiniatures.insert(application.id).inserted {
                    firstPageFolderMiniatures.append(application)
                }
            }
        }

        // A 2x standalone source is still small (~5 MiB for 35 96pt icons) and
        // can satisfy both 1x external and 2x Retina first frames. Folder
        // previews are much smaller: each first-page child is pinned as an
        // exact 64px RGBA bitmap, with at most nine children per folder.
        let pinnedScale = max(CGFloat(2), displayContext.backingScaleFactor)
        iconCache.retainPinnedFirstPageApplications(firstPageStandalone)
        iconCache.retainPinnedFirstPageFolderMiniatures(firstPageFolderMiniatures)

        iconPrewarmTasks.idleFirstPage?.cancel()
        guard !firstPageStandalone.isEmpty || !firstPageFolderMiniatures.isEmpty else {
            iconPrewarmTasks.idleFirstPage = nil
            return
        }

        iconPrewarmTasks.idleFirstPage = Task { @MainActor [weak self] in
            guard let self else { return }

            // P0: standalone icons dominate first-frame perception. Warm them
            // first, then use otherwise-idle time for tiny folder previews.
            await iconCache.warmPinnedFirstPage(
                firstPageStandalone, pointSize: metrics.iconSize, scale: pinnedScale, maximumConcurrentLoads: 2)
            guard !Task.isCancelled else { return }

            await iconCache.warmPinnedFirstPageFolderMiniatures(
                firstPageFolderMiniatures, pixelSize: 64, maximumConcurrentLoads: 2)
        }
    }

    /// Starts once per visible presentation and warms every application at the
    /// root/full-folder icon size. FolderLayoutConstraintSolver deliberately
    /// matches folder-child icon geometry to the root grid, so one exact
    /// pointSize/scale request is sufficient for both places.
    ///
    /// Phase 0 is intentionally only the *full contents* of first-page folders.
    /// Those are the only icons a user can plausibly request immediately after
    /// launch that are not already covered by the pinned first-page standalone
    /// cache. Once phase 0 completes, the remaining pages fill opportunistically.
    func scheduleSessionHighQualityIconWarm(metrics: GridMetrics, scale: CGFloat) {
        guard presentationResourcesActive, !applications.isEmpty, !isLoadingApplications,
            iconPrewarmTasks.presentation == nil
        else { return }

        let pages = ResolvedLaunchpadItemFactory.makePages(
            document: layoutDocument, applications: applications, query: "", pageCapacity: metrics.itemsPerPage)
        let plan = IconWarmPlan.make(pages: pages.pages, applications: applications)
        guard !plan.firstPageFolderContents.isEmpty || !plan.remaining.isEmpty else { return }

        iconPrewarmTasks.presentation = Task { @MainActor [weak self] in
            guard let self else { return }

            // Let the pinned first-page render reach the compositor before doing
            // any extra decode work. This does not delay the opening animation.
            await Task.yield()
            guard presentationResourcesActive, !Task.isCancelled else { return }

            // LAUNCHPANE_FOLDER_OPEN_HEADROOM_V6
            // P0: every child of every first-page folder, full Retina size. Keep
            // four background workers so an actively opened folder can start its
            // own four priority loads without creating a decode storm.
            await iconCache.warm(
                plan.firstPageFolderContents, pointSize: metrics.iconSize, scale: scale, maximumConcurrentLoads: 4)
            guard presentationResourcesActive, !Task.isCancelled else { return }

            // P1+: all remaining apps in page order. Use only two opportunistic
            // workers after the first-page folders are warm; interaction wins over
            // background completion if the user opens a folder immediately.
            await iconCache.warm(plan.remaining, pointSize: metrics.iconSize, scale: scale, maximumConcurrentLoads: 2)
            guard presentationResourcesActive, !Task.isCancelled else { return }

            // Rebind any surfaces that are currently staged. This is cosmetic:
            // folders opened after the warm already read the same cache directly.
            for surface in pageSurfaces.values { refreshIcons(in: surface, pointSize: metrics.iconSize, scale: scale) }

            if openFolderID != nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for presentation in folderPresentation.folderPresentations {
                    presentation.iconLayer.contents = iconCache.cgImage(
                        for: presentation.button.application, pointSize: metrics.iconSize, scale: scale)
                }
                CATransaction.commit()
            }
        }
    }

    func scheduleIconPrewarming(metrics: GridMetrics, scale: CGFloat) {
        guard !applications.isEmpty, !isLoadingApplications, !isPageTransitionActive else { return }

        let revision = contentRevision
        let currentSurface = pageSurfaces[currentPage]
        let adjacentPageIndices = [currentPage - 1, currentPage + 1].filter { pageSurfaces[$0] != nil }

        iconPrewarmTasks.visiblePage?.cancel()

        iconPrewarmTasks.visiblePage = Task { @MainActor [weak self] in
            guard let self else { return }

            if let currentSurface {
                guard await warmVisiblePage(currentSurface, metrics: metrics, scale: scale, revision: revision) else {
                    return
                }
            }

            // P2: adjacent standalone apps first, then only their visible folder
            // miniatures. This keeps the next swipe responsive without a folder
            // containing dozens of apps stealing decoder slots.
            let (adjacentStandalone, adjacentFolderMiniatures) = adjacentIconWarmPlan(adjacentPageIndices)

            await iconCache.warm(
                adjacentStandalone, pointSize: metrics.iconSize, scale: scale, maximumConcurrentLoads: 2)

            guard !Task.isCancelled, revision == contentRevision, !isPageTransitionActive else { return }

            for pageIndex in adjacentPageIndices {
                guard let surface = pageSurfaces[pageIndex] else { continue }
                refreshIcons(in: surface, pointSize: metrics.iconSize, scale: scale)
            }

            await iconCache.warm(
                adjacentFolderMiniatures,
                pointSize: AppTilePresentationFactory.folderMiniatureIconPointSize(forRootIconSize: metrics.iconSize),
                scale: scale, maximumConcurrentLoads: 2)

            guard !Task.isCancelled, revision == contentRevision, !isPageTransitionActive else { return }

            for pageIndex in adjacentPageIndices {
                guard let surface = pageSurfaces[pageIndex] else { continue }
                refreshIcons(in: surface, pointSize: metrics.iconSize, scale: scale)
            }
        }
    }

    private func adjacentIconWarmPlan(_ adjacentPageIndices: [Int]) -> ([ApplicationRecord], [ApplicationRecord]) {
        var adjacentStandalone: [ApplicationRecord] = []
        var adjacentFolderMiniatures: [ApplicationRecord] = []
        var seenStandalone: Set<ApplicationIdentity> = []
        var seenFolder: Set<ApplicationIdentity> = []

        for pageIndex in adjacentPageIndices {
            guard let surface = pageSurfaces[pageIndex] else { continue }

            for application in standaloneApplications(in: surface)
                where seenStandalone.insert(application.id).inserted {
                adjacentStandalone.append(application)
            }
            for application in folderMiniatureApplications(in: surface)
                where seenFolder.insert(application.id).inserted {
                adjacentFolderMiniatures.append(application)
            }
        }
        return (adjacentStandalone, adjacentFolderMiniatures)
    }

    private func warmVisiblePage(
        _ currentSurface: LaunchpadPageSurface, metrics: GridMetrics, scale: CGFloat, revision: Int
    ) async -> Bool {
        await iconCache.warm(
            standaloneApplications(in: currentSurface), pointSize: metrics.iconSize, scale: scale,
            maximumConcurrentLoads: 2)

        guard !Task.isCancelled, revision == contentRevision, !isPageTransitionActive else { return false }

        refreshIcons(in: currentSurface, pointSize: metrics.iconSize, scale: scale)

        // P1: only the nine miniatures a closed folder can actually show.
        // Do not decode every child of a large folder during launch.
        await iconCache.warm(
            folderMiniatureApplications(in: currentSurface),
            pointSize: AppTilePresentationFactory.folderMiniatureIconPointSize(forRootIconSize: metrics.iconSize),
            scale: scale, maximumConcurrentLoads: 2)

        guard !Task.isCancelled, revision == contentRevision, !isPageTransitionActive else { return false }

        refreshIcons(in: currentSurface, pointSize: metrics.iconSize, scale: scale)
        return true
    }

    func standaloneApplications(in surface: LaunchpadPageSurface) -> [ApplicationRecord] {
        var seen: Set<ApplicationIdentity> = []
        return surface.entries.compactMap { entry -> ApplicationRecord? in
            guard case .application(let application) = entry.item else { return nil }
            return seen.insert(application.id).inserted ? application : nil
        }
    }

    func folderMiniatureApplications(in surface: LaunchpadPageSurface) -> [ApplicationRecord] {
        var seen: Set<ApplicationIdentity> = []
        var result: [ApplicationRecord] = []
        for entry in surface.entries {
            guard case .folder(let folder) = entry.item else { continue }
            for application in folder.applications.prefix(AppTilePresentationFactory.folderMaximumVisibleChildren)
            where seen.insert(application.id).inserted { result.append(application) }
        }
        return result
    }

    func refreshIcons(in surface: LaunchpadPageSurface, pointSize: CGFloat, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in surface.entries {
            switch entry.presentation {
            case .application(let presentation):
                guard case .application(let application) = entry.item else { continue }
                presentation.iconLayer.contents = iconCache.cgImage(
                    for: application, pointSize: pointSize, scale: scale)
            case .folder(let presentation):
                guard case .folder(let folder) = entry.item else { continue }
                let miniaturePointSize = AppTilePresentationFactory.folderMiniatureIconPointSize(
                    forRootIconSize: pointSize)
                let childIcons = folder.applications.prefix(AppTilePresentationFactory.folderMaximumVisibleChildren)
                    .compactMap { iconCache.cgImage(for: $0, pointSize: miniaturePointSize, scale: scale) }
                AppTilePresentationFactory.updateFolderIcon(
                    presentation, childIcons: childIcons, scale: scale, layoutDirection: userInterfaceLayoutDirection)
            }
        }
        CATransaction.commit()
    }

    func cancelIconPrewarming() {
        iconPrewarmTasks.cancelVisiblePage()
    }
}
