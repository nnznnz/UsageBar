// swift-tools-version:5.9
import PackageDescription

// UsageBar — a personal, single-user AI-subscription usage tracker for the macOS menu bar.
//
// Design constraint: ZERO third-party dependencies. Everything here is built on
// Apple system frameworks only (AppKit, Foundation, Security, CryptoKit). There
// is no supply chain to trust, nothing to audit but the code in this repository,
// and no network egress except to the provider APIs themselves (enforced by an
// exact-match allowlist — see Net/HTTPClient.swift).
//
// Structure: all logic lives in the `UsageBarKit` library so it can be unit
// tested without a running app; `UsageBar` is a thin executable (just main.swift)
// that wires the kit into a menu-bar app.
let package = Package(
    name: "UsageBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "UsageBarKit",
            path: "Sources/UsageBarKit"
            // No `dependencies:` on purpose. If a Package.resolved ever appears,
            // a dependency sneaked in — investigate before trusting the build.
        ),
        .executableTarget(
            name: "UsageBar",
            dependencies: ["UsageBarKit"],
            path: "Sources/UsageBar"
        ),
        .testTarget(
            name: "UsageBarKitTests",
            dependencies: ["UsageBarKit"],
            path: "Tests/UsageBarKitTests"
        )
    ]
)
