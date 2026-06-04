import XCTest
@testable import UsageBarKit

/// The single most security-critical behavior: egress is restricted to EXACT
/// hosts. These lock in that a subdomain of an allowlisted host is rejected.
final class AllowlistTests: XCTestCase {
    let allow: Set<String> = ["api.github.com", "chatgpt.com", "api2.cursor.sh"]

    func testExactHostAllowed() {
        XCTAssertTrue(HTTPClient.isHostAllowed("api.github.com", in: allow))
        XCTAssertTrue(HTTPClient.isHostAllowed("chatgpt.com", in: allow))
        XCTAssertTrue(HTTPClient.isHostAllowed("api2.cursor.sh", in: allow))
    }

    func testSubdomainsRejected() {
        // The exact attack the README's "hard allowlist" claim must withstand.
        XCTAssertFalse(HTTPClient.isHostAllowed("evil.api.github.com", in: allow))
        XCTAssertFalse(HTTPClient.isHostAllowed("foo.chatgpt.com", in: allow))
        XCTAssertFalse(HTTPClient.isHostAllowed("api2.cursor.sh.evil.com", in: allow))
    }

    func testUnrelatedHostRejected() {
        XCTAssertFalse(HTTPClient.isHostAllowed("example.com", in: allow))
        XCTAssertFalse(HTTPClient.isHostAllowed("github.com", in: allow)) // apex not listed
        XCTAssertFalse(HTTPClient.isHostAllowed("", in: allow))
    }

    func testCaseInsensitiveAndTrailingDot() {
        XCTAssertTrue(HTTPClient.isHostAllowed("API.GitHub.com", in: allow))
        XCTAssertTrue(HTTPClient.isHostAllowed("api.github.com.", in: allow)) // FQDN form
    }
}
