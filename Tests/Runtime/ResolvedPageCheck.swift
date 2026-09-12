// Standalone deterministic checks; link AppCore and ResolvedLaunchpadItem.swift.
// Does not open windows, discover apps, or touch the persisted user layout.
import AppCore
import Foundation

@main
struct ResolvedPageCheck {
    static func main() throws {
        func app(_ name: String) -> ApplicationRecord {
            ApplicationRecord(displayName: name, bundleIdentifier: "test.resolved.\(name)",
                              bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"))
        }
        let records = ["A", "B", "C", "D", "Missing", "External"].map(app)
        let ids = records.map { LauncherLayoutItemIdentifier.application($0.id) }
        let a = ids[0], b = ids[1], c = ids[2], missing = ids[4], external = ids[5]
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func moved(_ persisted: [LauncherLayoutItemIdentifier],
                   visible: [LauncherLayoutItemIdentifier], source: LauncherLayoutItemIdentifier,
                   slot: Int) -> [LauncherLayoutItemIdentifier] {
            let index = ResolvedLaunchpadInsertionIndex.resolve(
                visibleSlot: slot, pageIdentifiers: persisted,
                visibleIdentifiers: visible, sourceIdentifier: source
            )!
            var result = persisted.filter { $0 != source }
            result.insert(source, at: index)
            return result
        }
        check(moved([missing, a, b], visible: [a, b], source: b, slot: 1) == [missing, a, b],
              "A hidden leading reference must not turn release at B's own slot into a reorder")
        check(moved([missing, a, b], visible: [a, b], source: b, slot: 0) == [missing, b, a],
              "Moving B before A anchors by identity after the hidden leading reference")
        check(moved([a, missing, b], visible: [a, b], source: a, slot: 0) == [a, missing, b],
              "A no-op preserves unresolved references adjacent to the source")
        check(moved([a, b, missing], visible: [a, b], source: b, slot: 1) == [a, b, missing],
              "Returning to the last visible slot preserves the missing tail")
        check(moved([a, b, missing], visible: [a, b], source: external, slot: 2)
                == [a, b, external, missing], "Cross-page append stays before unresolved tail")
        check(moved([missing, a, b], visible: [a, b], source: external, slot: 1)
                == [missing, a, external, b], "Cross-page middle insertion uses the visible anchor")
        check(moved([missing], visible: [], source: external, slot: 9) == [external, missing],
              "A page with no resolved apps still accepts a drop")
        check(moved([], visible: [], source: external, slot: 0) == [external],
              "A new empty page accepts its first app")

        let complete = Array(ids.prefix(4))
        for source in complete {
            for slot in 0...5 {
                var expected = complete.filter { $0 != source }
                expected.insert(source, at: min(slot, expected.count))
                check(moved(complete, visible: complete, source: source, slot: slot) == expected,
                      "Complete catalog keeps ordinary final-slot reorder semantics")
            }
        }
        check(ResolvedLaunchpadInsertionIndex.resolve(
            visibleSlot: -1, pageIdentifiers: [a, b], visibleIdentifiers: [a, b], sourceIdentifier: a
        ) == nil, "Negative slot is rejected")
        check(ResolvedLaunchpadInsertionIndex.resolve(
            visibleSlot: 0, pageIdentifiers: [a, b], visibleIdentifiers: [a, c], sourceIdentifier: a
        ) == nil, "A stale visible identity mapping is rejected")

        let document = LauncherLayoutDocument(pages: [
            [.application(LauncherApplicationReference(application: records[4])),
             .application(LauncherApplicationReference(application: records[0])),
             .application(LauncherApplicationReference(application: records[1]))],
            [],
            [.application(LauncherApplicationReference(application: records[2]))]
        ])
        let projection = ResolvedLaunchpadItemFactory.makePages(
            document: document, applications: Array(records.prefix(3)), query: "", pageCapacity: 4
        )
        check(projection.pageCount == 3, "Projection preserves an interior empty page")
        check(projection.pages.map { $0.map(\.id) } == [[a, b], [], [c]],
              "Unresolved references are hidden without pulling later pages forward")
        check(projection.range(forPage: 1) == 2..<2, "An empty page has an empty flat range")
        check(projection.pageIndex(containing: 2) == 2, "Flat selection locates the explicit page")
        check(projection.localIndex(forFlatIndex: 2) == 0, "Local selection index ignores prior gaps")
        check(projection.range(forPage: 9).isEmpty && projection.pageIndex(containing: 3) == nil,
              "Out-of-range queries are safe")
        let search = ResolvedLaunchpadItemFactory.makePages(
            document: document, applications: Array(records.prefix(3)), query: "a", pageCapacity: 2
        )
        check(search.pages.map { $0.map(\.id) } == [[a]], "Search is packed independently of saved pages")
        check(ResolvedLaunchpadPages(pages: []).pageCount == 1, "Empty projection has one page")
        print("RESOLVED PAGES: \(checks) assertions passed")
    }
}
