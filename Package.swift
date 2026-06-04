// swift-tools-version:5.9
import PackageDescription

// UsageBar — a personal, single-user AI-subscription usage tracker for the macOS menu bar.
//
// Design constraint: ZERO third-party dependencies. Everything here is built on
// Apple system frameworks only (AppKit, Foundation, Security). That is the whole
// point of the project — there is no supply chain to trust, nothing to audit but
// the code in this repository, and no network egress except to the provider APIs
// themselves (enforced by an allowlist, see Net/HTTPClient.swift).
let package = Package(
    name: "UsageBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "UsageBar",
            path: "Sources/UsageBar"
            // No `dependencies:` on purpose. If you ever see a Package.resolved
            // file appear, something pulled in a dependency — investigate it.
        )
    ]
)
