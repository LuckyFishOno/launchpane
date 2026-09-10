@testable import AppCore
import Foundation
import XCTest

final class LauncherLayoutDocumentTests: XCTestCase {
    func testVersionOneRoundTripPreservesRootAndFolderOrder() throws {
        let safari = reference("com.apple.safari")
        let mail = reference("com.apple.mail")
        let notes = reference("com.apple.notes")
        let folderID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let document = LauncherLayoutDocument(
            revision: 8,
            items: [
                .application(safari),
                .folder(LauncherFolder(
                    id: folderID,
                    customTitle: "Work",
                    applications: [mail, notes]
                )),
            ]
        )
        let codec = LauncherLayoutCodec()

        let data = try codec.encode(document)
        let decoded = try codec.decode(data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(json.contains(#""kind":"folder""#))
    }

    func testValidatorRejectsApplicationAppearingInRootAndFolder() throws {
        let duplicate = reference("org.example.duplicate")
        let other = reference("org.example.other")
        let folderID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let document = LauncherLayoutDocument(items: [
            .application(duplicate),
            .folder(LauncherFolder(id: folderID, applications: [other, duplicate])),
        ])

        XCTAssertThrowsError(try LauncherLayoutValidator.validate(document)) { error in
            XCTAssertEqual(
                error as? LauncherLayoutValidationError,
                .duplicateApplication(duplicate.identity)
            )
        }
    }

    func testValidatorRejectsSingletonFolder() throws {
        let folderID = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let document = LauncherLayoutDocument(items: [
            .folder(LauncherFolder(id: folderID, applications: [reference("org.example.one")])),
        ])

        XCTAssertThrowsError(try LauncherLayoutValidator.validate(document)) { error in
            XCTAssertEqual(
                error as? LauncherLayoutValidationError,
                .folderHasFewerThanTwoApplications(folderID)
            )
        }
    }

    func testValidatorRejectsDuplicateFolderIdentity() throws {
        let folderID = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let first = LauncherFolder(
            id: folderID,
            applications: [reference("org.example.a"), reference("org.example.b")]
        )
        let second = LauncherFolder(
            id: folderID,
            applications: [reference("org.example.c"), reference("org.example.d")]
        )
        let document = LauncherLayoutDocument(items: [.folder(first), .folder(second)])

        XCTAssertThrowsError(try LauncherLayoutValidator.validate(document)) { error in
            XCTAssertEqual(error as? LauncherLayoutValidationError, .duplicateFolder(folderID))
        }
    }

    private func reference(_ bundleIdentifier: String) -> LauncherApplicationReference {
        LauncherApplicationReference(identity: ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
        ))
    }
}
