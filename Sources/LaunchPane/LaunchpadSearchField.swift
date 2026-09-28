import AppKit
import QuartzCore

@MainActor final class LaunchpadSearchField: NSView, NSTextFieldDelegate {
    // LAUNCHPANE_SEARCH_FOCUS_SLIDE_V3_SUBLAYER_TRANSFORM
    // The icon and idle placeholder share one visual container.
    // IMPORTANT: the NSView frame never moves during focus. AppKit owns view
    // geometry and relayouts it repeatedly while the field editor becomes first
    // responder. We therefore animate only CALayer.sublayerTransform, a property
    // that AppKit layout does not overwrite.
    let searchContentView = SearchContentMotionView()
    let iconView = PassThroughImageView()
    let textField = FocusTrackingTextField()
    let centeredPlaceholderLabel = NSTextField(labelWithString: "")
    let clearButton = NSButton()
    let settingsButton = NSButton()
    let settingsMenu = NSMenu()

    let placeholder = NSAttributedString(
        string: "Search",
        attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.fontSize, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(Metrics.placeholderOpacity),
        ])

    var isEditing = false
    var contentMotionGeneration = 0

    // LAUNCHPANE_SEARCH_IME_MARKED_TEXT_V1
    //
    // NSTextField edits through the window's shared NSTextView field editor.
    // During IME composition (Zhuyin/Pinyin/Japanese/etc.), marked text can
    // exist in that editor before NSTextField's committed control value changes.
    // Keep presentation-only observation attached to that editor while focused.
    weak var observedFieldEditor: NSTextView?
    weak var observedFieldEditorTextStorage: NSTextStorage?

    var onTextChanged: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResetRequested: (() -> Void)?

    var stringValue: String {
        get { textField.currentEditor()?.string ?? textField.stringValue }
        set {
            textField.stringValue = newValue
            if let editor = textField.currentEditor(), editor.string != newValue { editor.string = newValue }
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

    @available(*, unavailable) required init?(coder _: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopFieldEditorObservation() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2

        let isRightToLeft = userInterfaceLayoutDirection == .rightToLeft
        let iconOriginY = verticallyCenteredOrigin(componentHeight: Metrics.iconSize)
        let textOriginY = verticallyCenteredOrigin(
            componentHeight: Metrics.textFieldHeight, opticalOffset: Metrics.textOpticalCenterOffset)

        layoutSearchContent(isRightToLeft: isRightToLeft, iconOriginY: iconOriginY, textOriginY: textOriginY)
        layoutSettingsButton(isRightToLeft: isRightToLeft)
        layoutClearButton(isRightToLeft: isRightToLeft)
        layoutTextField(isRightToLeft: isRightToLeft, textOriginY: textOriginY)
    }

    override func mouseDown(with _: NSEvent) { focus(in: window) }

    func focus(in window: NSWindow?) {
        beginEditingPresentation()
        window?.makeFirstResponder(textField)
    }

    func insertText(_ text: String) { textField.currentEditor()?.insertText(text) }

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
            withTarget: self, selector: #selector(reconcileEditingPresentation), object: nil)
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
            withTarget: self, selector: #selector(reconcileEditingPresentation), object: nil)
        perform(#selector(reconcileEditingPresentation), with: nil, afterDelay: 0)
    }

    func control(_: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        guard !textView.hasMarkedText() else { return false }

        if stringValue.isEmpty { onCancel?() } else { clearSearch() }
        return true
    }
}
