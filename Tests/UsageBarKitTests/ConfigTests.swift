import XCTest
@testable import UsageBarKit

/// Config must FAIL CLOSED: a present-but-broken config never silently
/// re-enables a provider the user disabled.
final class ConfigTests: XCTestCase {

    func testMissingFileUsesDefaults() {
        let cfg = Config.parse(data: nil, fileExists: false)
        XCTAssertNil(cfg.configError)
        XCTAssertTrue(cfg.provider("claude").enabled)   // default-on
        XCTAssertFalse(cfg.provider("codex").enabled)   // default-off
    }

    func testValidConfigParsed() {
        let json = #"{"refreshMinutes":30,"providers":{"claude":{"enabled":false},"codex":{"enabled":true,"allowTokenRefresh":true}}}"#
        let cfg = Config.parse(data: Data(json.utf8), fileExists: true)
        XCTAssertNil(cfg.configError)
        XCTAssertEqual(cfg.refreshMinutes, 30)
        XCTAssertFalse(cfg.provider("claude").enabled)  // explicitly disabled — must stay disabled
        XCTAssertTrue(cfg.provider("codex").enabled)
        XCTAssertTrue(cfg.provider("codex").allowTokenRefresh)
    }

    func testMalformedFileFailsClosed() {
        let cfg = Config.parse(data: Data("{ this is not json ".utf8), fileExists: true)
        XCTAssertNotNil(cfg.configError)
        // Fail closed: EVERYTHING off, including the otherwise-default-on Claude.
        XCTAssertFalse(cfg.provider("claude").enabled)
        XCTAssertFalse(cfg.provider("codex").enabled)
    }

    func testExistingButUnreadableFailsClosed() {
        // File exists (per directory listing) but couldn't be read → data nil.
        let cfg = Config.parse(data: nil, fileExists: true)
        XCTAssertNotNil(cfg.configError)
        XCTAssertFalse(cfg.provider("claude").enabled)
    }

    func testRefreshClampedToSaneRange() {
        let low = Config.parse(data: Data(#"{"refreshMinutes":1}"#.utf8), fileExists: true)
        XCTAssertEqual(low.refreshMinutes, 5)   // floor
        let high = Config.parse(data: Data(#"{"refreshMinutes":99999}"#.utf8), fileExists: true)
        XCTAssertEqual(high.refreshMinutes, 240) // ceiling
    }
}
