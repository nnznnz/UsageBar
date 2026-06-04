import Foundation

/// Filesystem helpers for reading local credential/config files.
/// Read-only by nature — providers use these to locate tokens that other CLIs
/// have already written. UsageBar never writes through here.
enum Files {

    /// Expand a leading `~` to the user's home directory.
    static func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path))
    }

    static func readText(_ path: String) -> String? {
        try? String(contentsOfFile: expand(path), encoding: .utf8)
    }

    /// Read and JSON-parse a file into a dictionary, tolerating absence/garbage.
    static func readJSONObject(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expand(path))) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Value of an environment variable, trimmed, or nil if unset/empty.
    static func env(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces),
              !v.isEmpty else { return nil }
        return v
    }
}
