import AppKit
import QuartzCore

@MainActor
final class LaunchpadWindow: NSWindow {
    private var isDismissing = false

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    func present() {
        isDismissing = false
        alphaValue = 0
        makeKeyAndOrderFront(nil)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.20,
                0.72,
                0.20,
                1
            )
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            closeImmediately()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            // The reference recording takes roughly 0.2 s to resolve back to the desktop.
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.40,
                0,
                0.72,
                0.22
            )
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.closeImmediately()
            }
        }
    }

    private func closeImmediately() {
        super.close()
    }
}
