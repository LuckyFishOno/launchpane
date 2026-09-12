import AppKit
import QuartzCore

@MainActor
final class LaunchpadSearchField: NSView, NSTextFieldDelegate {
    // OPENLAUNCHPAD_SEARCH_FOCUS_SLIDE_V3_SUBLAYER_TRANSFORM
    // The icon and idle placeholder share one visual container.
    // IMPORTANT: the NSView frame never moves during focus. AppKit owns view
    // geometry and relayouts it repeatedly while the field editor becomes first
    // responder. We therefore animate only CALayer.sublayerTransform, a property
    // that AppKit layout does not overwrite.
    private let searchContentView = SearchContentMotionView()
    private let iconView = PassThroughImageView()
    private let textField = FocusTrackingTextField()
    private let centeredPlaceholderLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private let settingsButton = NSButton()
    private let settingsMenu = NSMenu()

    private let placeholder = NSAttributedString(
        string: "Search",
        attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.fontSize, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(Metrics.placeholderOpacity),
        ]
    )

    private var isEditing = false
    private var contentMotionGeneration = 0

    // OPENLAUNCHPAD_SEARCH_IME_MARKED_TEXT_V1
    //
    // NSTextField edits through the window's shared NSTextView field editor.
    // During IME composition (Zhuyin/Pinyin/Japanese/etc.), marked text can
    // exist in that editor before NSTextField's committed control value changes.
    // Keep presentation-only observation attached to that editor while focused.
    private weak var observedFieldEditor: NSTextView?
    private weak var observedFieldEditorTextStorage: NSTextStorage?

    var onTextChanged: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResetRequested: (() -> Void)?

    var stringValue: String {
        get {
            textField.currentEditor()?.string
                ?? textField.stringValue
        }
        set {
            textField.stringValue = newValue
            if let editor = textField.currentEditor(), editor.string != newValue {
                editor.string = newValue
            }
            updatePresentation()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureContainer()
        configureSearchContentView()
        configureIcon()
        configureCenteredPlaceholder()
        configureTextField()
        configureClearButton()
        configureSettingsButton()
        updatePresentation()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopFieldEditorObservation()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2

        let isRightToLeft = userInterfaceLayoutDirection == .rightToLeft
        let iconOriginY = verticallyCenteredOrigin(
            componentHeight: Metrics.iconSize
        )
        let textOriginY = verticallyCenteredOrigin(
            componentHeight: Metrics.textFieldHeight,
            opticalOffset: Metrics.textOpticalCenterOffset
        )

        layoutSearchContent(
            isRightToLeft: isRightToLeft,
            iconOriginY: iconOriginY,
            textOriginY: textOriginY
        )
        layoutSettingsButton(isRightToLeft: isRightToLeft)
        layoutClearButton(isRightToLeft: isRightToLeft)
        layoutTextField(
            isRightToLeft: isRightToLeft,
            textOriginY: textOriginY
        )
    }

    override func mouseDown(with _: NSEvent) {
        focus(in: window)
    }

    func focus(in window: NSWindow?) {
        beginEditingPresentation()
        window?.makeFirstResponder(textField)
    }

    func insertText(_ text: String) {
        textField.currentEditor()?.insertText(text)
    }

    /// A new launcher presentation is not a continuation of the old search.
    /// End the shared field editor too, including any unfinished IME input.
    func resetForPresentation() {
        stopFieldEditorObservation()
        if let editor = activeFieldEditor {
            editor.inputContext?.discardMarkedText()
            editor.unmarkText()
            editor.string = ""
            window?.endEditing(for: textField)
        }
        textField.stringValue = ""
        isEditing = false
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(reconcileEditingPresentation),
            object: nil
        )
        cancelContentMotionAnimation()
        updatePresentation()
        layoutSubtreeIfNeeded()
    }

    func controlTextDidChange(_: Notification) {
        installFieldEditorObservationIfNeeded()
        updatePresentation()
        onTextChanged?()
    }

    func controlTextDidBeginEditing(_: Notification) {
        // At this point currentEditor() is the actual shared NSTextView used by
        // the input method. Observe it before any marked-text composition starts.
        installFieldEditorObservationIfNeeded()
        beginEditingPresentation()
        updatePresentation()
    }

    func controlTextDidEndEditing(_: Notification) {
        // Read final committed/cancelled state while the field editor is still
        // available, then detach from the shared editor so another NSTextField
        // can never drive this search UI later.
        updatePresentation()
        stopFieldEditorObservation()

        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(reconcileEditingPresentation),
            object: nil
        )
        perform(
            #selector(reconcileEditingPresentation),
            with: nil,
            afterDelay: 0
        )
    }

    func control(
        _: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        guard !textView.hasMarkedText() else { return false }

        if stringValue.isEmpty {
            onCancel?()
        } else {
            clearSearch()
        }
        return true
    }
}

