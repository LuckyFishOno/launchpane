import AppCore
import AppKit

extension LaunchpadRootView {
    // MARK: - Native-style folder title editing

    func startFolderTitleEditing() {
        guard folderPresentation.folderTitleEditor == nil, !isCommittingFolderTitle, let openFolderID,
            let folder = resolvedFolder(id: openFolderID),
            folderPresentation.folderTitleFrame.width > 0, folderPresentation.folderTitleFrame.height > 0
        else { return }

        let editor = NSTextField(frame: folderPresentation.folderTitleFrame)
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

        folderPresentation.folderTitleEditor = editor
        folderPresentation.folderTitleLayer?.opacity = 0
        addSubview(editor)

        guard window?.makeFirstResponder(editor) == true else {
            editor.removeFromSuperview()
            folderPresentation.folderTitleEditor = nil
            folderPresentation.folderTitleLayer?.opacity = 1
            return
        }
        editor.currentEditor()?.selectAll(nil)
    }

    func finishFolderTitleEditing(commit: Bool) {
        guard !folderPresentation.isEndingFolderTitleEditing,
            let editor = folderPresentation.folderTitleEditor else { return }
        folderPresentation.isEndingFolderTitleEditing = true

        let folderID = openFolderID
        let rawTitle = editor.stringValue
        let fallbackTitle = folderID.flatMap { resolvedFolder(id: $0)?.title } ?? "Untitled"
        let normalizedTitle = normalizedFolderTitle(rawTitle)

        // Clear ownership before resigning first responder because AppKit sends
        // controlTextDidEndEditing synchronously during the responder handoff.
        folderPresentation.folderTitleEditor = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        folderPresentation.folderTitleLayer?.opacity = 1
        folderPresentation.folderTitleLayer?.string = commit ? normalizedTitle : fallbackTitle
        window?.makeFirstResponder(self)
        folderPresentation.isEndingFolderTitleEditing = false

        guard commit, let folderID else { return }
        persistFolderTitle(normalizedTitle, folderID: folderID)
    }

    private func normalizedFolderTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private func persistFolderTitle(_ title: String, folderID: UUID) {
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
                if openFolderID == folderID { renderFolderOverlay(animated: false) } else { needsLayout = true }
            } catch {
                NSSound.beep()
                if openFolderID == folderID { renderFolderOverlay(animated: false) }
            }
        }
    }

}

// NSTextFieldDelegate is intentionally handled by the root view so editing can
// commit without introducing a second window or stealing the folder's visual
// animation ownership.
extension LaunchpadRootView {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !folderPresentation.isEndingFolderTitleEditing,
            let editor = folderPresentation.folderTitleEditor, obj.object as? NSTextField === editor else {
            return
        }
        finishFolderTitleEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let editor = folderPresentation.folderTitleEditor, control === editor else { return false }
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
