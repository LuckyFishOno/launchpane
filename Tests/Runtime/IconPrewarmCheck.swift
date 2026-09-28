import AppCore
import Foundation

@main struct IconPrewarmCheck {
    @MainActor static func main() {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        checkPlans(check)
        checkTasks(check)
        print("ICON PREWARM: \(assertions) assertions passed")
    }

    private static func checkPlans(_ check: (Bool, String) -> Void) {
        let apps = (0..<14).map { index in
            ApplicationRecord(
                displayName: "App \(index)", bundleIdentifier: "test.prewarm.\(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/Prewarm\(index).app"))
        }
        let folder = ResolvedLaunchpadFolder(id: UUID(), title: "First", applications: Array(apps[1...10]))
        let later = ResolvedLaunchpadFolder(id: UUID(), title: "Later", applications: [apps[10], apps[12]])
        let pages: [[ResolvedLaunchpadItem]] = [
            [.application(apps[0]), .folder(folder), .folder(folder)],
            [.application(apps[11]), .folder(later), .application(apps[0])],
        ]
        let plan = IconWarmPlan.make(pages: pages, applications: apps.reversed())
        check(
            plan.firstPageFolderContents.map(\.id) == apps[1...10].map(\.id),
            "Full folder contents have first priority")
        check(
            plan.remaining.map(\.id) == [apps[0], apps[11], apps[12], apps[13]].map(\.id),
            "Standalone, later-page, and catalog-only apps retain their priority order")
        let all = plan.firstPageFolderContents + plan.remaining
        check(Set(all.map(\.id)).count == all.count, "Repeated folders and apps are decoded only once")
        check(Set(all.map(\.id)) == Set(apps.map(\.id)), "The complete catalog is covered")
        let empty = IconWarmPlan.make(pages: [], applications: [])
        check(empty.firstPageFolderContents.isEmpty && empty.remaining.isEmpty, "Empty input schedules no work")
        let catalogOnly = IconWarmPlan.make(pages: [], applications: apps)
        check(catalogOnly.remaining.map(\.id) == apps.map(\.id), "Catalog fallback preserves discovery order")
    }

    @MainActor private static func checkTasks(_ check: (Bool, String) -> Void) {
        let tasks = IconPrewarmTasks()
        let visible = Task { @MainActor in }
        let idle = Task { @MainActor in }
        let presentation = Task { @MainActor in }
        tasks.visiblePage = visible
        tasks.idleFirstPage = idle
        tasks.presentation = presentation
        tasks.cancelVisiblePage()
        check(visible.isCancelled && tasks.visiblePage == nil, "Paging cancels and releases visible work")
        check(!presentation.isCancelled && !idle.isCancelled, "Paging preserves presentation and idle work")
        tasks.cancelPresentation()
        check(presentation.isCancelled && tasks.presentation == nil, "Dismissal releases presentation work")
        check(!idle.isCancelled && tasks.idleFirstPage != nil, "Dismissal preserves pinned idle work")
        tasks.cancelIdleFirstPage()
        check(idle.isCancelled && tasks.idleFirstPage == nil, "Idle cancellation releases its task")
        tasks.cancelVisiblePage()
        tasks.cancelPresentation()
        tasks.cancelIdleFirstPage()
        check(
            tasks.visiblePage == nil && tasks.presentation == nil && tasks.idleFirstPage == nil,
            "Cancellation is idempotent")
    }
}
