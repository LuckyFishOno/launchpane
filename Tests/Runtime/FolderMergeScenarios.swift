import AppCore
import AppKit
import LayoutCore
import QuartzCore

// Folder interaction scenarios share the real-event fixture above.
extension FolderMergeCheckDelegate {
    var directions: [ApproachDirection] {
        [
            .init(name: "left", horizontal: -1, vertical: 0), .init(name: "right", horizontal: 1, vertical: 0),
            .init(name: "above", horizontal: 0, vertical: 1), .init(name: "below", horizontal: 0, vertical: -1),
            .init(name: "upper left", horizontal: -1, vertical: 1),
            .init(name: "upper right", horizontal: 1, vertical: 1),
            .init(name: "lower left", horizontal: -1, vertical: -1),
            .init(name: "lower right", horizontal: 1, vertical: -1),
        ]
    }

    func checkEightApproaches() async throws {
        // Each source is the genuine adjacent side/corner icon. Beginning just
        // outside the target cell must not push it away before entering its icon.
        for direction in directions {
            let name = direction.name
            let horizontal = direction.horizontal
            let vertical = direction.vertical
            try await openFixture()
            let sourceColumnDelta = metrics.isRightToLeft ? -horizontal : horizontal
            sourceID = references[targetIndex + sourceColumnDelta - vertical * metrics.columns].identity
            let identifier = LauncherLayoutItemIdentifier.application(targetID)
            guard let baseline = frames(identifier) else {
                check(false, "\(name): expected the target application on the visible page")
                return
            }
            let destination = center(baseline.icon)
            let start = CGPoint(
                x: horizontal < 0 ? baseline.cell.minX - 6 : horizontal > 0 ? baseline.cell.maxX + 6 : destination.x,
                y: vertical < 0 ? baseline.cell.minY - 6 : vertical > 0 ? baseline.cell.maxY + 6 : destination.y)
            let button = press()
            drag(button, to: start)
            var targetStayedStill = unchanged(identifier, from: baseline)
            let steps = max(1, Int(ceil(hypot(start.x - destination.x, start.y - destination.y) / 5)))
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                drag(
                    button,
                    to: CGPoint(
                        x: start.x + (destination.x - start.x) * progress,
                        y: start.y + (destination.y - start.y) * progress))
                await pause(0.006)
                targetStayedStill = targetStayedStill && unchanged(identifier, from: baseline)
            }
            check(session != nil && button.isTrackingPointer, "\(name): real source button owns the drag")
            check(intent?.candidate == .application(targetID), "\(name): icon overlap acquires the target")
            await pause(0.55)  // No additional mouseDragged event: stationary dwell must work.
            check(
                intent?.isReady == true && intent?.candidate == .application(targetID),
                "\(name): stationary overlap arms folder creation")
            check(value(root, "openFolderID", as: UUID.self) == nil, "\(name): short dwell keeps the folder closed")
            check(
                (selectionLayer(identifier)?.presentation()?.opacity ?? selectionLayer(identifier)?.opacity ?? 0) > 0.5,
                "\(name): merge-ready target shows the white rounded frame")
            check(
                targetStayedStill && unchanged(identifier, from: baseline),
                "\(name): target never moves away during approach or dwell")
            try await cancel(button)
        }
    }

    func checkDirectOverlapAndCommit() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let identifier = LauncherLayoutItemIdentifier.application(targetID)
        let baseline = frames(identifier)!
        let destination = center(baseline.icon)
        let button = press()
        drag(button, to: destination)
        check(intent?.candidate == .application(targetID), "one input event acquires its actual icon target")
        await pause(0.55)
        check(
            intent?.isReady == true && unchanged(identifier, from: baseline),
            "direct stationary overlap arms without moving the target")
        check(
            value(root, "openFolderID", as: UUID.self) == nil && button.isTrackingPointer,
            "short merge dwell keeps the folder closed while the real drag remains active")
        check(
            (selectionLayer(identifier)?.presentation()?.opacity ?? selectionLayer(identifier)?.opacity ?? 0) > 0.5,
            "merge-ready state uses the white rounded target frame")

        await release(button, at: destination)
        let document = try persisted()
        let created = folders(document)
        check(created.count == 1, "mouseUp on a ready target creates exactly one closed folder")
        check(value(root, "openFolderID", as: UUID.self) == nil, "normal folder creation does not open the new folder")
        if let folder = created.first {
            check(
                folder.applications.map(\.identity) == [targetID, sourceID!],
                "new folder orders the target first and dragged application second")
            check(folder.customTitle == "Untitled", "new folder persists the native Untitled name")
            check(
                entry(.folder(folder.id)).flatMap { value($0, "item", as: ResolvedLaunchpadItem.self) }?.displayName
                    == "Untitled", "new folder displays Untitled")
        }
        verifyOneCommit(document)
        await pause(0.5)
        check(try persisted() == document, "release leaves no delayed second merge or commit")
    }

    func checkSpringOpenAfterTwoSeconds() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let destination = center(frames(.application(targetID))!.icon)
        let button = press()
        drag(button, to: destination)

        await pause(0.55)
        check(intent?.isReady == true, "spring-open test reaches merge-ready state")
        check(value(root, "openFolderID", as: UUID.self) == nil, "folder is still closed after the short merge dwell")

        await pause(1.60)
        let openedID: UUID? = value(root, "openFolderID", as: UUID.self)
        check(
            openedID != nil && button.isTrackingPointer,
            "continuous two-second overlap spring-opens without ending the real drag")

        let panel: CGRect = value(root.folderPresentation, "folderPanelFrame")!
        let dropPoint = CGPoint(x: panel.midX, y: panel.midY)
        drag(button, to: dropPoint)
        await release(button, at: dropPoint)
        let document = try persisted()
        let created = folders(document)
        check(created.count == 1, "spring-open drop persists exactly one folder")
        check(
            value(root, "openFolderID", as: UUID.self) == created.first?.id,
            "spring-open folder remains open after dropping inside it")
        verifyOneCommit(document)
        try await checkFolderTitleEditing()
    }

    func checkFolderTitleEditing() async throws {
        let baseline = try persisted()
        root.startFolderTitleEditing()
        guard let editor = root.folderPresentation.folderTitleEditor else {
            check(false, "folder title editor acquires first responder")
            return
        }
        let originalTitle = editor.stringValue
        editor.stringValue = "Discard this name"
        let cancelled = root.control(
            editor, textView: NSTextView(), doCommandBy: NSSelectorFromString("cancelOperation:"))
        check(cancelled && root.folderPresentation.folderTitleEditor == nil, "Escape removes the folder title editor")
        check(root.folderPresentation.folderTitleLayer?.string as? String == originalTitle,
            "Escape restores the displayed title")
        check(try persisted() == baseline, "Escape does not write the layout")

        root.startFolderTitleEditing()
        guard let replacement = root.folderPresentation.folderTitleEditor else {
            check(false, "folder title can be edited again after cancellation")
            return
        }
        replacement.stringValue = "  Renamed Folder  "
        let committed = root.control(
            replacement, textView: NSTextView(), doCommandBy: NSSelectorFromString("insertNewline:"))
        check(committed && root.folderPresentation.folderTitleEditor == nil,
            "Enter removes the editor before committing")
        root.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: replacement))
        await until("folder title persistence settles") { !root.isCommittingFolderTitle }
        let renamed = try persisted()
        check(folders(renamed).first?.customTitle == "Renamed Folder", "committed folder title is trimmed")
        check(renamed.revision == baseline.revision + 1, "duplicate editing notification commits only once")
        root.startFolderTitleEditing()
        check(root.folderPresentation.folderTitleEditor?.stringValue == "Renamed Folder",
            "reopened editor displays persisted title")
        root.finishFolderTitleEditing(commit: false)
    }

    func checkLeavingAndRestart() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let destination = center(frames(.application(targetID))!.icon)
        let button = press()
        drag(button, to: destination)
        await pause(0.12)
        let outsideGrid = CGPoint(x: metrics.contentFrame.midX, y: metrics.contentFrame.maxY + 12)
        drag(button, to: outsideGrid)
        await pause(0.55)
        check(
            intent?.candidate == nil && intent?.isReady == false,
            "leaving before dwell clears candidate and cannot arm later")
        await release(button, at: outsideGrid)
        check(try persisted() == fixture, "release outside after leaving does not create a folder")

        try await openFixture()
        let nextID = references[targetIndex + 2].identity
        let nextPoint = center(frames(.application(nextID))!.icon)
        let switching = press()
        drag(switching, to: destination)
        let dwell = intent!.mergeDwell
        let previousDeadline = intent!.deadline!
        await pause(dwell * 0.4)
        drag(switching, to: nextPoint)
        check(intent?.candidate == .application(nextID), "B to C switches the pending candidate")
        check(
            (intent?.deadline ?? 0) > previousDeadline && intent?.isReady == false,
            "switching candidates resets readiness and starts a new deadline")
        await pause(dwell + 0.1)
        check(
            intent?.candidate == .application(nextID) && intent?.isReady == true,
            "C arms only after its own stationary dwell")
        try await cancel(switching)

        try await openFixture()
        let cancelled = press()
        drag(cancelled, to: destination)
        await pause(0.10)
        try await cancel(cancelled)
        check(folders(try persisted()).isEmpty, "cancelling pending dwell cannot create a late folder")
    }

    func checkReorderAndOffset() async throws {
        try await openFixture()
        sourceID = references[0].identity
        let baseline = frames(.application(targetID))!
        let destination = center(baseline.icon)
        let quick = press()
        drag(quick, to: destination)
        await release(quick, at: destination)
        let quickDocument = try persisted()
        check(folders(quickDocument).isEmpty, "quick release over an icon does not create a folder")
        check(quickDocument.items != fixture.items, "quick release still commits a reorder")
        verifyOneCommit(quickDocument)

        try await openFixture()
        let originalFrames = Dictionary(
            uniqueKeysWithValues: references.compactMap { reference in
                frames(.application(reference.identity)).map { (reference.identity, $0) }
            })
        let passing = press()
        drag(passing, to: destination)
        await pause(0.06)
        // The lower cell gutter is an insertion location, outside icon overlap.
        let gutter = CGPoint(x: baseline.cell.midX, y: baseline.cell.minY + 6)
        drag(passing, to: gutter)
        await pause(0.3)
        check(intent?.candidate?.isInsertion == true, "passing through the icon into its gutter selects reorder")
        check(
            originalFrames.contains { identity, original in
                identity != sourceID && frames(.application(identity)) != original
            }, "stationary gutter moves a displaced neighbor in the reorder preview")
        await release(passing, at: gutter)
        let reordered = try persisted()
        check(
            folders(reordered).isEmpty && reordered.items != fixture.items,
            "fast pass followed by gutter drop reorders without a folder")
        verifyOneCommit(reordered)

        try await openFixture()
        let sourceFrames = frames(.application(sourceID))!
        let offset = CGVector(dx: sourceFrames.icon.width * 0.26, dy: -sourceFrames.icon.height * 0.20)
        let offsetButton = press(offset: offset)
        let offsetDestination = CGPoint(x: destination.x + offset.dx, y: destination.y + offset.dy)
        drag(offsetButton, to: offsetDestination)
        await pause(0.55)
        check(
            intent?.candidate == .application(targetID) && intent?.isReady == true,
            "off-center mouseDown uses dragged-icon geometry for folder intent")
        check(unchanged(.application(targetID), from: baseline), "off-center grab does not displace its target")
        try await cancel(offsetButton)
    }

    func checkExistingFolder() async throws {
        let originalFixture = fixture
        var items = references.map(LauncherLayoutItem.application)
        let folder = LauncherFolder(
            customTitle: "Kept Name", applications: [references[targetIndex], references.last!])
        items[targetIndex] = .folder(folder)
        items.removeLast()
        try await openFixture(LauncherLayoutDocument(revision: 950, items: items))
        sourceID = references[0].identity
        let folderButton = descendants(root).compactMap { $0 as? FolderTileButton }.first { $0.folderID == folder.id }
        check(folderButton != nil, "existing folder has its real FolderTileButton")
        let baseline = frames(.folder(folder.id))!
        let destination = center(baseline.icon)
        let button = press()
        drag(button, to: destination)
        await pause(0.55)
        check(
            intent?.candidate == .folder(folder.id) && intent?.isReady == true,
            "existing folder arms as an add target after stationary dwell")
        check(unchanged(.folder(folder.id), from: baseline), "existing folder stays in place while armed")
        check(
            value(root, "openFolderID", as: UUID.self) == nil && button.isTrackingPointer,
            "short dwell over an existing folder keeps it closed")
        await release(button, at: destination)
        let document = try persisted()
        let result = folders(document)
        check(result.count == 1 && result.first?.id == folder.id, "add preserves the existing folder identity")
        check(
            result.first?.applications.map(\.identity) == folder.applications.map(\.identity) + [sourceID!],
            "existing folder appends the dragged application exactly once")
        check(result.first?.customTitle == "Kept Name", "adding an application preserves a custom folder name")
        check(
            value(root, "openFolderID", as: UUID.self) == nil,
            "adding to an existing folder by mouseUp leaves it closed")
        verifyOneCommit(document)
        fixture = originalFixture
    }

}
