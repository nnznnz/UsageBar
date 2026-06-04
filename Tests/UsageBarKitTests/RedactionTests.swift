import XCTest
@testable import UsageBarKit

/// Backstop for the "secrets never get logged" claim. Each case feeds a
/// token-shaped string through `Log.redact` and asserts the secret is gone.
final class RedactionTests: XCTestCase {

    private func assertRedacted(_ input: String, secret: String, file: StaticString = #filePath, line: UInt = #line) {
        let out = Log.redact(input)
        XCTAssertFalse(out.contains(secret), "expected secret to be redacted in: \(out)", file: file, line: line)
    }

    func testBearerHeader() {
        assertRedacted("Authorization: Bearer abc123DEF456ghi789jkl", secret: "abc123DEF456ghi789jkl")
    }

    func testJSONFields() {
        assertRedacted(#"{"accessToken":"sup3r-s3cret-value-here"}"#, secret: "sup3r-s3cret-value-here")
        assertRedacted(#"{"refresh_token":"rt_abcdefghijklmnop"}"#, secret: "rt_abcdefghijklmnop")
    }

    func testGitHubTokens() {
        assertRedacted("token=gho_0123456789abcdefghij", secret: "gho_0123456789abcdefghij")
        assertRedacted("ghp_ABCDEFGHIJKLMNOPQRSTUV in logs", secret: "ghp_ABCDEFGHIJKLMNOPQRSTUV")
        assertRedacted("github_pat_11ABCDEFG0abcdefghijklmnop", secret: "github_pat_11ABCDEFG0abcdefghijklmnop")
    }

    func testOpenAIAndAnthropicKeys() {
        assertRedacted("key sk-ant-api03-abcdefghijklmnop", secret: "sk-ant-api03-abcdefghijklmnop")
        assertRedacted("OPENAI sk-proj-abcdefghijklmnop12", secret: "sk-proj-abcdefghijklmnop12")
        assertRedacted("sk-abcdefghijklmnop1234567890", secret: "sk-abcdefghijklmnop1234567890")
    }

    func testJWT() {
        let jwt = "eyJhbGciOiJIUzI1Ni00000.eyJzdWIiOiIxMjM0NTY3ODkw.dBjftJeZ4CVP_mB92K27uhbU"
        assertRedacted("jwt=\(jwt)", secret: jwt)
    }

    func testNonSecretSurvives() {
        // We must not redact ordinary log content.
        let msg = "HTTP allowlist: api.github.com, chatgpt.com"
        XCTAssertEqual(Log.redact(msg), msg)
    }
}