private extension LaunchpadSearchField {
    enum Metrics {
        static let borderWidth: CGFloat = 1
        static let borderOpacity: CGFloat = 0.2
        static let backgroundOpacity: CGFloat = 0.085
        static let horizontalInset: CGFloat = 10
        static let iconSize: CGFloat = 14
        static let iconTextSpacing: CGFloat = 5
        static let placeholderCellHorizontalPadding: CGFloat = 2
        static let clearButtonSize: CGFloat = 16
        static let settingsButtonSize: CGFloat = 18
        static let accessorySpacing: CGFloat = 5
        static let textClearButtonSpacing: CGFloat = 4
        static let textFieldHeight: CGFloat = 22
        static let textOpticalCenterOffset: CGFloat = -1.5
        static let fontSize: CGFloat = 15
        static let iconOpacity: CGFloat = 0.55
        static let placeholderOpacity: CGFloat = 0.5

        // Deliberately long enough to be perceptible, but still fast enough that
        // clicking the search field never feels delayed.
        static let focusSlideDuration: CFTimeInterval = 0.34
        static let minimumInterruptedSlideDuration: CFTimeInterval = 0.12
        static let focusSlideAnimationKey = "searchFocusContentPosition"
    }

    var hasActiveEditor: Bool {
        isEditing
            || textField.currentEditor() != nil
            || window?.firstResponder === textField
    }

    var usesLeadingContentLayout: Bool {
        !stringValue.isEmpty || hasActiveEditor
    }

    func searchContentMetrics() -> (
        visualWidth: CGFloat,
        placeholderInkWidth: CGFloat,
        placeholderCellWidth: CGFloat
    ) {
        let inkWidth = placeholder.size().width
        let visualWidth = Metrics.iconSize
            + Metrics.iconTextSpacing
            + inkWidth
        let cellWidth = ceil(
            inkWidth
                + Metrics.placeholderCellHorizontalPadding * 2
        )
        return (
            visualWidth,
            inkWidth,
            cellWidth
        )
    }

    func centeredContentTranslationX(
        isRightToLeft: Bool,
        visualWidth: CGFloat
    ) -> CGFloat {
        let centeredOrigin = alignedToBackingScale(
            (bounds.width - visualWidth) / 2
        )

        let leadingOrigin = alignedToBackingScale(
            isRightToLeft
                ? bounds.width - Metrics.horizontalInset - visualWidth
                : Metrics.horizontalInset
        )

        return alignedToBackingScale(
            centeredOrigin - leadingOrigin
        )
    }

    func layoutSearchContent(
        isRightToLeft: Bool,
        iconOriginY: CGFloat,
        textOriginY: CGFloat
    ) {
        let content = searchContentMetrics()

        // Keep this NSView's geometry invariant. Changing its frame while an
        // NSTextField is becoming first responder lets AppKit relayout the same
        // backing layer and truncates an explicit position animation.
        searchContentView.frame = bounds

        // The children are permanently laid out at their final leading position.
        // Centering while idle is only a parent sublayerTransform translation.
        let iconOriginX = isRightToLeft
            ? bounds.width - Metrics.horizontalInset - Metrics.iconSize
            : Metrics.horizontalInset

        iconView.frame = NSRect(
            x: alignedToBackingScale(iconOriginX),
            y: iconOriginY,
            width: Metrics.iconSize,
            height: Metrics.iconSize
        )

        let placeholderOriginX = isRightToLeft
            ? iconView.frame.minX
                - Metrics.iconTextSpacing
                + Metrics.placeholderCellHorizontalPadding
                - content.placeholderCellWidth
            : iconView.frame.maxX
                + Metrics.iconTextSpacing
                - Metrics.placeholderCellHorizontalPadding

        centeredPlaceholderLabel.frame = NSRect(
            x: alignedToBackingScale(placeholderOriginX),
            y: textOriginY,
            width: content.placeholderCellWidth,
            height: Metrics.textFieldHeight
        )
        centeredPlaceholderLabel.alignment = isRightToLeft ? .right : .left
        textField.alignment = isRightToLeft ? .right : .left

        let centeredTranslation = centeredContentTranslationX(
            isRightToLeft: isRightToLeft,
            visualWidth: content.visualWidth
        )

        setContentTranslationModel(
            usesLeadingContentLayout ? 0 : centeredTranslation
        )
    }

