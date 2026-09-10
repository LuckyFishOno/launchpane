import AppKit

@MainActor
public struct ScreenDisplayContextResolver {
    public init() {}

    public func resolve(_ screen: NSScreen) -> DisplayContext {
        let insets = screen.safeAreaInsets
        return DisplayContext(
            displayID: Self.displayID(for: screen),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor,
            safeInsets: DisplayInsets(
                top: insets.top,
                leading: insets.left,
                bottom: insets.bottom,
                trailing: insets.right
            ),
            hasNotch: insets.top > 0
        )
    }

    public static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
public enum DisplaySelector {
    public static func screenContainingMouse(
        screens: [NSScreen] = NSScreen.screens,
        mouseLocation: CGPoint = NSEvent.mouseLocation
    ) -> NSScreen? {
        screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? screens.first
    }

    public static func screen(
        with displayID: CGDirectDisplayID,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        screens.first { ScreenDisplayContextResolver.displayID(for: $0) == displayID }
    }
}
