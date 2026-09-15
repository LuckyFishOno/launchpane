import AppKit

final class PassThroughImageView: NSImageView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class FocusTrackingTextField: NSTextField {
    var onFocusRequested: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onFocusRequested?()
        return super.becomeFirstResponder()
    }
}
