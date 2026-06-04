import Foundation

/// Codex / ChatGPT usage.
///
/// Reads the OAuth credential the Codex CLI stores (`auth.json` in one of a few
/// known locations, or the "Codex Auth" keychain item) and calls ChatGPT's
/// usage endpoint for the rolling rate-limit windows.
///
/// Read-only by default (same posture as Claude). Opt-in token refresh is
/// supported but, like Claude, writes the refreshed token back to its source so
/// the Codex CLI stays in sync.
final class CodexProvider: Provider {
    let id = "codex"
    let displayName = "Codex"
    let allowedHosts: Set<String> = ["chatgpt.com", "auth.openai.com"]

    private let usageURL   = "https://chatgpt.com/backend-api/wham/usage"
    private let refreshURL = "https://auth.openai.com/oauth/token"
    private let clientID   = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let minFetchInterval: TimeInterval = 5 * 60
    private let defaultBackoff: TimeInterval = 5 * 60

    private var lastFetch: Date?
    private var rateLimitedUntil: Date?
    private var cachedUsage: [String: Any]?

    func fetch(client: HTTPClient, config: ProviderConfig) -> ProbeResult {
        guard var creds = loadCredentials() else {
            return .notConfigured(message: "Not logged in. Run `codex` to authenticate.")
        }

        let now = Date()
        var usage: [String: Any]? = cachedUsage
        var rateNote: String?
        var staleNote: String?

        if let until = rateLimitedUntil, now < until {
            rateNote = "Rate limited, retry ~\(Util.humanDuration(until: until, from: now))"
        } else {
            rateLimitedUntil = nil
            let throttled = lastFetch.map { now.timeIntervalSince($0) < minFetchInterval } ?? false
            if !(throttled && cachedUsage != nil) {
                lastFetch = now
                do {
                    var resp = try fetchUsage(client: client, creds: creds)
                    if (resp.status == 401 || resp.status == 403),
                       config.allowTokenRefresh, let t = refreshToken(&creds, client: client) {
                        creds.accessToken = t
                        resp = try fetchUsage(client: client, creds: creds)
                    }
                    switch resp.status {
                    case 401, 403:
                        let hint = "Token expired. Open Codex, or set allowTokenRefresh."
                        if cachedUsage == nil { return .failure(message: hint) }
                        staleNote = hint
                    case 429:
                        let secs = retryAfterSeconds(resp) ?? defaultBackoff
                        rateLimitedUntil = now.addingTimeInterval(secs)
                        rateNote = "Rate limited, retry ~\(Util.humanDuration(until: rateLimitedUntil!, from: now))"
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
        }

        return .ok(buildSnapshot(usage: usage, creds: creds, rateNote: rateNote, staleNote: staleNote, now: now))
    }

    private func buildSnapshot(usage: [String: Any]?, creds: Creds,
                               rateNote: String?, staleNote: String?, now: Date) -> ProviderSnapshot {
        var lines: [MetricLine] = []
        var headline: Double?
        if let n = rateNote { lines.append(.badge(label: "Status", text: n)) }

        func addWindow(_ win: [String: Any]?, _ label: String) {
            guard let win = win, let used = JSON.num(win["used_percent"]) else { return }
            lines.append(.progress(label: label, used: used, limit: 100,
                                   format: .percent, resetsAt: Util.toDate(win["reset_at"])))
            headline = max(headline ?? 0, used)
        }

        if let usage = usage {
            if let rl = JSON.obj(usage["rate_limit"]) {
                addWindow(JSON.obj(rl["primary_window"]), "Session")
                addWindow(JSON.obj(rl["secondary_window"]), "Weekly")
            }
            if let cr = JSON.obj(usage["code_review_rate_limit"]) {
                addWindow(JSON.obj(cr["primary_window"]), "Code review (weekly)")
            }

            if let credits = JSON.obj(usage["credits"]), JSON.bool(credits["has_credits"]) == true {
                if JSON.bool(credits["unlimited"]) == true {
                    lines.append(.text(label: "Credits", value: "Unlimited"))
                } else if let bal = JSON.num(credits["balance"]) {
                    lines.append(.text(label: "Credits", value: String(format: "$%.2f left", bal)))
                }
            }
        }

        if let n = staleNote { lines.append(.text(label: "Note", value: n)) }
        if lines.isEmpty { lines.append(.badge(label: "Status", text: "No usage data")) }

        let plan = creds.planType.map { Util.planLabel($0) }
        return ProviderSnapshot(providerID: id, displayName: displayName, plan: plan,
                                lines: lines, fetchedAt: now, headlinePercent: headline)
    }

    private func fetchUsage(client: HTTPClient, creds: Creds) throws -> HTTPClient.Response {
        var headers = [
            "Authorization": "Bearer \(creds.accessToken)",
            "Accept": "application/json",
            "User-Agent": "UsageBar/1.0 (personal)"
        ]
        if let acct = creds.accountID { headers["ChatGPT-Account-Id"] = acct }
        return try client.request(.GET, usageURL, headers: headers)
    }

    private func retryAfterSeconds(_ resp: HTTPClient.Response) -> TimeInterval? {
        guard let raw = resp.header("Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let s = Double(raw) { return max(0, s) }
        if let d = Util.toDate(raw) { return max(0, d.timeIntervalSinceNow) }
        return nil
    }

    private func refreshToken(_ creds: inout Creds, client: HTTPClient) -> String? {
        guard let refresh = creds.refreshToken else { return nil }
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let form = "grant_type=refresh_token&client_id=\(enc(clientID))&refresh_token=\(enc(refresh))"
        do {
            let resp = try client.request(.POST, refreshURL,
                                          headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                          body: Data(form.utf8), timeout: 15)
            guard (200..<300).contains(resp.status), let json = JSON.parseObject(resp.bodyText),
                  let newToken = JSON.str(json["access_token"]) else {
                Log.warn("codex: token refresh failed (HTTP \(resp.status))")
                return nil
            }
            creds.accessToken = newToken
            if let r = JSON.str(json["refresh_token"]) { creds.refreshToken = r }
            if let idt = JSON.str(json["id_token"]) { creds.idToken = idt }
            persist(creds)
            return newToken
        } catch {
            Log.warn("codex: token refresh error")
            return nil
        }
    }

    private func persist(_ creds: Creds) {
        var tokens = JSON.obj(creds.fullData["tokens"]) ?? [:]
        tokens["access_token"] = creds.accessToken
        if let r = creds.refreshToken { tokens["refresh_token"] = r }
        if let idt = creds.idToken { tokens["id_token"] = idt }
        var full = creds.fullData
        full["tokens"] = tokens
        guard let text = JSON.compactString(full) else { return }
        switch creds.source {
        case .file(let path):
            try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: Files.expand(path)))
        case .keychain(let service):
            Keychain.updateGenericPassword(service: service, value: text)
        }
    }

    // MARK: Credentials

    private enum Source { case file(path: String), keychain(service: String) }

    private struct Creds {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var accountID: String?
        var planType: String?
        var source: Source
        var fullData: [String: Any]
    }

    private func loadCredentials() -> Creds? {
        var paths: [String] = []
        if let h = Files.env("CODEX_HOME") { paths.append(h.hasSuffix("/") ? h + "auth.json" : h + "/auth.json") }
        paths.append("~/.config/codex/auth.json")
        paths.append("~/.codex/auth.json")

        for p in paths {
            if let raw = Files.readText(p), let c = parseCreds(raw, source: .file(path: p)) { return c }
        }
        if let raw = Keychain.readGenericPassword(service: "Codex Auth"),
           let c = parseCreds(raw, source: .keychain(service: "Codex Auth")) {
            return c
        }
        return nil
    }

    private func parseCreds(_ raw: String, source: Source) -> Creds? {
        guard let json = JSON.parseObject(raw), let tokens = JSON.obj(json["tokens"]),
              let access = JSON.str(tokens["access_token"]), !access.isEmpty else { return nil }
        return Creds(accessToken: access,
                     refreshToken: JSON.str(tokens["refresh_token"]),
                     idToken: JSON.str(tokens["id_token"]),
                     accountID: JSON.str(tokens["account_id"]),
                     planType: JSON.str(json["plan_type"]) ?? JSON.str(tokens["plan_type"]),
                     source: source,
                     fullData: json)
    }
}
