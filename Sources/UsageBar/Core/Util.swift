import Foundation

/// Small formatting/parsing helpers shared across providers and the UI.
enum Util {

    // MARK: Timestamp parsing
    //
    // Providers hand us timestamps in three flavours: ISO-8601 strings, unix
    // seconds, and unix milliseconds. `toDate` accepts any of them.

    static func date(fromUnixSeconds s: Double) -> Date { Date(timeIntervalSince1970: s) }
    static func date(fromUnixMillis ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000.0) }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    /// Best-effort parse of "any reasonable timestamp" into a Date.
    static func toDate(_ value: Any?) -> Date? {
        switch value {
        case let d as Date:
            return d
        case let n as Double:
            return heuristicNumber(n)
        case let n as Int:
            return heuristicNumber(Double(n))
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            for p in isoParsers { if let d = p.date(from: trimmed) { return d } }
            if let n = Double(trimmed) { return heuristicNumber(n) }
            // Date-only "YYYY-MM-DD".
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = "yyyy-MM-dd"
            return df.date(from: trimmed)
        default:
            return nil
        }
    }

    /// A bare number is unix seconds if it's roughly "now in seconds", or unix
    /// millis if it's ~1000x bigger. Threshold: anything past year ~2286 in
    /// seconds is treated as millis.
    private static func heuristicNumber(_ n: Double) -> Date {
        if n > 1_000_000_000_000 { return date(fromUnixMillis: n) }
        return date(fromUnixSeconds: n)
    }

    // MARK: Human formatting

    /// "2h 5m", "3d 4h", "<1m", or "now".
    static func humanDuration(until date: Date, from now: Date = Date()) -> String {
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let d = secs / 86_400
        let h = (secs % 86_400) / 3_600
        let m = (secs % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    /// 1234567 -> "1.2M", 4200 -> "4.2K".
    static func compactNumber(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (threshold, suffix) in units where abs >= threshold {
            let scaled = abs / threshold
            let s = scaled >= 10 ? String(Int(scaled.rounded()))
                                 : String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "")
            return sign + s + suffix
        }
        return sign + String(Int(abs.rounded()))
    }

    static func dollars(cents: Double) -> Double { cents / 100.0 }

    /// "Pro" from "pro", "Max 20x" from ("max", "20"). Title-cases the plan word.
    static func planLabel(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return String(first).uppercased() + raw.dropFirst()
    }
}
