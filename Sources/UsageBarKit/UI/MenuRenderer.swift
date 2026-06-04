import AppKit

/// Turns normalized `ProviderSnapshot` data into AppKit menu items. Pure-ish
/// view code: it reads model values and produces `NSMenuItem`s, nothing else.
///
/// Progress bars are drawn with Unicode block characters in a monospaced font
/// rather than custom-drawn NSViews — it looks clean in a menu, aligns reliably,
/// and keeps the UI layer tiny and hard to get wrong.
enum MenuRenderer {

    private static let barWidth = 12
    private static let labelWidth = 16

    private static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }

    // MARK: Public builders

    static func headerItem(name: String, plan: String?) -> NSMenuItem {
        let title = plan.map { "\(name) — \($0)" } ?? name
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ])
        return item
    }

    static func items(for result: ProbeResult) -> [NSMenuItem] {
        switch result {
        case .ok(let snap):
            return snap.lines.map { lineItem($0) }
        case .failure(let message):
            return [infoItem("  " + message, color: .systemRed)]
        case .notConfigured(let message):
            return [infoItem("  " + message, color: .secondaryLabelColor)]
        }
    }

    static func infoItem(_ text: String, color: NSColor = .labelColor, mono: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: mono ? monoFont : NSFont.menuFont(ofSize: 0),
            .foregroundColor: color
        ])
        return item
    }

    // MARK: Line rendering

    private static func lineItem(_ line: MetricLine) -> NSMenuItem {
        switch line {
        case .text(let label, let value):
            return mono("\(pad(label)) \(value)", color: .labelColor)

        case .badge(let label, let text):
            let color: NSColor = text.lowercased().contains("rate limit") ? .systemOrange : .secondaryLabelColor
            return mono("\(pad(label)) \(text)", color: color)

        case .progress(let label, let used, let limit, let format, let resetsAt):
            let fraction = limit > 0 ? used / limit : 0
            let bar = barString(fraction)
            let value = valueText(used: used, limit: limit, format: format)
            var text = "\(pad(label)) \(bar) \(value)"
            if let r = resetsAt {
                text += "  · \(Util.humanDuration(until: r))"
            }
            return mono(text, color: severityColor(fraction))
        }
    }

    private static func valueText(used: Double, limit: Double, format: ProgressFormat) -> String {
        switch format {
        case .percent:
            return "\(Int(used.rounded()))%"
        case .dollars:
            return String(format: "$%.2f / $%.2f", used, limit)
        case .count(let suffix):
            let s = suffix.isEmpty ? "" : " \(suffix)"
            return "\(Int(used.rounded()))/\(Int(limit.rounded()))\(s)"
        }
    }

    static func barString(_ fraction: Double, width: Int = barWidth) -> String {
        let f = max(0, min(1, fraction))
        let filled = Int((f * Double(width)).rounded())
        let clampedFilled = max(0, min(width, filled))
        return String(repeating: "█", count: clampedFilled)
             + String(repeating: "░", count: width - clampedFilled)
    }

    private static func severityColor(_ fraction: Double) -> NSColor {
        if fraction >= 0.90 { return .systemRed }
        if fraction >= 0.75 { return .systemOrange }
        return .labelColor
    }

    private static func mono(_ text: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: monoFont,
            .foregroundColor: color
        ])
        return item
    }

    /// Right-pad (never truncate) a label so bars line up in the common case.
    private static func pad(_ s: String, width: Int = labelWidth) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
