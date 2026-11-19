import XCTest
@testable import YTDLPStudio

final class BrowserCookiesTests: XCTestCase {
    private var home = ""

    override func setUpWithError() throws {
        home = (NSTemporaryDirectory() as NSString).appendingPathComponent("jethriki-cookies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
    }

    /// Creates an empty file under the fake home folder.
    private func touch(_ relative: String) throws {
        let path = (home as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    func testNothingInstalledMeansNoCookieArguments() {
        XCTAssertTrue(BrowserCookies.available(home: home).isEmpty)
        for choice in CookieBrowser.allCases {
            XCTAssertEqual(BrowserCookies.arguments(for: choice, home: home), [], choice.rawValue)
        }
        XCTAssertNil(BrowserCookies.resolve(.none, home: home).note)
        XCTAssertNotNil(BrowserCookies.resolve(.firefox, home: home).note)
        XCTAssertNotNil(BrowserCookies.resolve(.auto, home: home).note)
    }

    func testMissingFirefoxFallsBackToInstalledBrowser() throws {
        try touch("Library/Application Support/Google/Chrome/Default/Network/Cookies")
        // A Firefox folder without a cookie database is the failure yt-dlp reports.
        try touch("Library/Application Support/Firefox/Profiles/abc.default/prefs.js")
        let resolution = BrowserCookies.resolve(.firefox, home: home)
        XCTAssertEqual(resolution.source?.browser, .chrome)
        XCTAssertEqual(resolution.note, "Firefox has no cookies on this Mac — using Chrome instead.")
        XCTAssertEqual(BrowserCookies.arguments(for: .firefox, home: home), ["--cookies-from-browser", "chrome"])
        XCTAssertEqual(BrowserCookies.arguments(for: .auto, home: home), ["--cookies-from-browser", "chrome"])
        XCTAssertNil(BrowserCookies.resolve(.chrome, home: home).note)
    }

    func testFirefoxAndItsForks() throws {
        try touch("Library/Application Support/zen/Profiles/xyz.Default (release)/cookies.sqlite")
        let profiles = (home as NSString).appendingPathComponent("Library/Application Support/zen/Profiles")
        let zen = try XCTUnwrap(BrowserCookies.source(for: .firefox, home: home))
        XCTAssertEqual(zen.name, "Zen")
        XCTAssertEqual(zen.argument, "firefox:\(profiles)")
        XCTAssertNil(BrowserCookies.resolve(.firefox, home: home).note)

        // Real Firefox wins once it has cookies, and needs no path.
        try touch("Library/Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite")
        XCTAssertEqual(BrowserCookies.arguments(for: .firefox, home: home), ["--cookies-from-browser", "firefox"])
    }

    func testSafariAndPreferenceOrder() throws {
        XCTAssertTrue(BrowserCookies.safariNeedsFullDiskAccess(home: home))
        try touch("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        XCTAssertFalse(BrowserCookies.safariNeedsFullDiskAccess(home: home))
        XCTAssertEqual(BrowserCookies.arguments(for: .auto, home: home), ["--cookies-from-browser", "safari"])

        try touch("Library/Application Support/com.operasoftware.Opera/Cookies")
        try touch("Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/Cookies")
        XCTAssertEqual(BrowserCookies.available(home: home).map(\.browser), [.brave, .opera, .safari])
        XCTAssertEqual(BrowserCookies.arguments(for: .safari, home: home), ["--cookies-from-browser", "safari"])
    }

    func testCommandUsesResolvedBrowser() {
        var options = DownloadOptions()
        options.cookieBrowser = .none
        XCTAssertFalse(CommandBuilder.arguments(for: options, urls: ["VIDEO"]).contains("--cookies-from-browser"))
    }
}
