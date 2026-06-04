import Foundation

/// GitHub Copilot usage.
///
/// Uses the token the GitHub CLI (`gh`) already stores — either in
/// `~/.config/gh/hosts.yml` or the `gh:github.com` keychain item — and calls
/// GitHub's internal Copilot quota endpoint. Read-only; there is no token
/// refresh flow here (gh tokens are long-lived), so `allowTokenRefresh` is
/// irrelevant for this provider.
final class CopilotProvider: Provider {
    let id = "copilot"
    let displayName = "Copilot"
    let allowedHosts: Set<String> = ["api.github.com"]

    private let usageURL = "https://api.github.com/copilot_internal/user"
    private let minFetchInterval: TimeInterval = 3 * 60
    private var lastFetch: Date?
    private var cachedUsage: [String: Any]?

    func fetch(client: HTTPClient, config: ProviderConfig) -> ProbeResult {
        guard let token = loadToken() else {
            return .notConfigured(message: "Not logged in. Run `gh auth login`.")
        }
        let now = Date()
        var usage: [String: Any]? = cachedUsage
        var staleNote: String?

        let throttled = lastFetch.map { now.timeIntervalSince($0) < minFetchInterval } ?? false
        if !(throttled && cachedUsage != nil) {
            lastFetch = now
            do {
                let resp = try client.request(.GET, usageURL, headers: [
                    "Authorization": "token \(token)",
                    "Accept": "application/json",
                    "Editor-Version": "vscode/1.96.2",
                    "Editor-Plugin-Version": "copilot-chat/0.26.7",
                    "User-Agent": "UsageBar/1.0 (personal)",
                    "X-Github-Api-Version": "2025-04-01"
                ])
                switch resp.status {
                case 401, 403:
                    let hint = "Token invalid or lacks Copilot access. Run `gh auth login`."
                    if cachedUsage == nil { return .failure(message: hint) }
                    staleNote = hint
                case 200..<300:
                    if let parsed = JSON.parseObject(resp.bodyText) {
                        usage = parsed; cachedUsage = parsed
                    } else if cachedUsage == nil {
                        return .failure(message: "Usage response invalid.")
                    }
                default:
                    if cachedUsage == nil { return .failure(message: "Usage request failed (HTTP \(resp.status)).") }
                    staleNote = "Last update failed (HTTP \(resp.status))."
                }
            } catch let e as UsageError {
                if cachedUsage == nil { return .failure(message: e.message) }
                staleNote = "Offline — showing last known usage."
            } catch {
                if cachedUsage == nil { return .failure(message: "Usage request failed.") }
                staleNote = "Offline — showing last known usage."
            }
        }

        return .ok(buildSnapshot(usage: usage, staleNote: staleNote, now: now))
    }

    private func buildSnapshot(usage: [String: Any]?, staleNote: String?, now: Date) -> ProviderSnapshot {
        var lines: [MetricLine] = []
        var headline: Double?
        var plan: String?

        if let usage = usage {
            plan = JSON.str(usage["copilot_plan"]).map { Util.planLabel($0) }

            // Paid tier: quota_snapshots with entitlement/remaining/percent_remaining.
            if let snaps = JSON.obj(usage["quota_snapshots"]) {
                let resets = Util.toDate(usage["quota_reset_date"])
                let order: [(String, String)] = [("premium_interactions", "Premium"), ("chat", "Chat")]
                for (key, label) in order {
                    guard let q = JSON.obj(snaps[key]) else { continue }
                    if let ent = JSON.num(q["entitlement"]), ent > 0, let rem = JSON.num(q["remaining"]) {
                        let used = max(0, ent - rem)
                        lines.append(.progress(label: label, used: used, limit: ent,
                                               format: .count(suffix: "left=\(Int(rem))"),
                                               resetsAt: resets))
                        headline = max(headline ?? 0, used / ent * 100)
                    } else if let pctRem = JSON.num(q["percent_remaining"]) {
                        let used = max(0, 100 - pctRem)
                        lines.append(.progress(label: label, used: used, limit: 100,
                                               format: .percent, resetsAt: resets))
                        headline = max(headline ?? 0, used)
                    }
                }
            }

            // Free tier: limited_user_quotas (remaining) vs monthly_quotas (cap).
            if lines.isEmpty, let limited = JSON.obj(usage["limited_user_quotas"]) {
                let monthly = JSON.obj(usage["monthly_quotas"]) ?? [:]
                let resets = Util.toDate(usage["limited_user_reset_date"])
                for (key, label) in [("chat", "Chat"), ("completions", "Completions")] {
                    guard let rem = JSON.num(limited[key]), let cap = JSON.num(monthly[key]), cap > 0 else { continue }
                    let used = max(0, cap - rem)
                    lines.append(.progress(label: label, used: used, limit: cap,
                                           format: .count(suffix: "left=\(Int(rem))"), resetsAt: resets))
                    headline = max(headline ?? 0, used / cap * 100)
                }
            }
        }

        if let n = staleNote { lines.append(.text(label: "Note", value: n)) }
        if lines.isEmpty { lines.append(.badge(label: "Status", text: "No usage data")) }

        return ProviderSnapshot(providerID: id, displayName: displayName, plan: plan,
                                lines: lines, fetchedAt: now, headlinePercent: headline)
    }

    // MARK: Token

    /// Prefer the file (no keychain prompt), then the gh keychain item.
    private func loadToken() -> String? {
        if let text = Files.readText("~/.config/gh/hosts.yml"),
           let token = scanOAuthToken(text) {
            return token
        }
        // gh stores the token under service "gh:github.com" when keyring is used.
        if let raw = Keychain.readGenericPassword(service: "gh:github.com") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // The item is usually the bare token; tolerate a YAML/JSON-ish blob too.
            return scanOAuthToken(trimmed) ?? (trimmed.isEmpty ? nil : trimmed)
        }
        return nil
    }

    /// Pull `oauth_token: <value>` out of gh's YAML without a YAML parser —
    /// one field, one regex; no need to add a dependency for this.
    private func scanOAuthToken(_ text: String) -> String? {
        guard let r = text.range(of: #"oauth_token:\s*([^\s"']+)"#, options: .regularExpression) else { return nil }
        let match = String(text[r])
        guard let colon = match.firstIndex(of: ":") else { return nil }
        let value = match[match.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
