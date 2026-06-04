// swift-tools-version:6.0
import PackageDescription

// UsageBar — a personal, single-user AI-subscription usage tracker for the macOS menu bar.
//
// Design constraint: ZERO third-party dependencies. Everything here is built on
// Apple system frameworks only (AppKit, Foundation, Security, CryptoKit). There
// is no supply chain to trust, nothing to audit but the code in this repository,
// and no network egress except to the provider APIs themselves (enforced by an
// exact-match allowlist — see Net/HTTPClient.swift).
//
// Tools version is 6.0 (matches recent Command Line Tools / Xcode 16), but the
// code is pinned to the Swift 5 language mode via `swiftLanguageVersions` so we
// keep the exact, already-tested semantics and avoid Swift 6 strict-concurrency
// churn. (We use `swiftLanguageVersions`, the parameter that exists at
// tools-version 6.0; the `swiftLanguageModes` spelling only arrived in 6.1.)
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
    ],
    swiftLanguageVersions: [.v5]
)
