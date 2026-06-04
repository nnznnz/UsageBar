import XCTest
@testable import UsageBarKit

/// The default Cursor DB path contains a space ("Application Support"), so the
/// file: URI must be percent-encoded or sqlite3 mis-parses it.
final class SQLiteURITests: XCTestCase {

    func testSpacesArePercentEncoded() {
        let uri = SQLiteReader.fileURI(forExpandedPath: "/Users/me/Library/Application Support/Cursor/state.vscdb")
        XCTAssertTrue(uri.hasPrefix("file://"), "got: \(uri)")
        XCTAssertTrue(uri.contains("Application%20Support"), "space not encoded: \(uri)")
        XCTAssertFalse(uri.contains("Application Support"), "raw space leaked: \(uri)")
        XCTAssertTrue(uri.hasSuffix("?immutable=1"), "missing immutable flag: \(uri)")
    }

    func testReservedCharactersEncoded() {
        let uri = SQLiteReader.fileURI(forExpandedPath: "/tmp/weird #path/db.vscdb")
        XCTAssertFalse(uri.contains(" #path"), "reserved chars not encoded: \(uri)")
        XCTAssertTrue(uri.hasSuffix("?immutable=1"))
    }
}
