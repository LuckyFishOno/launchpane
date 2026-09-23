// Standalone AppKit regression check for the real menu-bar opening transition.
// It uses the production windows and animation path without app discovery or
// persisted layout access.
import AppKit
import QuartzCore

@main
@MainActor
struct MenuBarOpeningAnimationCheck {
    private static let opacityAnimationKey = "LaunchPane.nativeWindowVisibility"
    private static let spatialAnimationKey = "LaunchPane.nativeRadialMotion"
    private static let expectedOpenDuration = 13.0 / 58.0
    private static let expectedOpenCurve: [Float] = [
        0.000, 0.064, 0.108, 0.161, 0.223, 0.293, 0.364,
        0.447, 0.534, 0.621, 0.713, 0.818, 0.940, 1.000,
    ]

    static func main() {
        var checks = 0
        var failures = 0

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else {
                failures += 1
                fputs("FAIL: \(message)\n", stderr)
                return
            }
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fputs("FAIL: no display is available\n", stderr)
            exit(1)
        }

        let screenFrame = screen.frame
        let launcher = LaunchpadWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        launcher.animationBehavior = .none
        launcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let launcherContent = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        launcherContent.wantsLayer = true
        launcher.contentView = launcherContent

        let backdrop = MenuBarBackdropWindow()
        let desktop = solidImage(size: screenFrame.size, color: .systemBlue)
        let wallpaper = solidImage(size: screenFrame.size, color: .systemIndigo)

        defer {
            launcher.orderOut(nil)
            backdrop.dismiss()
        }

        backdrop.present(on: screen, desktopImage: desktop, wallpaperImage: wallpaper)

        guard
            let launcherLayer = launcherContent.layer,
            let backdropLayer = backdrop.transitionLayer
        else {
            fputs("FAIL: production transition layers were not created\n", stderr)
            exit(1)
        }

        check(backdrop.isVisible, "menu-bar continuation is ordered in before the launcher opens")
        check(backdrop.contentView?.layer === backdropLayer,
              "the complete menu-bar continuation is the synchronized transition layer")
        check(backdropLayer.opacity == 0,
              "a newly ordered menu-bar continuation starts transparent")
        check(backdrop.frame.minX == screenFrame.minX && backdrop.frame.width == screenFrame.width,
              "menu-bar continuation spans the selected display")
        check(abs(backdrop.frame.maxY - screenFrame.maxY) < 0.000_001,
              "menu-bar continuation is anchored to the physical display top")
        let requiredHeight = DesktopWallpaperProvider.menuBarHeight(on: screen)
        let backingPixel = 1 / screen.backingScaleFactor
        check(backdrop.frame.height >= requiredHeight
                && backdrop.frame.height - requiredHeight <= backingPixel,
              "menu-bar continuation preserves the production overlap after backing-pixel alignment")
        check(backdrop.frame.minY < screen.visibleFrame.maxY,
              "menu-bar continuation overlaps the launcher canvas boundary")

        launcher.synchronizedBackdropLayer = backdropLayer
        launcher.present()

        check(launcher.isVisible, "launcher is ordered in by the production opening path")
        check(launcherLayer.opacity == 1 && backdropLayer.opacity == 1,
              "launcher and complete menu-bar continuation share the final model opacity")

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let launcherFade = launcherLayer.animation(forKey: opacityAnimationKey) as? CAKeyframeAnimation
        let backdropFade = backdropLayer.animation(forKey: opacityAnimationKey) as? CAKeyframeAnimation

        if reduceMotion {
            check(launcherFade == nil && backdropFade == nil,
                  "Reduce Motion resolves both synchronized surfaces without animation")
        } else {
            check(launcherFade != nil, "launcher receives the production opening opacity animation")
            check(backdropFade != nil, "menu-bar continuation receives the opening opacity animation")

            if let launcherFade, let backdropFade {
                let launcherValues = floatValues(launcherFade.values)
                let backdropValues = floatValues(backdropFade.values)
                let launcherTimes = doubleValues(launcherFade.keyTimes)
                let backdropTimes = doubleValues(backdropFade.keyTimes)

                check(launcherValues == expectedOpenCurve,
                      "launcher retains the measured opening opacity curve")
                check(backdropValues == launcherValues,
                      "menu-bar continuation uses the exact launcher opacity samples")
                check(backdropTimes == launcherTimes,
                      "menu-bar continuation uses the exact launcher opacity key times")
                check(abs(launcherFade.duration - expectedOpenDuration) < 0.000_001,
                      "launcher retains the measured 13-frame opening duration")
                check(abs(backdropFade.duration - launcherFade.duration) < 0.000_001,
                      "menu-bar continuation and launcher have identical opening durations")
                check(launcherFade.calculationMode == .linear && backdropFade.calculationMode == .linear,
                      "both surfaces interpolate the measured samples identically")
                check(launcherFade.beginTime == backdropFade.beginTime,
                      "both opacity animations enter the same Core Animation transaction timeline")
            }

            check(launcherLayer.animation(forKey: spatialAnimationKey) != nil,
                  "launcher keeps its opening spatial motion")
            check(backdropLayer.animation(forKey: spatialAnimationKey) == nil,
                  "menu-bar continuation fades without scaling away from the display edge")
        }

        print("MENU BAR OPENING: \(checks) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    private static func floatValues(_ values: [Any]?) -> [Float] {
        values?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
    }

    private static func doubleValues(_ values: [NSNumber]?) -> [Double] {
        values?.map(\.doubleValue) ?? []
    }

    private static func solidImage(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        CGRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
