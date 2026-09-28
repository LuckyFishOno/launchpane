import AppKit
import QuartzCore

extension LaunchpadSearchField {
    func updatePresentation() {
        let hasCommittedText = !textField.stringValue.isEmpty
        let hasVisualInput = hasTextForPlaceholderSuppression

        // Preserve existing clear-button semantics: it represents committed
        // search text. Merely starting an IME composition does not manufacture a
        // committed query or force the clear button to appear.
        clearButton.isHidden = !hasCommittedText

        // This is the bug fix: custom placeholder visibility follows BOTH
        // committed text and uncommitted marked text in the field editor.
        centeredPlaceholderLabel.isHidden = hasVisualInput

        // We render the empty placeholder ourselves so the magnifier and text
        // are guaranteed to move as one compositor object.
        textField.placeholderAttributedString = nil
        needsLayout = true
    }

    var activeFieldEditor: NSTextView? { textField.currentEditor() as? NSTextView }

    var hasTextForPlaceholderSuppression: Bool {
        // The control value is authoritative after commit.
        if !textField.stringValue.isEmpty { return true }

        guard let editor = activeFieldEditor else { return false }

        // `hasMarkedText()` is the semantic IME signal. Checking editor.string
        // as well covers the tiny transition window between insertion and the
        // control forwarding its normal text-change notification.
        return editor.hasMarkedText() || !editor.string.isEmpty
    }

    func installFieldEditorObservationIfNeeded() {
        guard let editor = activeFieldEditor else { return }

        let storage = editor.textStorage

        if observedFieldEditor === editor, observedFieldEditorTextStorage === storage { return }

        stopFieldEditorObservation()

        observedFieldEditor = editor
        observedFieldEditorTextStorage = storage

        // NSTextDidChange is the high-level signal from the field editor.
        NotificationCenter.default.addObserver(
            self, selector: #selector(fieldEditorDidChange(_:)), name: NSText.didChangeNotification, object: editor)

        // IMEs can update marked characters/attributes in NSTextStorage before
        // the NSTextField's committed string changes. Observe TextKit directly
        // as the low-level, composition-safe signal.
        if let storage {
            NotificationCenter.default.addObserver(
                self, selector: #selector(fieldEditorTextStorageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
    }

    func stopFieldEditorObservation() {
        if let editor = observedFieldEditor {
            NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: editor)
        }

        if let storage = observedFieldEditorTextStorage {
            NotificationCenter.default.removeObserver(
                self, name: NSTextStorage.didProcessEditingNotification, object: storage)
        }

        observedFieldEditor = nil
        observedFieldEditorTextStorage = nil
    }

    @objc func fieldEditorDidChange(_ notification: Notification) {
        guard let editor = observedFieldEditor, notification.object as AnyObject? === editor,
            activeFieldEditor === editor
        else { return }

        // Presentation only. Do NOT call onTextChanged here: marked text is not
        // a committed search query yet.
        updatePresentation()
    }

    @objc func fieldEditorTextStorageDidProcessEditing(_ notification: Notification) {
        guard let editor = observedFieldEditor, let storage = observedFieldEditorTextStorage,
            notification.object as AnyObject? === storage, activeFieldEditor === editor
        else { return }

        // `setMarkedText` mutates the editor's text storage. By observing this
        // transaction we update the placeholder in the same run-loop turn as
        // the IME composition instead of waiting for Enter/candidate commit.
        updatePresentation()
    }

    func beginEditingPresentation() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(reconcileEditingPresentation), object: nil)

        // mouseDown, becomeFirstResponder and NSTextFieldDelegate can all report
        // the same focus edge. Only the FIRST edge is allowed to change motion.
        guard !isEditing else { return }

        layoutSubtreeIfNeeded()

        let startX = visibleContentTranslationX()
        let shouldAnimate = stringValue.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        isEditing = true
        updatePresentation()
        layoutSubtreeIfNeeded()

        let endX = modelContentTranslationX()

        guard shouldAnimate else {
            cancelContentMotionAnimation()
            return
        }

        animateContentTranslation(from: startX, to: endX)
    }

    func animateContentTranslation(from startX: CGFloat, to endX: CGFloat) {
        guard let layer = searchContentView.layer else { return }

        contentMotionGeneration &+= 1
        let generation = contentMotionGeneration

        layer.removeAnimation(forKey: Metrics.focusSlideAnimationKey)

        let distance = abs(endX - startX)
        guard distance >= 0.5 else {
            setContentTranslationModel(endX)
            return
        }

        let duration = contentTranslationDuration(distance: distance)

        // Commit the destination as model state first. Any AppKit layout that
        // happens while the field editor is being installed can safely repeat
        // this value; it cannot overwrite the explicit animation because the
        // animated property is sublayerTransform, not NSView frame/position.
        setContentTranslationModel(endX)

        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: contentTransform(translationX: startX))
        animation.toValue = NSValue(caTransform3D: contentTransform(translationX: endX))
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.20, 1.00)
        animation.isRemovedOnCompletion = true

        layer.add(animation, forKey: Metrics.focusSlideAnimationKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self, generation == self.contentMotionGeneration else { return }

            self.searchContentView.layer?.removeAnimation(forKey: Metrics.focusSlideAnimationKey)
        }
    }

    func contentTranslationDuration(distance: CGFloat) -> CFTimeInterval {
        let content = searchContentMetrics()
        let fullDistance = max(
            1,
            abs(
                centeredContentTranslationX(
                    isRightToLeft: userInterfaceLayoutDirection == .rightToLeft, visualWidth: content.visualWidth)))
        let fraction = min(1, distance / fullDistance)

        return max(
            Metrics.minimumInterruptedSlideDuration, Metrics.focusSlideDuration * CFTimeInterval(pow(fraction, 0.72)))

    }

    // Visual translation is read from the presentation sublayerTransform
    // by visibleContentTranslationX().

    func cancelContentMotionAnimation() {
        contentMotionGeneration &+= 1
        searchContentView.layer?.removeAnimation(forKey: Metrics.focusSlideAnimationKey)
    }

    @objc func reconcileEditingPresentation() {
        let stillEditing = textField.currentEditor() != nil || window?.firstResponder === textField

        guard !stillEditing else {
            isEditing = true
            return
        }

        layoutSubtreeIfNeeded()
        let startX = visibleContentTranslationX()
        let shouldAnimate = stringValue.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        isEditing = false
        updatePresentation()
        layoutSubtreeIfNeeded()

        let endX = modelContentTranslationX()

        if shouldAnimate { animateContentTranslation(from: startX, to: endX) } else { cancelContentMotionAnimation() }
    }

    func clearSearch() {
        stringValue = ""
        onTextChanged?()
        focus(in: window)
    }

    @objc func clearButtonPressed() { clearSearch() }

    @objc func settingsButtonPressed() {
        let menuOrigin = NSPoint(
            x: settingsButton.frame.maxX - settingsMenu.size.width,
            y: settingsButton.frame.minY - Metrics.accessorySpacing)
        settingsMenu.popUp(positioning: nil, at: menuOrigin, in: self)
    }

    @objc func resetLaunchpadMenuItemPressed() { onResetRequested?() }
}
