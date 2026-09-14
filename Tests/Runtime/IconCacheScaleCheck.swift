// Deterministic cache checks using synthetic original-resolution, 64-bit P3
// images. No NSWorkspace icon service, windows, or application layout is used.
import AppCore
import AppKit

@main
struct IconCacheScaleCheck {
    @MainActor
    static func main() async {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let application = ApplicationRecord(
            displayName: "Fixture", bundleIdentifier: "test.memory.fixture",
            bundleURL: URL(fileURLWithPath: "/test/Fixture.app")
        )
        let cache = AppIconCache(decode: { _, size in image(for: size) })
        let low = await cache.loadCGImage(for: application, pointSize: 96, scale: 1)!
        check(low.width == 256, "Original 1x representation is retained")
        check(cache.cgImage(for: application, pointSize: 96, scale: 2) == nil,
              "A 256px original requested at 1x must not satisfy the 2x request")
        let high = await cache.loadCGImage(for: application, pointSize: 96, scale: 2)!
        check(high.width == 512 && high.height == 512, "2x retains original representation dimensions")
        check(high.bitsPerComponent == 16 && high.bitsPerPixel == 64, "No bit-depth conversion")
        check(high.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3, "Original color space is retained")
        check(high !== low, "2x loads the higher-resolution original")
        check(cache.cgImage(for: application, pointSize: 96, scale: 1) === high,
              "1x reuses the exact higher-resolution image instead of retaining a second bitmap")
        check(cache.cgImage(for: application, pointSize: 96, scale: 2) === high, "2x remains ready")
        let repeated = await cache.loadCGImage(for: application, pointSize: 96, scale: 1)
        check(repeated === high, "Returning to 1x does not decode another bitmap")
        check(cache.cgImage(for: application, pointSize: 192, scale: 1) === high,
              "Equivalent requested backing pixels share the image")
        check(cache.cgImage(for: application, pointSize: 192, scale: 2) == nil,
              "Requests larger than the cached request still load independently")

        let movedApplication = ApplicationRecord(
            displayName: "Fixture", bundleIdentifier: "test.memory.fixture",
            bundleURL: URL(fileURLWithPath: "/different/Fixture.app")
        )
        check(cache.cgImage(for: movedApplication, pointSize: 96, scale: 1) == nil,
              "A changed bundle path cannot reuse stale artwork")

        // Deliberately complete the small request AFTER the large one. Arrival
        // order must neither downgrade the cached image nor add a second key.
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let racing = AppIconCache(decode: { _, size in
            if size == 96 {
                started.signal()
                release.wait()
            }
            return image(for: size)
        })
        let pendingSmall = Task { await racing.loadCGImage(for: application, pointSize: 96, scale: 1) }
        await waitForDecoder(started)
        let readyLarge = await racing.loadCGImage(for: application, pointSize: 96, scale: 2)!
        release.signal()
        _ = await pendingSmall.value
        check(racing.cgImage(for: application, pointSize: 96, scale: 1) === readyLarge,
              "Late small completion cannot replace the large cached original")
        check(racing.cgImage(for: application, pointSize: 96, scale: 2) === readyLarge,
              "Late completion leaves high-resolution requests warm")

        racing.removeAll()
        check(racing.cgImage(for: application, pointSize: 96, scale: 1) == nil, "Explicit clearing removes all scales")
        let pendingCleared = Task { await racing.loadCGImage(for: application, pointSize: 96, scale: 1) }
        await waitForDecoder(started)
        racing.removeAll()
        release.signal()
        _ = await pendingCleared.value
        check(racing.cgImage(for: application, pointSize: 96, scale: 1) == nil,
              "A load finishing after clearing must not repopulate the cache")
        print("ICON CACHE SCALES: \(checks) assertions passed")
    }

    nonisolated private static func waitForDecoder(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    nonisolated private static func image(for request: Int) -> CGImage {
        // Model NSWorkspace returning more pixels than the requested size.
        let size = request <= 96 ? 256 : 512
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 16, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.75, green: 0.2, blue: 0.6, alpha: 0.8)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }
}
