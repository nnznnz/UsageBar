import Foundation
import CryptoKit

/// Claude Code usage.
///
/// Reads the OAuth credential that Claude Code stores locally (Keychain first,
/// `~/.claude/.credentials.json` as a fallback), then calls Anthropic's
/// undocumented usage endpoint to read the rolling rate-limit windows.
///
/// Safety posture:
///   • Read-only by default. We do NOT refresh or rewrite your Claude token
///     unless you set "allowTokenRefresh": true for this provider in config.
///     A heavy Claude user's stored access token is almost always fresh (Claude
///     Code refreshes it as you work), so read-only just works day to day.
///   • We never poll more than once every 5 minutes, and we honor 429
///     Retry-After, so we can't hammer Anthropic or get your account throttled.
final class ClaudeProvider: Provider {
    let id = "claude"
    let displayName = "Claude"
    let allowedHosts: Set<String> = ["api.anthropic.com", "platform.claude.com"]

    // Endpoint + OAuth constants (public protocol values, not secrets).
    private let usageURL   = "https://api.anthropic.com/api/oauth/usage"
    private let refreshURL = "https://platform.claude.com/v1/oauth/token"
    private let clientID   = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let scopes     = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private let keychainServiceBase = "Claude Code-credentials"

    private let minFetchInterval: TimeInterval = 5 * 60
    private let defaultBackoff: TimeInterval = 5 * 60

    // Per-provider state, persisted across probes (the instance is long-lived).
    // Accessed only from the scheduler's serial worker queue — no locking needed.
    private var lastFetch: Date?
    private var rateLimitedUntil: Date?
    private var cachedUsage: [String: Any]?

    // MARK: Probe

