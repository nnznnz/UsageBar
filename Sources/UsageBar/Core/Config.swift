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

    /// Providers enabled by default when the config file says nothing about them.
    /// Only Claude is on out of the box — minimal footprint, opt-in for the rest.
    private static let defaultEnabled: Set<String> = ["claude"]

    func provider(_ id: String) -> ProviderConfig {
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

    /// Load config, tolerating a missing or malformed file by falling back to
    /// sane defaults. We never crash on bad config.
    static func load() -> Config {
        var refresh = 15
        var providers: [String: ProviderConfig] = [:]

        if let data = try? Data(contentsOf: configFile),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {

            if let m = root["refreshMinutes"] as? Int { refresh = m }
            else if let m = root["refreshMinutes"] as? Double { refresh = Int(m) }

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
        }

        // Clamp refresh to a sane range. Below 5 minutes risks tripping
        // provider rate limits (Claude in particular throttles us to once / 5m).
        refresh = max(5, min(refresh, 240))
        return Config(refreshMinutes: refresh, providers: providers)
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
