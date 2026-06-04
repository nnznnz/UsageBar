import Foundation

/// User configuration, read from `~/.config/usagebar/config.json`.
///
/// The file is optional. With no file at all, UsageBar runs with Claude enabled
/// and everything else off, refreshing every 15 minutes. The file is only ever
/// READ by UsageBar; we never write it (the user owns it).
///
/// Example config.json:
/// {
///   "refreshMinutes": 15,
///   "providers": {
///     "claude":  { "enabled": true,  "allowTokenRefresh": false },
///     "codex":   { "enabled": true },
///     "copilot": { "enabled": false },
///     "cursor":  { "enabled": false }
///   }
/// }
struct Config {
    var refreshMinutes: Int
    private var providers: [String: ProviderConfig]

    /// Non-nil when config.json EXISTS but could not be parsed. In that case we
    /// fail CLOSED: `provider(_:)` reports every provider disabled and the UI
    /// shows a warning. A JSON typo must never silently re-enable a provider the
    /// user deliberately turned off.
    var configError: String?

    /// Providers enabled by default when the config file says nothing about them.
    /// Only Claude is on out of the box — minimal footprint, opt-in for the rest.
    private static let defaultEnabled: Set<String> = ["claude"]

    func provider(_ id: String) -> ProviderConfig {
        if configError != nil { return ProviderConfig.defaultFor(enabled: false) }  // fail closed
        if let c = providers[id] { return c }
        return ProviderConfig.defaultFor(enabled: Config.defaultEnabled.contains(id))
    }

    static var configDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/usagebar", isDirectory: true)
    }

    static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    /// Load config from disk. Thin wrapper over `parse` so the parsing/fail-closed
    /// logic can be unit-tested without touching the filesystem.
    static func load() -> Config {
        let exists = FileManager.default.fileExists(atPath: configFile.path)
        let data = try? Data(contentsOf: configFile)
        return parse(data: data, fileExists: exists)
    }

    /// Pure parse. Three cases:
    ///   • file absent      → defaults (Claude on). First run / intentional absence.
    ///   • file present, OK → parsed config.
    ///   • file present, bad→ FAIL CLOSED: no providers, `configError` set.
    static func parse(data: Data?, fileExists: Bool) -> Config {
        if !fileExists {
            return Config(refreshMinutes: 15, providers: [:], configError: nil)
        }
        guard let data = data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Config(refreshMinutes: 15, providers: [:],
                          configError: "config.json couldn't be parsed — all providers disabled until it's fixed")
        }

        var refresh = 15
        if let m = root["refreshMinutes"] as? Int { refresh = m }
        else if let m = root["refreshMinutes"] as? Double { refresh = Int(m) }

        var providers: [String: ProviderConfig] = [:]
        if let provs = root["providers"] as? [String: Any] {
            for (key, raw) in provs {
                guard let obj = raw as? [String: Any] else { continue }
                let enabled = (obj["enabled"] as? Bool) ?? defaultEnabled.contains(key)
                let allowRefresh = (obj["allowTokenRefresh"] as? Bool) ?? false
                var options: [String: String] = [:]
                if let opts = obj["options"] as? [String: Any] {
                    for (ok, ov) in opts { options[ok] = String(describing: ov) }
                }
                providers[key] = ProviderConfig(enabled: enabled,
                                                allowTokenRefresh: allowRefresh,
                                                options: options)
            }
        }

        // Clamp refresh to a sane range. Below 5 minutes risks tripping
        // provider rate limits (Claude in particular throttles us to once / 5m).
        refresh = max(5, min(refresh, 240))
        return Config(refreshMinutes: refresh, providers: providers, configError: nil)
    }

    /// Writes a documented starter config if none exists yet. Returns the path.
    /// This is the one time we touch the file — and only to create it, never to
    /// overwrite an existing one.
    @discardableResult
    static func writeStarterIfMissing() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configFile.path) {
            try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let starter = """
            {
              "refreshMinutes": 15,
              "providers": {
                "claude":  { "enabled": true,  "allowTokenRefresh": false },
                "codex":   { "enabled": false, "allowTokenRefresh": false },
                "copilot": { "enabled": false },
                "cursor":  { "enabled": false }
              }
            }
            """
            try? starter.data(using: .utf8)?.write(to: configFile)
        }
        return configFile
    }
}
