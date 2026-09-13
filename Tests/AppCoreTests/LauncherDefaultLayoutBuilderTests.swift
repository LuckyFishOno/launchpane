@testable import AppCore
import Foundation
import XCTest

final class LauncherDefaultLayoutBuilderTests: XCTestCase {
    func testSystemUtilitiesBecomeFirstItemFolder() throws {
        let calculator = application("Calculator", path: "/System/Applications/Calculator.app")
        let terminal = application("Terminal", path: "/System/Applications/Utilities/Terminal.app")
        let safari = application("Safari", path: "/System/Applications/Safari.app")
        let console = application("Console", path: "/System/Applications/Utilities/Console.app")

        let document = LauncherDefaultLayoutBuilder.makeDocument(
            applications: [calculator, terminal, safari, console]
        )

        XCTAssertEqual(document.items.count, 3)
        XCTAssertEqual(document.items[1], .application(reference(calculator)))
        XCTAssertEqual(document.items[2], .application(reference(safari)))
        guard case let .folder(folder) = document.items[0] else {
            return XCTFail("Expected Utilities in the first Launchpad position")
        }
        XCTAssertEqual(folder.id, LauncherDefaultLayoutBuilder.utilitiesFolderID)
        XCTAssertEqual(folder.customTitle, "Utilities")
        XCTAssertEqual(folder.applications, [reference(terminal), reference(console)])
        XCTAssertNoThrow(try LauncherLayoutValidator.validate(document))
    }

    func testSimilarNamesOutsideSystemUtilitiesStayAtRoot() {
        let thirdParty = application("Terminal Utility", path: "/Applications/Terminal Utility.app")
        let userUtility = application("My Utility", path: "/Users/test/Applications/My Utility.app")

        let document = LauncherDefaultLayoutBuilder.makeDocument(
            applications: [thirdParty, userUtility]
        )

        XCTAssertEqual(document.items, [
            .application(reference(thirdParty)),
            .application(reference(userUtility)),
        ])
    }

    func testFewerThanTwoSystemUtilitiesDoNotCreateInvalidFolder() {
        let terminal = application("Terminal", path: "/System/Applications/Utilities/Terminal.app")
        let document = LauncherDefaultLayoutBuilder.makeDocument(applications: [terminal, terminal])

        XCTAssertEqual(document.items, [.application(reference(terminal))])
    }

    private func application(_ name: String, path: String) -> ApplicationRecord {
        ApplicationRecord(
            displayName: name,
            bundleIdentifier: "org.example.\(name.replacingOccurrences(of: " ", with: "-"))",
            bundleURL: URL(fileURLWithPath: path)
        )
    }

    private func reference(_ application: ApplicationRecord) -> LauncherApplicationReference {
        LauncherApplicationReference(application: application)
    }
}