    func layoutClearButton(isRightToLeft: Bool) {
        let clearButtonOrigin = isRightToLeft
            ? settingsButton.frame.maxX + Metrics.accessorySpacing
            : settingsButton.frame.minX - Metrics.accessorySpacing - Metrics.clearButtonSize
        clearButton.frame = NSRect(
            x: alignedToBackingScale(clearButtonOrigin),
            y: floor((bounds.height - Metrics.clearButtonSize) / 2),
            width: Metrics.clearButtonSize,
            height: Metrics.clearButtonSize
        )
    }

    func layoutSettingsButton(isRightToLeft: Bool) {
        let originX = isRightToLeft
            ? Metrics.horizontalInset
            : bounds.width - Metrics.horizontalInset - Metrics.settingsButtonSize
        settingsButton.frame = NSRect(
            x: alignedToBackingScale(originX),
            y: floor((bounds.height - Metrics.settingsButtonSize) / 2),
            width: Metrics.settingsButtonSize,
            height: Metrics.settingsButtonSize
        )
    }

    func layoutTextField(
        isRightToLeft: Bool,
        textOriginY: CGFloat
    ) {
        let activeIconOrigin = isRightToLeft
            ? bounds.width - Metrics.horizontalInset - Metrics.iconSize
            : Metrics.horizontalInset
        let textFieldOrigin = isRightToLeft
            ? clearButton.frame.maxX + Metrics.textClearButtonSpacing
            : activeIconOrigin + Metrics.iconSize + Metrics.iconTextSpacing
        let textFieldMaximumX = isRightToLeft
            ? activeIconOrigin - Metrics.iconTextSpacing
            : clearButton.frame.minX - Metrics.textClearButtonSpacing

        textField.frame = NSRect(
            x: alignedToBackingScale(textFieldOrigin),
            y: textOriginY,
            width: max(
                0,
                alignedToBackingScale(textFieldMaximumX - textFieldOrigin)
            ),
            height: Metrics.textFieldHeight
        )
    }

    func contentTransform(translationX: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(
            translationX,
            0,
            0
        )
    }

    func setContentTranslationModel(_ translationX: CGFloat) {
        guard let layer = searchContentView.layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = contentTransform(
            translationX: translationX
        )
        CATransaction.commit()
    }

    func modelContentTranslationX() -> CGFloat {
        searchContentView.layer?.sublayerTransform.m41 ?? 0
    }

    func visibleContentTranslationX() -> CGFloat {
        searchContentView.layer?.presentation()?.sublayerTransform.m41
            ?? searchContentView.layer?.sublayerTransform.m41
            ?? 0
    }

    func verticallyCenteredOrigin(
        componentHeight: CGFloat,
        opticalOffset: CGFloat = 0
    ) -> CGFloat {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let origin = (bounds.height - componentHeight) / 2 + opticalOffset
        return (origin * scale).rounded() / scale
    }

    func alignedToBackingScale(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        return (value * scale).rounded() / scale
    }