    func fetch(client: HTTPClient, config: ProviderConfig) -> ProbeResult {
        guard var creds = loadCredentials() else {
            return .notConfigured(message: "Not logged in. Run `claude` to authenticate.")
        }

        let now = Date()
        var usage: [String: Any]? = cachedUsage
        var rateNote: String?
        var staleNote: String?

        if let until = rateLimitedUntil, now < until {
            // Inside a known rate-limit window — don't even try, just reuse cache.
            rateNote = "Rate limited, retry ~\(Util.humanDuration(until: until, from: now))"
        } else {
            rateLimitedUntil = nil
            let throttled = lastFetch.map { now.timeIntervalSince($0) < minFetchInterval } ?? false

            if throttled && cachedUsage != nil {
                // Polled too recently — reuse last good data silently.
            } else {
                // Optional, opt-in proactive refresh.
                var accessToken = creds.accessToken
                if config.allowTokenRefresh, creds.isExpiringSoon(now: now),
                   let refreshed = refreshToken(&creds, client: client) {
                    accessToken = refreshed
                }

                lastFetch = now
                do {
                    var resp = try fetchUsage(client: client, token: accessToken)

                    // One reactive refresh attempt on auth failure, if allowed.
                    if (resp.status == 401 || resp.status == 403) {
                        if config.allowTokenRefresh, let refreshed = refreshToken(&creds, client: client) {
                            resp = try fetchUsage(client: client, token: refreshed)
                        }
                    }

                    switch resp.status {
                    case 401, 403:
                        let hint = config.allowTokenRefresh
                            ? "Session expired. Run `claude` to log in again."
                            : "Token expired. Open Claude Code, or set allowTokenRefresh."
                        if cachedUsage == nil { return .failure(message: hint) }
                        staleNote = hint
                    case 429:
                        let secs = retryAfterSeconds(resp) ?? defaultBackoff
                        rateLimitedUntil = now.addingTimeInterval(secs)
                        rateNote = "Rate limited, retry ~\(Util.humanDuration(until: rateLimitedUntil!, from: now))"
                    case 200..<300:
                        if let parsed = JSON.parseObject(resp.bodyText) {
                            usage = parsed
                            cachedUsage = parsed
                        } else if cachedUsage == nil {
                            return .failure(message: "Usage response invalid. Try again later.")
                        }
                    default:
                        if cachedUsage == nil {
                            return .failure(message: "Usage request failed (HTTP \(resp.status)).")
                        }
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
        }

        return .ok(buildSnapshot(usage: usage, creds: creds,
                                 rateNote: rateNote, staleNote: staleNote, now: now))
    }

    // MARK: Snapshot building

    private func buildSnapshot(usage: [String: Any]?, creds: Creds,
                               rateNote: String?, staleNote: String?, now: Date) -> ProviderSnapshot {
        var lines: [MetricLine] = []
        var headline: Double?

        if let note = rateNote { lines.append(.badge(label: "Status", text: note)) }

        // The known rolling windows, in display order. Each is a percent (0–100).
        let windows: [(key: String, label: String)] = [
            ("five_hour", "Session"),
            ("seven_day", "Weekly"),
            ("seven_day_opus", "Opus (weekly)"),
            ("seven_day_sonnet", "Sonnet (weekly)"),
            ("seven_day_omelette", "Claude Design (weekly)")
        ]
        if let usage = usage {
            for w in windows {
                guard let win = JSON.obj(usage[w.key]),
                      let util = JSON.num(win["utilization"]) else { continue }
                let resets = Util.toDate(win["resets_at"])
                lines.append(.progress(label: w.label, used: util, limit: 100,
                                       format: .percent, resetsAt: resets))
                headline = max(headline ?? 0, util)
            }

            // On-demand overage credits (cents).
            if let extra = JSON.obj(usage["extra_usage"]), JSON.bool(extra["is_enabled"]) == true {
                let usedC = JSON.num(extra["used_credits"]) ?? 0
                let limitC = JSON.num(extra["monthly_limit"]) ?? 0
                if limitC > 0 {
                    lines.append(.progress(label: "Extra usage",
                                           used: Util.dollars(cents: usedC),
                                           limit: Util.dollars(cents: limitC),
                                           format: .dollars, resetsAt: nil))
                } else if usedC > 0 {
                    lines.append(.text(label: "Extra usage",
                                       value: String(format: "$%.2f", Util.dollars(cents: usedC))))
                }
            }
        }

        if let note = staleNote { lines.append(.text(label: "Note", value: note)) }
        if lines.isEmpty { lines.append(.badge(label: "Status", text: "No usage data")) }

        return ProviderSnapshot(providerID: id, displayName: displayName,
                                plan: planLabel(creds), lines: lines,
                                fetchedAt: now, headlinePercent: headline)
    }

    private func planLabel(_ creds: Creds) -> String? {
        guard let sub = creds.subscriptionType, !sub.isEmpty else { return nil }
        var label = Util.planLabel(sub)
        if let tier = creds.rateLimitTier,
           let r = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            label += " " + String(tier[r])
        }
        return label
    }

    // MARK: HTTP

    private func fetchUsage(client: HTTPClient, token: String) throws -> HTTPClient.Response {
        try client.request(.GET, usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "UsageBar/1.0 (personal)"
        ])
    }

    private func retryAfterSeconds(_ resp: HTTPClient.Response) -> TimeInterval? {
        guard let raw = resp.header("Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let s = Double(raw) { return max(0, s) }
        if let date = Util.toDate(raw) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    // MARK: Token refresh (opt-in only)

    /// Refresh the access token and (since we changed it) write the new
    /// credential back to whichever source we read it from, so Claude Code
    /// stays logged in. Only ever called when config.allowTokenRefresh is true.
    private func refreshToken(_ creds: inout Creds, client: HTTPClient) -> String? {
        guard let refresh = creds.refreshToken else {
            Log.warn("claude: refresh requested but no refresh token present")
            return nil
        }
        let body = JSON.compactString([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
            "scope": scopes
        ]) ?? "{}"

        do {
            let resp = try client.request(.POST, refreshURL,
                                          headers: ["Content-Type": "application/json"],
                                          body: Data(body.utf8), timeout: 15)
            guard (200..<300).contains(resp.status), let json = JSON.parseObject(resp.bodyText),
                  let newToken = JSON.str(json["access_token"]) else {
                Log.warn("claude: token refresh failed (HTTP \(resp.status))")
                return nil
            }
            creds.accessToken = newToken
            if let newRefresh = JSON.str(json["refresh_token"]) { creds.refreshToken = newRefresh }
            if let expiresIn = JSON.num(json["expires_in"]) {
                creds.expiresAtMs = Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000
            }
            persist(creds)
            Log.info("claude: token refreshed and persisted to \(creds.source)")
            return newToken
        } catch {
            Log.warn("claude: token refresh error")
            return nil
        }
    }

    private func persist(_ creds: Creds) {
        // Rebuild the full credential object with our updated oauth fields.
        var oauth = JSON.obj(creds.fullData["claudeAiOauth"]) ?? [:]
        oauth["accessToken"] = creds.accessToken
        if let r = creds.refreshToken { oauth["refreshToken"] = r }
        if let e = creds.expiresAtMs { oauth["expiresAt"] = e }
        var full = creds.fullData
        full["claudeAiOauth"] = oauth
        guard let text = JSON.compactString(full) else { return }

        switch creds.source {
        case .file(let path):
            try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: Files.expand(path)))
        case .keychain(let service):
            Keychain.updateGenericPassword(service: service, value: text)
        }
    }

    // MARK: Credential loading

    private enum Source: CustomStringConvertible {
        case file(path: String)
        case keychain(service: String)

        var description: String {
            switch self {
            case .file(let p): return "file \(p)"
            case .keychain(let s): return "keychain \(s)"
            }
        }
    }

    private struct Creds {
        var accessToken: String
        var refreshToken: String?
        var expiresAtMs: Double?
        var subscriptionType: String?
        var rateLimitTier: String?
        var source: Source
        var fullData: [String: Any]

        func isExpiringSoon(now: Date, bufferMs: Double = 5 * 60 * 1000) -> Bool {
            guard let exp = expiresAtMs else { return false }
            return now.timeIntervalSince1970 * 1000 >= (exp - bufferMs)
        }
    }

    private var claudeHome: String { Files.env("CLAUDE_CONFIG_DIR") ?? "~/.claude" }

    private func loadCredentials() -> Creds? {
        // Keychain wins when valid: recent Claude Code keeps the live session in
        // the keychain and can leave a stale file behind.
        for service in keychainServiceCandidates() {
            if let raw = Keychain.readGenericPassword(service: service),
               let creds = parseCreds(raw, source: .keychain(service: service)) {
                return creds
            }
        }
        let path = claudeHome + "/.credentials.json"
        if let raw = Files.readText(path),
           let creds = parseCreds(raw, source: .file(path: path)) {
            return creds
        }
        return nil
    }

    private func keychainServiceCandidates() -> [String] {
        var out: [String] = []
        // When CLAUDE_CONFIG_DIR is set, Claude Code may use a hashed service
        // name; check it before the legacy default.
        if let dir = Files.env("CLAUDE_CONFIG_DIR") {
            let normalized = dir.precomposedStringWithCanonicalMapping  // NFC
            let digest = SHA256.hash(data: Data(normalized.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            out.append("\(keychainServiceBase)-\(hex.prefix(8))")
        }
        out.append(keychainServiceBase)
        return out
    }

    private func parseCreds(_ raw: String, source: Source) -> Creds? {
        // Value is normally JSON; tolerate a hex-encoded UTF-8 variant too.
        let json = JSON.parseObject(raw) ?? JSON.parseObject(decodeHexIfNeeded(raw) ?? "")
        guard let json = json, let oauth = JSON.obj(json["claudeAiOauth"]),
              let token = JSON.str(oauth["accessToken"]), !token.isEmpty else {
            return nil
        }
        return Creds(accessToken: token,
                     refreshToken: JSON.str(oauth["refreshToken"]),
                     expiresAtMs: JSON.num(oauth["expiresAt"]),
                     subscriptionType: JSON.str(oauth["subscriptionType"]),
                     rateLimitTier: JSON.str(oauth["rateLimitTier"]),
                     source: source,
                     fullData: json)
    }

    /// Some keychain reads can come back as hex-encoded UTF-8 ("7b0a...").
    private func decodeHexIfNeeded(_ s: String) -> String? {
        var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0, !hex.isEmpty,
              hex.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil else { return nil }
        var bytes = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
