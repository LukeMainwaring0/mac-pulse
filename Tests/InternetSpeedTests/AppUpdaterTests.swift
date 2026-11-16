import XCTest
@testable import InternetSpeed

final class AppUpdaterTests: XCTestCase {
    private let publicKey = "p7DmSvt5BWtBXlPV7LllvQnKJfsbYcZwx0xL3GU8pCI="

    func testLoadsSecureUpdateConfiguration() {
        let configuration = AppUpdateConfiguration.load(from: [
            "SUFeedURL": "https://github.com/LukeMainwaring0/mac-pulse/releases/latest/download/appcast.xml",
            "SUPublicEDKey": publicKey
        ])

        XCTAssertEqual(
            configuration,
            AppUpdateConfiguration(
                feedURL: URL(string: "https://github.com/LukeMainwaring0/mac-pulse/releases/latest/download/appcast.xml")!,
                publicEDKey: publicKey
            )
        )
    }

    func testRejectsMissingUpdateConfiguration() {
        XCTAssertNil(AppUpdateConfiguration.load(from: nil))
        XCTAssertNil(AppUpdateConfiguration.load(from: [:]))
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUFeedURL": "https://example.com/appcast.xml"
        ]))
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUPublicEDKey": "public-key"
        ]))
    }

    func testRejectsInsecureOrMalformedFeedURLs() {
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUFeedURL": "http://example.com/appcast.xml",
            "SUPublicEDKey": publicKey
        ]))
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUFeedURL": "not a URL",
            "SUPublicEDKey": publicKey
        ]))
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUFeedURL": "https:///appcast.xml",
            "SUPublicEDKey": publicKey
        ]))
    }

    func testRejectsBlankSigningKey() {
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "  \n"
        ]))
    }

    func testRejectsMalformedOrWrongLengthSigningKey() {
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "not-base64"
        ]))
        XCTAssertNil(AppUpdateConfiguration.load(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data("too short".utf8).base64EncodedString()
        ]))
    }
}