    func configureContainer() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Metrics.borderWidth
        layer?.borderColor = NSColor.white
            .withAlphaComponent(Metrics.borderOpacity)
            .cgColor
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(Metrics.backgroundOpacity)
            .cgColor
    }

    func configureSearchContentView() {
        searchContentView.wantsLayer = true
        searchContentView.layer?.masksToBounds = false
        addSubview(searchContentView)
    }

    func configureIcon() {
        iconView.wantsLayer = true
        iconView.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )
        iconView.contentTintColor = NSColor.white
            .withAlphaComponent(Metrics.iconOpacity)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        iconView.setAccessibilityHidden(true)
        searchContentView.addSubview(iconView)
    }

    func configureCenteredPlaceholder() {
        centeredPlaceholderLabel.wantsLayer = true
        centeredPlaceholderLabel.attributedStringValue = placeholder
        centeredPlaceholderLabel.lineBreakMode = .byClipping
        centeredPlaceholderLabel.maximumNumberOfLines = 1
        centeredPlaceholderLabel.setAccessibilityElement(false)
        centeredPlaceholderLabel.setAccessibilityHidden(true)
        searchContentView.addSubview(centeredPlaceholderLabel)
    }

    func configureTextField() {
        textField.onFocusRequested = { [weak self] in
            self?.beginEditingPresentation()
        }
        textField.delegate = self
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: Metrics.fontSize, weight: .regular)
        textField.textColor = .white
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.setAccessibilityLabel("Search applications")
        addSubview(textField)
    }

    func configureClearButton() {
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Clear"
        )
        clearButton.contentTintColor = NSColor.white
            .withAlphaComponent(Metrics.iconOpacity)
        clearButton.isBordered = false
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.focusRingType = .none
        clearButton.target = self
        clearButton.action = #selector(clearButtonPressed)
        clearButton.isHidden = true
        clearButton.setAccessibilityLabel("Clear search")
        addSubview(clearButton)
    }

    func configureSettingsButton() {
        settingsButton.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Launchpad settings"
        )
        settingsButton.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        settingsButton.isBordered = false
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.focusRingType = .none
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonPressed)
        settingsButton.setAccessibilityLabel("Launchpad settings")

        settingsMenu.autoenablesItems = false
        let resetItem = NSMenuItem(
            title: "Reset Launchpad",
            action: #selector(resetLaunchpadMenuItemPressed),
            keyEquivalent: ""
        )
        resetItem.target = self
        settingsMenu.addItem(resetItem)
        settingsButton.menu = settingsMenu
        addSubview(settingsButton)
    }

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

    var activeFieldEditor: NSTextView? {
        textField.currentEditor() as? NSTextView
    }

    var hasTextForPlaceholderSuppression: Bool {
        // The control value is authoritative after commit.
        if !textField.stringValue.isEmpty {
            return true
        }

        guard let editor = activeFieldEditor else {
            return false
        }

        // `hasMarkedText()` is the semantic IME signal. Checking editor.string
        // as well covers the tiny transition window between insertion and the
        // control forwarding its normal text-change notification.
        return editor.hasMarkedText()
            || !editor.string.isEmpty
    }

    func installFieldEditorObservationIfNeeded() {
        guard let editor = activeFieldEditor else {
            return
        }

        let storage = editor.textStorage

        if observedFieldEditor === editor,
           observedFieldEditorTextStorage === storage {
            return
        }

        stopFieldEditorObservation()

        observedFieldEditor = editor
        observedFieldEditorTextStorage = storage

        // NSTextDidChange is the high-level signal from the field editor.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fieldEditorDidChange(_:)),
            name: NSText.didChangeNotification,
            object: editor
        )

        // IMEs can update marked characters/attributes in NSTextStorage before
        // the NSTextField's committed string changes. Observe TextKit directly
        // as the low-level, composition-safe signal.
        if let storage {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fieldEditorTextStorageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
    }

    func stopFieldEditorObservation() {
        if let editor = observedFieldEditor {
            NotificationCenter.default.removeObserver(
                self,
                name: NSText.didChangeNotification,
                object: editor
            )
        }

        if let storage = observedFieldEditorTextStorage {
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }

        observedFieldEditor = nil
        observedFieldEditorTextStorage = nil
    }

    @objc func fieldEditorDidChange(_ notification: Notification) {
        guard
            let editor = observedFieldEditor,
            notification.object as AnyObject? === editor,
            activeFieldEditor === editor
        else {
            return
        }

        // Presentation only. Do NOT call onTextChanged here: marked text is not
        // a committed search query yet.
        updatePresentation()
    }

    @objc func fieldEditorTextStorageDidProcessEditing(
        _ notification: Notification
    ) {
        guard
            let editor = observedFieldEditor,
            let storage = observedFieldEditorTextStorage,
            notification.object as AnyObject? === storage,
            activeFieldEditor === editor
        else {
            return
        }

        // `setMarkedText` mutates the editor's text storage. By observing this
        // transaction we update the placeholder in the same run-loop turn as
        // the IME composition instead of waiting for Enter/candidate commit.
        updatePresentation()
    }

    func beginEditingPresentation() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(reconcileEditingPresentation),
            object: nil
        )

        // mouseDown, becomeFirstResponder and NSTextFieldDelegate can all report
        // the same focus edge. Only the FIRST edge is allowed to change motion.
        guard !isEditing else { return }

        layoutSubtreeIfNeeded()

        let startX = visibleContentTranslationX()
        let shouldAnimate = stringValue.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        isEditing = true
        updatePresentation()
        layoutSubtreeIfNeeded()

        let endX = modelContentTranslationX()

        guard shouldAnimate else {
            cancelContentMotionAnimation()
            return
        }

        animateContentTranslation(
            from: startX,
            to: endX
        )
    }

    func animateContentTranslation(
        from startX: CGFloat,
        to endX: CGFloat
    ) {
        guard let layer = searchContentView.layer else { return }

        contentMotionGeneration &+= 1
        let generation = contentMotionGeneration

        layer.removeAnimation(
            forKey: Metrics.focusSlideAnimationKey
        )

        let distance = abs(endX - startX)
        guard distance >= 0.5 else {
            setContentTranslationModel(endX)
            return
        }

        let content = searchContentMetrics()
        let fullDistance = max(
            1,
            abs(
                centeredContentTranslationX(
                    isRightToLeft: userInterfaceLayoutDirection == .rightToLeft,
                    visualWidth: content.visualWidth
                )
            )
        )
        let fraction = min(1, distance / fullDistance)

        let duration = max(
            Metrics.minimumInterruptedSlideDuration,
            Metrics.focusSlideDuration
                * CFTimeInterval(pow(fraction, 0.72))
        )

        // Commit the destination as model state first. Any AppKit layout that
        // happens while the field editor is being installed can safely repeat
        // this value; it cannot overwrite the explicit animation because the
        // animated property is sublayerTransform, not NSView frame/position.
        setContentTranslationModel(endX)

        let animation = CABasicAnimation(
            keyPath: "sublayerTransform"
        )
        animation.fromValue = NSValue(
            caTransform3D: contentTransform(
                translationX: startX
            )
        )
        animation.toValue = NSValue(
            caTransform3D: contentTransform(
                translationX: endX
            )
        )
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.22,
            0.72,
            0.20,
            1.00
        )
        animation.isRemovedOnCompletion = true

        layer.add(
            animation,
            forKey: Metrics.focusSlideAnimationKey
        )

        DispatchQueue.main.asyncAfter(
            deadline: .now() + duration + 0.02
        ) { [weak self] in
            guard
                let self,
                generation == self.contentMotionGeneration
            else { return }

            self.searchContentView.layer?.removeAnimation(
                forKey: Metrics.focusSlideAnimationKey
            )
        }
    }

    // Visual translation is read from the presentation sublayerTransform
    // by visibleContentTranslationX().

    func cancelContentMotionAnimation() {
        contentMotionGeneration &+= 1
        searchContentView.layer?.removeAnimation(
            forKey: Metrics.focusSlideAnimationKey
        )
    }

    @objc func reconcileEditingPresentation() {
        let stillEditing = textField.currentEditor() != nil
            || window?.firstResponder === textField

        guard !stillEditing else {
            isEditing = true
            return
        }

        layoutSubtreeIfNeeded()
        let startX = visibleContentTranslationX()
        let shouldAnimate = stringValue.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        isEditing = false
        updatePresentation()
        layoutSubtreeIfNeeded()

        let endX = modelContentTranslationX()

        if shouldAnimate {
            animateContentTranslation(
                from: startX,
                to: endX
            )
        } else {
            cancelContentMotionAnimation()
        }
    }

    func clearSearch() {
        stringValue = ""
        onTextChanged?()
        focus(in: window)
    }

    @objc func clearButtonPressed() {
        clearSearch()
    }

    @objc func settingsButtonPressed() {
        let menuOrigin = NSPoint(
            x: settingsButton.frame.maxX - settingsMenu.size.width,
            y: settingsButton.frame.minY - Metrics.accessorySpacing
        )
        settingsMenu.popUp(positioning: nil, at: menuOrigin, in: self)
    }

    @objc func resetLaunchpadMenuItemPressed() {
        onResetRequested?()
    }
}

/// This view is presentation-only. Returning nil from hitTest lets the parent
/// search field / real text field own pointer interaction while the visual group
/// can move freely above them.
private final class SearchContentMotionView: NSView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
