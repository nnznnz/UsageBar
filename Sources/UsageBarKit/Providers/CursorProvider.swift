import Foundation

/// Cursor usage (experimental; off by default).
///
/// Cursor's desktop app keeps its auth token in a local SQLite file. We read it
/// read-only and call Cursor's dashboard RPC for current-period spend/usage.
///
/// Deliberately ALWAYS read-only: unlike Claude/Codex, we never refresh or write
/// Cursor's token, because Cursor's token store is a live database the running
/// app owns — writing to it from outside risks corrupting your session. If the
/// stored token is expired, we just say so. (allowTokenRefresh is ignored here.)
final class CursorProvider: Provider {
    let id = "cursor"
    let displayName = "Cursor"
    let allowedHosts: Set<String> = ["api2.cursor.sh"]

    private let usageURL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    private let planURL  = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    private let dbPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    private let minFetchInterval: TimeInterval = 3 * 60
    private var lastFetch: Date?
    private var cachedUsage: [String: Any]?
    private var cachedPlan: String?

    func reset() { lastFetch = nil; cachedUsage = nil; cachedPlan = nil }

    func fetch(client: HTTPClient, config: ProviderConfig) -> ProbeResult {
        guard let token = loadAccessToken() else {
            return .notConfigured(message: "Not signed in to Cursor on this Mac.")
        }
        let now = Date()
        var usage: [String: Any]? = cachedUsage
        var plan: String? = cachedPlan
        var staleNote: String?

        let throttled = lastFetch.map { now.timeIntervalSince($0) < minFetchInterval } ?? false
        if !(throttled && cachedUsage != nil) {
            lastFetch = now
            let headers = [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "User-Agent": "UsageBar/1.0 (personal)"
            ]
            do {
                let resp = try client.request(.POST, usageURL, headers: headers, body: Data("{}".utf8))
                switch resp.status {
                case 401, 403:
                    let hint = "Cursor token expired. Open Cursor to refresh."
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

                // Best-effort plan name; failure here is non-fatal.
                if let presp = try? client.request(.POST, planURL, headers: headers, body: Data("{}".utf8)),
                   (200..<300).contains(presp.status), let pjson = JSON.parseObject(presp.bodyText),
                   let info = JSON.obj(pjson["planInfo"]), let name = JSON.str(info["planName"]) {
                    plan = name; cachedPlan = name
                }
            } catch let e as UsageError {
                if cachedUsage == nil { return .failure(message: e.message) }
                staleNote = "Offline — showing last known usage."
            } catch {
                if cachedUsage == nil { return .failure(message: "Usage request failed.") }
                staleNote = "Offline — showing last known usage."
            }
        }

        return .ok(buildSnapshot(usage: usage, plan: plan, staleNote: staleNote, now: now))
    }

    private func buildSnapshot(usage: [String: Any]?, plan: String?, staleNote: String?, now: Date) -> ProviderSnapshot {
        var lines: [MetricLine] = []
        var headline: Double?
        var producedMetrics = false

        if let usage = usage, let pu = JSON.obj(usage["planUsage"]) {
            let resets = Util.toDate(usage["billingCycleEnd"])
            if let pct = JSON.num(pu["totalPercentUsed"]) {
                lines.append(.progress(label: "Plan usage", used: pct, limit: 100,
                                       format: .percent, resetsAt: resets))
                headline = max(headline ?? 0, pct)
                producedMetrics = true
            }
            if let included = JSON.num(pu["includedSpend"]), let limit = JSON.num(pu["limit"]), limit > 0 {
                lines.append(.progress(label: "Spend",
                                       used: Util.dollars(cents: included),
                                       limit: Util.dollars(cents: limit),
                                       format: .dollars, resetsAt: resets))
                if headline == nil { headline = included / limit * 100 }
                producedMetrics = true
            }
            if let auto = JSON.num(pu["autoPercentUsed"]), auto > 0 {
                lines.append(.text(label: "Auto", value: String(format: "%.0f%%", auto)))
            }
            if let api = JSON.num(pu["apiPercentUsed"]), api > 0 {
                lines.append(.text(label: "API/manual", value: String(format: "%.0f%%", api)))
            }
        }

        if let n = staleNote { lines.append(.text(label: "Note", value: n)) }
        if !producedMetrics {
            if usage != nil {
                lines.append(.badge(label: "Status", text: "API response not recognized — update may be needed"))
            } else {
                lines.append(.badge(label: "Status", text: "No usage data"))
            }
        }

        return ProviderSnapshot(providerID: id, displayName: displayName,
                                plan: plan.map { Util.planLabel($0) },
                                lines: lines, fetchedAt: now, headlinePercent: headline)
    }

    /// Read the bearer token from Cursor's SQLite store; fall back to the
    /// Cursor CLI keychain item.
    private func loadAccessToken() -> String? {
        if let v = SQLiteReader.value(dbPath: dbPath, key: "cursorAuth/accessToken") {
            return cleanToken(v)
        }
        if let v = Keychain.readGenericPassword(service: "cursor-access-token") {
            return cleanToken(v)
        }
        return nil
    }

    private func cleanToken(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Values are sometimes stored JSON-quoted.
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t.isEmpty ? nil : t
    }
}
