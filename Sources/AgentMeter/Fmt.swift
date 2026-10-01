import Foundation

enum Fmt {
  static func usd(_ v: Double) -> String {
    // Pinned to en_US: "$" everywhere, never "US$" from the system region.
    v.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(v >= 1000 ? 0 : 2)))
  }

  /// Short enough for the menu bar: $4.20, $168, $1.2k.
  static func compactUSD(_ v: Double) -> String {
    switch v {
    case 0: "$0"
    case ..<100: String(format: "$%.2f", v)
    case ..<1000: String(format: "$%.0f", v)
    default: String(format: "$%.1fk", v / 1000)
    }
  }

  static func percent(_ v: Double) -> String {
    v < 0.01 ? "<1%" : v.formatted(.percent.precision(.fractionLength(0)))
  }

  static func tokens(_ n: Int) -> String {
    n.formatted(.number.notation(.compactName).precision(.significantDigits(3)))
  }

  /// claude-opus-5-5 → opus-5-5; dated suffixes dropped.
  static func model(_ m: String) -> String {
    var s = m.hasPrefix("claude-") ? String(m.dropFirst(7)) : m
    if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
    return s
  }

  static func ago(_ d: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
  }

  static func dayKey(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}
