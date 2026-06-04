import Foundation

/// A usage provider knows how to: locate its own local credentials on this Mac,
/// call exactly one vendor's usage API, and normalize the answer.
///
/// Providers are intentionally dumb and self-contained. They get a shared
/// `HTTPClient` (whose egress is allowlisted) and nothing else. They must never
/// touch the UI, never spawn timers, and never write anything to disk except
/// (optionally, opt-in) refreshing their own auth token back to where they
/// found it.
protocol Provider: AnyObject {
    /// Stable id, kebab-case, also used as the config key. e.g. "claude".
    var id: String { get }

    /// Human display name shown in the menu. e.g. "Claude".
    var displayName: String { get }

    /// The set of hosts this provider is allowed to talk to. These are merged
    /// into the global HTTP allowlist at startup — a provider can only ever
    /// reach the hosts it declares here, so adding a provider can't silently
    /// widen network egress without it being visible in one place.
    var allowedHosts: Set<String> { get }

    /// Probe the provider. Runs on a background queue. Must be synchronous
    /// (block the worker thread) — the HTTPClient is synchronous by design so
    /// providers read top-to-bottom with no callback soup.
    func fetch(client: HTTPClient, config: ProviderConfig) -> ProbeResult

    /// Drop all cached usage / throttle state. Called when the provider is
    /// disabled so re-enabling it later (or changing its config) starts clean
    /// instead of surfacing stale data or honoring a stale throttle window.
    func reset()
}

extension Provider {
    /// Default: a provider with no cache state need do nothing.
    func reset() {}
}

/// Per-provider configuration, parsed from the user's config file. Everything
/// has a safe default so an empty config "just works" for the default provider.
struct ProviderConfig {
    /// Whether the user has turned this provider on. Defaults are decided by
    /// `Config` (Claude on, the rest off until enabled).
    var enabled: Bool

    /// Opt-in: allow this provider to refresh an expired OAuth token and write
    /// the new token back to its source (keychain/file). This is the ONLY way
    /// UsageBar ever writes a credential, and it is OFF by default. See README.
    var allowTokenRefresh: Bool

    /// Optional free-form per-provider overrides (e.g. a non-default config dir).
    var options: [String: String]

    static func defaultFor(enabled: Bool) -> ProviderConfig {
        ProviderConfig(enabled: enabled, allowTokenRefresh: false, options: [:])
    }
}
