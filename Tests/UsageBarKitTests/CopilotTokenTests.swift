import XCTest
@testable import UsageBarKit

/// The gh hosts.yml parser must return the token for `github.com` specifically,
/// never an enterprise host's token that happens to appear first.
final class CopilotTokenTests: XCTestCase {

    func testSingleHost() {
        let yaml = """
        github.com:
            oauth_token: gho_AAA1111111111111111
            user: octocat
        """
        XCTAssertEqual(CopilotProvider.parseGitHubToken(fromHostsYAML: yaml), "gho_AAA1111111111111111")
    }

    func testEnterpriseHostBeforeGitHubIsNotChosen() {
        let yaml = """
        git.corp.example.com:
            oauth_token: ghs_ENTERPRISE0000000000
            user: employee
        github.com:
            oauth_token: gho_REAL2222222222222222
            user: octocat
        """
        XCTAssertEqual(CopilotProvider.parseGitHubToken(fromHostsYAML: yaml), "gho_REAL2222222222222222")
    }

    func testQuotedToken() {
        let yaml = """
        github.com:
            oauth_token: "gho_QUOTED333333333333333"
        """
        XCTAssertEqual(CopilotProvider.parseGitHubToken(fromHostsYAML: yaml), "gho_QUOTED333333333333333")
    }

    func testNestedUsersBlock() {
        // Newer gh format nests under `users:` — token still lives in the github.com block.
        let yaml = """
        github.com:
            users:
                octocat:
                    oauth_token: gho_NESTED44444444444444
            git_protocol: https
            user: octocat
        """
        XCTAssertEqual(CopilotProvider.parseGitHubToken(fromHostsYAML: yaml), "gho_NESTED44444444444444")
    }

    func testNoGitHubHostReturnsNil() {
        let yaml = """
        git.corp.example.com:
            oauth_token: ghs_ENTERPRISE0000000000
        """
        XCTAssertNil(CopilotProvider.parseGitHubToken(fromHostsYAML: yaml))
    }

    func testBareTokenIsNotMistakenForHostsYAML() {
        // A bare keychain token has no github.com block → parser returns nil
        // (loadToken then falls back to using it verbatim).
        XCTAssertNil(CopilotProvider.parseGitHubToken(fromHostsYAML: "gho_BARE5555555555555555"))
    }
}
