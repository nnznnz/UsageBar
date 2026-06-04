import Foundation

/// Tolerant coercion helpers over the `Any` soup that `JSONSerialization`
/// produces. Providers parse vendor JSON defensively — a missing or
/// wrong-typed field yields nil rather than a crash.
enum JSON {
    static func obj(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func arr(_ v: Any?) -> [Any]? { v as? [Any] }

    static func num(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            let l = s.lowercased()
            if ["true", "1", "yes"].contains(l) { return true }
            if ["false", "0", "no"].contains(l) { return false }
        }
        return nil
    }

    /// Parse a JSON string into a dictionary.
    static func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Serialize a dictionary to compact JSON text (no whitespace). Compact form
    /// matters when writing credentials back to the keychain — some tooling
    /// mishandles embedded newlines.
    static func compactString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
