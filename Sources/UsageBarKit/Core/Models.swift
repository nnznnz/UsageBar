import Foundation

// MARK: - Normalized usage model
//
// Every provider, regardless of how wildly different its upstream API looks,
// normalizes its result into a `ProviderSnapshot`. The UI and scheduler only
// ever deal with this shape — providers are the only code that knows about
// vendor-specific JSON.

/// A single displayable metric line. Deliberately small set of cases so the
/// menu renderer stays trivial and there is nothing exotic to get wrong.
enum MetricLine {
    /// A label/value pair, e.g. ("Plan", "Max 20x") or ("Today", "$5.17 · 9.2M tokens").
    case text(label: String, value: String)

    /// A progress bar. `used` and `limit` share units defined by `format`.
    /// `used` may exceed `limit` (overage) — the renderer clamps the bar but
    /// shows the true number.
    case progress(label: String, used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?)

    /// A short status indicator, e.g. ("Status", "Rate limited, retry ~5m").
    case badge(label: String, text: String)
}

enum ProgressFormat {
    case percent          // used/limit are 0...100, limit is 100
    case dollars          // used/limit are dollar amounts
    case count(suffix: String)
}

/// The result of probing one provider at one point in time.
struct ProviderSnapshot {
    var providerID: String
    var displayName: String
    var plan: String?
    var lines: [MetricLine]
    var fetchedAt: Date

    /// The single number that best represents "how close am I to a limit",
    /// 0...100+, used to drive the menu-bar title. Nil if the provider has no
    /// percentage-style metric. Computed from the lines by the provider.
    var headlinePercent: Double?
}

/// What a provider returns from `fetch()`. Either a usable snapshot or a
/// human-readable error string (we deliberately surface short, actionable
/// messages rather than raw exceptions — same philosophy as the upstream tool).
enum ProbeResult {
    case ok(ProviderSnapshot)
    case failure(message: String)
    /// The provider isn't configured/logged-in on this machine. Distinct from a
    /// hard failure so the UI can hide it quietly rather than show a scary error.
    case notConfigured(message: String)
}

// MARK: - Errors

/// Thrown internally by providers and helpers. Always carries a user-facing,
/// non-sensitive message. Never put a token or credential into one of these.
struct UsageError: Error, CustomStringConvertible {
    let message: String
    /// When true, the UI treats this as "not set up" rather than "broken".
    let notConfigured: Bool

    init(_ message: String, notConfigured: Bool = false) {
        self.message = message
        self.notConfigured = notConfigured
    }

    var description: String { message }
}
