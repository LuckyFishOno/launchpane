@testable import AppCore
import Foundation
import XCTest

final class ApplicationIdentityTests: XCTestCase {
    func testBundleIdentifierIsCanonicalAndSurvivesBundleMove() {
        let first = ApplicationIdentity(
            bundleIdentifier: "  COM.Example.Canvas  ",
            bundleURL: URL(fileURLWithPath: "/Applications/Canvas.app")
        )
        let moved = ApplicationIdentity(
            bundleIdentifier: "com.example.canvas",
            bundleURL: URL(fileURLWithPath: "/Users/test/Applications/Canvas.app")
        )

        XCTAssertEqual(first, moved)
        XCTAssertEqual(first.kind, .bundleIdentifier)
        XCTAssertEqual(first.value, "com.example.canvas")
    }

    func testMissingBundleIdentifierFallsBackToStandardizedAbsolutePath() {
        let identity = ApplicationIdentity(
            bundleIdentifier: " \n ",
            bundleURL: URL(fileURLWithPath: "/Applications/Utilities/../Tool.app")
        )

        XCTAssertEqual(identity.kind, .bundlePath)
        XCTAssertEqual(identity.value, "/Applications/Tool.app")
    }

    func testCodableRoundTripPreservesCanonicalIdentity() throws {
        let identity = ApplicationIdentity(
            bundleIdentifier: "org.example.Editor",
            bundleURL: URL(fileURLWithPath: "/Applications/Editor.app")
        )

        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(ApplicationIdentity.self, from: encoded)

        XCTAssertEqual(decoded, identity)
    }

    func testDecoderRejectsRelativeFallbackPath() {
        let data = Data(#"{"kind":"bundlePath","value":"Applications/App.app"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ApplicationIdentity.self, from: data))
    }
}
