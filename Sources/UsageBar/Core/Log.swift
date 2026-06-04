import Foundation

/// Tiny stderr logger. Two rules:
///   1. It only writes to stderr — never to a file, never to the network.
///   2. It refuses to print anything that looks like a secret.
///
/// (2) is enforced by `redact()`, which scrubs long token-ish substrings and
/// known credential field names before anything is printed. Defense in depth:
/// we also simply never pass raw tokens to the logger, but if a future change
/// slips up, the redactor is the backstop.
enum Log {
    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    static func info(_ m: String)  { line(.info, m) }
    static func warn(_ m: String)  { line(.warn, m) }
    static func error(_ m: String) { line(.error, m) }

    private static func line(_ level: Level, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(level.rawValue) \(redact(message))\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Replace anything that looks like a credential with "‹redacted›".
    static func redact(_ s: String) -> String {
        var out = s

        // 1) Bearer / token headers.
        out = replaceRegex(out, pattern: "(?i)(bearer|token)\\s+[A-Za-z0-9._\\-]{8,}", with: "$1 ‹redacted›")

        // 2) JSON-ish "field": "value" for known secret field names.
        let secretFields = ["accessToken", "refreshToken", "access_token", "refresh_token",
                            "id_token", "oauth_token", "OPENAI_API_KEY", "password", "token"]
        for f in secretFields {
            out = replaceRegex(out, pattern: "(?i)(\"?\(f)\"?\\s*[:=]\\s*\"?)[^\"\\s,}]{6,}",
                               with: "$1‹redacted›")
        }

        // 3) Long opaque blobs (JWTs and similar) anywhere in the string.
        out = replaceRegex(out, pattern: "[A-Za-z0-9_\\-]{20,}\\.[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}",
                           with: "‹redacted-jwt›")

        return out
    }

    private static func replaceRegex(_ input: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return re.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }
}
