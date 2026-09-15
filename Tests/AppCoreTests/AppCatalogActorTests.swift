@testable import AppCore
import Foundation
import XCTest

final class AppCatalogActorTests: XCTestCase {
    func testRefreshDeduplicatesAndSortsApplications() async {
        let alpha = makeApplication(name: "Alpha", path: "/Applications/Alpha.app")
        let beta = makeApplication(name: "Beta", path: "/Applications/Beta.app")
        let duplicateBeta = makeApplication(name: "Beta", path: "/Users/test/Applications/Beta.app")
        let catalog = AppCatalogActor(sources: [StubSource(applications: [beta, alpha, duplicateBeta])])

        let applications = await catalog.refresh()

        XCTAssertEqual(applications, [alpha, beta])
    }

    func testRefreshExcludesConfiguredBundleIdentifiers() async {
        let openLaunchpad = makeApplication(
            name: "LaunchPane",
            path: "/Applications/LaunchPane.app",
            bundleIdentifier: "org.launchpane.LaunchPane"
        )
        let safari = makeApplication(
            name: "Safari",
            path: "/Applications/Safari.app",
            bundleIdentifier: "com.apple.Safari"
        )
        let catalog = AppCatalogActor(
            sources: [StubSource(applications: [openLaunchpad, safari])],
            // Bundle identifiers are matched case-insensitively.
            excludedBundleIdentifiers: ["ORG.LAUNCHPANE.LAUNCHPANE"]
        )

        let applications = await catalog.refresh()
        let searchResults = await catalog.applications(matching: "LaunchPane")

        XCTAssertEqual(applications, [safari])
        XCTAssertTrue(searchResults.isEmpty)
    }

    func testRefreshUsesStableIdentityAcrossMovesAndRenames() async {
        let original = makeApplication(
            name: "Original Name",
            path: "/Applications/Original.app",
            bundleIdentifier: "org.example.shared"
        )
        let movedAndRenamed = makeApplication(
            name: "New Name",
            path: "/Users/test/Applications/New.app",
            bundleIdentifier: "ORG.EXAMPLE.SHARED"
        )
        let catalog = AppCatalogActor(sources: [StubSource(applications: [original, movedAndRenamed])])

        let applications = await catalog.refresh()

        XCTAssertEqual(applications, [original])
    }

    func testSearchUsesStrictCaseInsensitiveLongestCommonSubstring() async {
        let applicationTools = makeApplication(
            name: "Application tools",
            path: "/Applications/Application tools.app",
            bundleIdentifier: "org.example.applicationtools"
        )
        let catalog = AppCatalogActor(sources: [
            StubSource(applications: [applicationTools]),
        ])
        await catalog.refresh()

        // Complete contiguous substrings: accepted.
        let appMatches = await catalog.applications(matching: "app")
        let licaMatches = await catalog.applications(matching: "LICA")
        let boundaryMatches = await catalog.applications(matching: "tion t")
        let toolMatches = await catalog.applications(matching: "tool")

        XCTAssertEqual(appMatches, [applicationTools])
        XCTAssertEqual(licaMatches, [applicationTools])
        XCTAssertEqual(boundaryMatches, [applicationTools])
        XCTAssertEqual(toolMatches, [applicationTools])

        // Non-contiguous / token-skipping / typo-like queries: rejected.
        let joinedTokenMatches = await catalog.applications(matching: "apptools")
        let skippedMiddleMatches = await catalog.applications(matching: "app to")
        let typoLikeMatches = await catalog.applications(matching: "licaion")

        XCTAssertTrue(joinedTokenMatches.isEmpty)
        XCTAssertTrue(skippedMiddleMatches.isEmpty)
        XCTAssertTrue(typoLikeMatches.isEmpty)
    }

    func testSearchDoesNotMatchHiddenBundleIdentifier() async {
        let canvas = makeApplication(
            name: "Canvas",
            path: "/Applications/Canvas.app",
            bundleIdentifier: "org.example.drawing"
        )
        let catalog = AppCatalogActor(sources: [
            StubSource(applications: [canvas]),
        ])
        await catalog.refresh()

        let matches = await catalog.applications(matching: "drawing")
        XCTAssertTrue(matches.isEmpty)
    }

    func testSearchRanksExactThenPrefixThenInteriorSubstring() async {
        let exact = makeApplication(
            name: "Safari",
            path: "/Applications/Safari.app"
        )
        let prefix = makeApplication(
            name: "Safari Preview",
            path: "/Applications/Safari Preview.app"
        )
        let interior = makeApplication(
            name: "My Safari Tool",
            path: "/Applications/My Safari Tool.app"
        )
        let catalog = AppCatalogActor(sources: [
            StubSource(applications: [interior, prefix, exact]),
        ])
        await catalog.refresh()

        let matches = await catalog.applications(matching: "SAFARI")
        XCTAssertEqual(matches, [exact, prefix, interior])
    }

