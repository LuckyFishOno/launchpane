// Offscreen comparison harness: creates a hidden window, never activates the
// launcher, and uses an isolated temporary layout. Compare the same executable
// source linked with baseline/current UI sources. This does not measure visible
// WindowServer backing stores or replace manual Activity Monitor verification.
import AppKit
import Darwin
import DisplayCore
import QuartzCore

@main
struct AgentMemoryCheck {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchpane-memory-check-\(UUID().uuidString)")
        setenv("LAUNCHPANE_LAYOUT_PATH", directory.appendingPathComponent("layout.json").path, 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        report("AppKit initialized")

        let start = ContinuousClock.now
        let controller = LaunchpadWindowController()
        guard let window = controller.window,
              let root = window.contentView as? LaunchpadRootView else {
            fatalError("Missing launcher root")
        }
        print("Hidden window construction: \(start.duration(to: .now))")
        try await settle(root)
        precondition(!window.isVisible, "The probe must never show its window")
        report("Catalog and initial page icons warmed, window hidden")
        print("Display: \(root.bounds.size) points @\(window.backingScaleFactor)x")
        let applicationCount = Mirror(reflecting: root).children
            .first { $0.label == "applications" }
            .map { Mirror(reflecting: $0.value).children.count } ?? 0
        print("Discovered applications: \(applicationCount)")
        precondition(applicationCount > 0, "A populated catalog is required for a meaningful comparison")
        if CommandLine.arguments.contains("--cycle-displays") {
            let resolver = ScreenDisplayContextResolver()
            // Repeat the route to catch caches retaining another bitmap on
            // each 1x/2x round trip, without ever showing or activating a window.
            for pass in 1...2 {
                for screen in NSScreen.screens {
                    let display = resolver.resolve(screen)
                    window.setFrame(display.frame, display: false)
                    root.prepareForPresentation(displayContext: display)
                    try await settle(root)
                    precondition(!window.isVisible)
                    report("Pass \(pass), \(display.frame.size) @\(window.backingScaleFactor)x")
                }
            }
        }
        withExtendedLifetime(controller) {}
    }

    @MainActor
    private static func settle(_ root: LaunchpadRootView) async throws {
        for _ in 0..<150 {
            root.layoutSubtreeIfNeeded()
            if field(root, "isLoadingApplications", as: Bool.self) == false { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        precondition(field(root, "isLoadingApplications", as: Bool.self) == false, "Catalog refresh timed out")
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        if let task = field(root, "iconPrewarmTask", as: Task<Void, Never>.self) {
            await task.value
        }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(500))
    }

    private static func field<T>(_ object: Any, _ name: String, as: T.Type) -> T? {
        guard let value = Mirror(reflecting: object).children.first(where: { $0.label == name })?.value else {
            return nil
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first?.value as? T
        }
        return value as? T
    }

    private static func report(_ label: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "Cannot read this process's memory")
        print("\(label): \(String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)) MiB physical footprint")
    }
}
