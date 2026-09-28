import AppKit
import QuartzCore

extension LaunchpadSearchField {
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

    var hasActiveEditor: Bool { isEditing || textField.currentEditor() != nil || window?.firstResponder === textField }

    var usesLeadingContentLayout: Bool { !stringValue.isEmpty || hasActiveEditor }

    struct SearchContentMetrics {
        let visualWidth: CGFloat
        let placeholderInkWidth: CGFloat
        let placeholderCellWidth: CGFloat
    }

    func searchContentMetrics() -> SearchContentMetrics {
        let inkWidth = placeholder.size().width
        let visualWidth = Metrics.iconSize + Metrics.iconTextSpacing + inkWidth
        let cellWidth = ceil(inkWidth + Metrics.placeholderCellHorizontalPadding * 2)
        return SearchContentMetrics(
            visualWidth: visualWidth, placeholderInkWidth: inkWidth, placeholderCellWidth: cellWidth)
    }

    func centeredContentTranslationX(isRightToLeft: Bool, visualWidth: CGFloat) -> CGFloat {
        let centeredOrigin = alignedToBackingScale((bounds.width - visualWidth) / 2)

        let leadingOrigin = alignedToBackingScale(
            isRightToLeft ? bounds.width - Metrics.horizontalInset - visualWidth : Metrics.horizontalInset)

        return alignedToBackingScale(centeredOrigin - leadingOrigin)
    }

    func layoutSearchContent(isRightToLeft: Bool, iconOriginY: CGFloat, textOriginY: CGFloat) {
        let content = searchContentMetrics()

        // Keep this NSView's geometry invariant. Changing its frame while an
        // NSTextField is becoming first responder lets AppKit relayout the same
        // backing layer and truncates an explicit position animation.
        searchContentView.frame = bounds

        // The children are permanently laid out at their final leading position.
        // Centering while idle is only a parent sublayerTransform translation.
        let iconOriginX =
            isRightToLeft ? bounds.width - Metrics.horizontalInset - Metrics.iconSize : Metrics.horizontalInset

        iconView.frame = NSRect(
            x: alignedToBackingScale(iconOriginX), y: iconOriginY, width: Metrics.iconSize, height: Metrics.iconSize)

        let placeholderOriginX =
            isRightToLeft
            ? iconView.frame.minX - Metrics.iconTextSpacing + Metrics.placeholderCellHorizontalPadding
                - content.placeholderCellWidth
            : iconView.frame.maxX + Metrics.iconTextSpacing - Metrics.placeholderCellHorizontalPadding

        centeredPlaceholderLabel.frame = NSRect(
            x: alignedToBackingScale(placeholderOriginX), y: textOriginY, width: content.placeholderCellWidth,
            height: Metrics.textFieldHeight)
        centeredPlaceholderLabel.alignment = isRightToLeft ? .right : .left
        textField.alignment = isRightToLeft ? .right : .left

        let centeredTranslation = centeredContentTranslationX(
            isRightToLeft: isRightToLeft, visualWidth: content.visualWidth)

        setContentTranslationModel(usesLeadingContentLayout ? 0 : centeredTranslation)
    }

    func layoutClearButton(isRightToLeft: Bool) {
        let clearButtonOrigin =
            isRightToLeft
            ? settingsButton.frame.maxX + Metrics.accessorySpacing
            : settingsButton.frame.minX - Metrics.accessorySpacing - Metrics.clearButtonSize
        clearButton.frame = NSRect(
            x: alignedToBackingScale(clearButtonOrigin), y: floor((bounds.height - Metrics.clearButtonSize) / 2),
            width: Metrics.clearButtonSize, height: Metrics.clearButtonSize)
    }

    func layoutSettingsButton(isRightToLeft: Bool) {
        let originX =
            isRightToLeft
            ? Metrics.horizontalInset : bounds.width - Metrics.horizontalInset - Metrics.settingsButtonSize
        settingsButton.frame = NSRect(
            x: alignedToBackingScale(originX), y: floor((bounds.height - Metrics.settingsButtonSize) / 2),
            width: Metrics.settingsButtonSize, height: Metrics.settingsButtonSize)
    }

    func layoutTextField(isRightToLeft: Bool, textOriginY: CGFloat) {
        let activeIconOrigin =
            isRightToLeft ? bounds.width - Metrics.horizontalInset - Metrics.iconSize : Metrics.horizontalInset
        let textFieldOrigin =
            isRightToLeft
            ? clearButton.frame.maxX + Metrics.textClearButtonSpacing
            : activeIconOrigin + Metrics.iconSize + Metrics.iconTextSpacing
        let textFieldMaximumX =
            isRightToLeft
            ? activeIconOrigin - Metrics.iconTextSpacing : clearButton.frame.minX - Metrics.textClearButtonSpacing

        textField.frame = NSRect(
            x: alignedToBackingScale(textFieldOrigin), y: textOriginY,
            width: max(0, alignedToBackingScale(textFieldMaximumX - textFieldOrigin)), height: Metrics.textFieldHeight)
    }

    func contentTransform(translationX: CGFloat) -> CATransform3D { CATransform3DMakeTranslation(translationX, 0, 0) }

    func setContentTranslationModel(_ translationX: CGFloat) {
        guard let layer = searchContentView.layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = contentTransform(translationX: translationX)
        CATransaction.commit()
    }

    func modelContentTranslationX() -> CGFloat { searchContentView.layer?.sublayerTransform.m41 ?? 0 }

    func visibleContentTranslationX() -> CGFloat {
        searchContentView.layer?.presentation()?.sublayerTransform.m41 ?? searchContentView.layer?.sublayerTransform.m41
            ?? 0
    }

    func verticallyCenteredOrigin(componentHeight: CGFloat, opticalOffset: CGFloat = 0) -> CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let origin = (bounds.height - componentHeight) / 2 + opticalOffset
        return (origin * scale).rounded() / scale
    }

    func alignedToBackingScale(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return (value * scale).rounded() / scale
    }

    func configureContainer() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Metrics.borderWidth
        layer?.borderColor = NSColor.white.withAlphaComponent(Metrics.borderOpacity).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(Metrics.backgroundOpacity).cgColor
    }

    func configureSearchContentView() {
        searchContentView.wantsLayer = true
        searchContentView.layer?.masksToBounds = false
        addSubview(searchContentView)
    }

    func configureIcon() {
        iconView.wantsLayer = true
        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(Metrics.iconOpacity)
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
        textField.onFocusRequested = { [weak self] in self?.beginEditingPresentation() }
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
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        clearButton.contentTintColor = NSColor.white.withAlphaComponent(Metrics.iconOpacity)
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
            systemSymbolName: "ellipsis.circle", accessibilityDescription: "Launchpad settings")
        settingsButton.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        settingsButton.isBordered = false
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.focusRingType = .none
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonPressed)
        settingsButton.setAccessibilityLabel("Launchpad settings")

        settingsMenu.autoenablesItems = false
        let resetItem = NSMenuItem(
            title: "Reset Launchpad", action: #selector(resetLaunchpadMenuItemPressed), keyEquivalent: "")
        resetItem.target = self
        settingsMenu.addItem(resetItem)
        settingsButton.menu = settingsMenu
        addSubview(settingsButton)
    }

}

/// This view is presentation-only. Returning nil from hitTest lets the parent
/// search field / real text field own pointer interaction while the visual group
/// can move freely above them.
final class SearchContentMotionView: NSView { override func hitTest(_: NSPoint) -> NSView? { nil } }