    func testRefreshOutcomeIsPartialWhenAnySourceThrowsAndKeepsSuccessfulResults() async {
        let alpha = makeApplication(name: "Alpha", path: "/Applications/Alpha.app")
        let beta = makeApplication(name: "Beta", path: "/Applications/Beta.app")
        let catalog = AppCatalogActor(sources: [
            StubSource(applications: [beta]),
            ThrowingSource(),
            StubSource(applications: [alpha]),
        ])

        let outcome = await catalog.refreshOutcome()

        XCTAssertEqual(outcome.applications, [alpha, beta])
        XCTAssertEqual(outcome.completeness, .partial)
    }

    func testRefreshOutcomePropagatesPartialSourceWithoutDroppingItsApplications() async {
        let alpha = makeApplication(name: "Alpha", path: "/Applications/Alpha.app")
        let catalog = AppCatalogActor(sources: [
            StubOutcomeSource(applications: [alpha], completeness: .partial),
        ])

        let outcome = await catalog.refreshOutcome()

        XCTAssertEqual(outcome.applications, [alpha])
        XCTAssertEqual(outcome.completeness, .partial)
    }

    func testStandardDiscoveryTreatsMissingOptionalRootAsComplete() throws {
        let systemRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let optionalUserRoot = URL(
            fileURLWithPath: "/Users/test/Applications",
            isDirectory: true
        )
        let alphaURL = systemRoot.appendingPathComponent("Alpha.app", isDirectory: true)
        let source = StandardApplicationDiscoverySource(
            roots: [systemRoot, optionalUserRoot],
            optionalRoots: [optionalUserRoot],
            directoryScanner: StubDirectoryScanner(outcomes: [
                systemRoot: .complete([alphaURL]),
                optionalUserRoot: .missing,
            ])
        )

        let outcome = try source.discoverApplicationsWithCompleteness()

        XCTAssertEqual(outcome.applications.map(\.displayName), ["Alpha"])
        XCTAssertEqual(outcome.completeness, .complete)
    }

    func testStandardDiscoveryMarksMissingRequiredRootAsPartial() throws {
        let systemRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let source = StandardApplicationDiscoverySource(
            roots: [systemRoot],
            directoryScanner: StubDirectoryScanner(outcomes: [systemRoot: .missing])
        )

        let outcome = try source.discoverApplicationsWithCompleteness()

        XCTAssertTrue(outcome.applications.isEmpty)
        XCTAssertEqual(outcome.completeness, .partial)
    }

    func testStandardDiscoveryMarksExistingRootScanFailureAsPartial() throws {
        let systemRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let alphaURL = systemRoot.appendingPathComponent("Alpha.app", isDirectory: true)
        let source = StandardApplicationDiscoverySource(
            roots: [systemRoot],
            directoryScanner: StubDirectoryScanner(outcomes: [
                systemRoot: .partial([alphaURL]),
            ])
        )

        let outcome = try source.discoverApplicationsWithCompleteness()

        XCTAssertEqual(outcome.applications.map(\.displayName), ["Alpha"])
        XCTAssertEqual(outcome.completeness, .partial)
    }

    private func makeApplication(
        name: String,
        path: String,
        bundleIdentifier: String? = nil
    ) -> ApplicationRecord {
        ApplicationRecord(
            displayName: name,
            bundleIdentifier: bundleIdentifier ?? "org.example.\(name.lowercased())",
            bundleURL: URL(fileURLWithPath: path)
        )
    }
}

private struct StubSource: AppDiscoverySource {
    let applications: [ApplicationRecord]

    func discoverApplications() throws -> [ApplicationRecord] {
        applications
    }
}

private struct StubOutcomeSource: AppDiscoverySource {
    let applications: [ApplicationRecord]
    let completeness: LauncherCatalogCompleteness

    func discoverApplications() throws -> [ApplicationRecord] {
        applications
    }

    func discoverApplicationsWithCompleteness() throws -> AppDiscoveryOutcome {
        AppDiscoveryOutcome(applications: applications, completeness: completeness)
    }
}

private struct ThrowingSource: AppDiscoverySource {
    func discoverApplications() throws -> [ApplicationRecord] {
        throw StubDiscoveryError.failed
    }
}

private enum StubDiscoveryError: Error {
    case failed
}

private struct StubDirectoryScanner: ApplicationRootScanning {
    let outcomes: [URL: ApplicationRootScanOutcome]

    func scanApplicationURLs(
        in root: URL,
        resourceKeys _: [URLResourceKey]
    ) -> ApplicationRootScanOutcome {
        outcomes[root] ?? .missing
    }
}
