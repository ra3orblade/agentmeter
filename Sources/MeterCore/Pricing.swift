import Foundation

/// USD per million tokens. Keys match model ids as prefixes; the longest match wins.
public struct Price: Codable, Equatable, Sendable {
  public var input: Double
  public var output: Double
  public var cacheWrite: Double  // 5-minute cache write
  public var cacheWrite1h: Double?
  public var cacheRead: Double

  public init(input: Double, output: Double, cacheWrite: Double, cacheWrite1h: Double? = nil, cacheRead: Double) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheWrite1h = cacheWrite1h
    self.cacheRead = cacheRead
  }
}

public struct Usage: Equatable, Sendable {
  public var input = 0
  public var output = 0
  public var cacheWrite = 0  // all cache writes, 1h included
  public var cacheWrite1h = 0
  public var cacheRead = 0

  public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheWrite1h = cacheWrite1h
    self.cacheRead = cacheRead
  }

  public var total: Int { input + output + cacheWrite + cacheRead }

  public static func += (a: inout Usage, b: Usage) {
    a.input += b.input
    a.output += b.output
    a.cacheWrite += b.cacheWrite
    a.cacheWrite1h += b.cacheWrite1h
    a.cacheRead += b.cacheRead
  }
}

public enum Pricing {
  /// Hand-kept family prefixes under the generated snapshot, so a model newer than the snapshot
  /// (claude-opus-5-7) still lands on its family's price instead of none.
  public static let fallback: [String: Price] = [
    "claude-opus-4": Price(input: 15, output: 75, cacheWrite: 18.75, cacheWrite1h: 30, cacheRead: 1.5),
    "claude-opus-4-5": Price(input: 5, output: 25, cacheWrite: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
    "claude-opus-4-6": Price(input: 5, output: 25, cacheWrite: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
    "claude-sonnet-4": Price(input: 3, output: 15, cacheWrite: 3.75, cacheWrite1h: 6, cacheRead: 0.3),
    "claude-haiku-4-5": Price(input: 1, output: 5, cacheWrite: 1.25, cacheWrite1h: 2, cacheRead: 0.1),
    "claude-3-5-haiku": Price(input: 0.8, output: 4, cacheWrite: 1, cacheWrite1h: 1.6, cacheRead: 0.08),
    "claude-opus-5": Price(input: 5, output: 25, cacheWrite: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
    "claude-sonnet-5": Price(input: 2, output: 10, cacheWrite: 2.5, cacheWrite1h: 4, cacheRead: 0.2),
    "claude-fable-5": Price(input: 10, output: 50, cacheWrite: 12.5, cacheWrite1h: 20, cacheRead: 1),
    // Point releases priced apart (LiteLLM model_prices, 2026-10-01)
    "claude-fable-5-1": Price(input: 10, output: 50, cacheWrite: 12.5, cacheWrite1h: 20, cacheRead: 0.25),
    "claude-opus-5-5": Price(input: 4, output: 20, cacheWrite: 5, cacheWrite1h: 8, cacheRead: 0.2),
    "gpt-4o": Price(input: 2.5, output: 10, cacheWrite: 2.5, cacheRead: 1.25),
    "gpt-4o-mini": Price(input: 0.15, output: 0.6, cacheWrite: 0.15, cacheRead: 0.075),
    "gpt-4.1": Price(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.5),
    "gpt-4.1-mini": Price(input: 0.4, output: 1.6, cacheWrite: 0.4, cacheRead: 0.1),
    "gpt-5": Price(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125),
    "o3": Price(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.5),
    "o4-mini": Price(input: 1.1, output: 4.4, cacheWrite: 1.1, cacheRead: 0.275),
    "gemini-2.5-pro": Price(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.31),
    "gemini-2.5-flash": Price(input: 0.3, output: 2.5, cacheWrite: 0.3, cacheRead: 0.075),
    "deepseek-chat": Price(input: 0.27, output: 1.1, cacheWrite: 0.27, cacheRead: 0.07),
    "deepseek-reasoner": Price(input: 0.55, output: 2.19, cacheWrite: 0.55, cacheRead: 0.14),
    "grok-4": Price(input: 3, output: 15, cacheWrite: 3, cacheRead: 0.75),
    "grok-3": Price(input: 3, output: 15, cacheWrite: 3, cacheRead: 0.75),
    "grok-code-fast": Price(input: 0.2, output: 1.5, cacheWrite: 0.2, cacheRead: 0.02),
    "grok-composer": Price(input: 0.2, output: 1.5, cacheWrite: 0.2, cacheRead: 0.02),
  ]

  /// Fallback < generated snapshot. What ships in the app.
  public static var builtIn: [String: Price] { fallback.merging(snapshot) { _, new in new } }

  /// Built-in table, then a downloaded LiteLLM list, then the user's own overrides — later wins.
  /// `litellm` is LiteLLM's JSON as fetched; `override` uses this table's own shape.
  public static func load(litellm: URL?, override: URL?) -> [String: Price] {
    var table = builtIn
    if let litellm, let data = try? Data(contentsOf: litellm) {
      table.merge(fromLiteLLM(data)) { _, new in new }
    }
    if let override, let data = try? Data(contentsOf: override),
      let extra = try? JSONDecoder().decode([String: Price].self, from: data)
    {
      table.merge(extra) { _, new in new }
    }
    return table
  }

  /// LiteLLM `model_prices_and_context_window.json` (USD per token) → this table. Bare ids only:
  /// provider routes like `bedrock/…` never appear in an agent's log.
  public static func fromLiteLLM(_ data: Data) -> [String: Price] {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
    func perM(_ v: Any?) -> Double? { (v as? NSNumber).map { ($0.doubleValue * 1_000_000 * 1e6).rounded() / 1e6 } }
    var out: [String: Price] = [:]
    for (k, raw) in json {
      guard !k.contains("/"), !k.contains(":"), let v = raw as? [String: Any],
        ["chat", "responses"].contains(v["mode"] as? String ?? ""), let input = perM(v["input_cost_per_token"])
      else { continue }
      out[k] = Price(
        input: input, output: perM(v["output_cost_per_token"]) ?? 0,
        cacheWrite: perM(v["cache_creation_input_token_cost"]) ?? input,
        cacheWrite1h: perM(v["cache_creation_input_token_cost_above_1hr"]),
        cacheRead: perM(v["cache_read_input_token_cost"]) ?? input)
    }
    return out
  }

  public static let liteLLMURL = URL(
    string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

  public static func price(for model: String, in table: [String: Price]) -> Price? {
    let m = model.lowercased()
    var best: String?
    for k in table.keys where m.hasPrefix(k) {
      if best == nil || k.count > best!.count { best = k }
    }
    return best.flatMap { table[$0] }
  }

  /// nil when the model is not in the table: tokens are still counted, cost is unknown.
  public static func cost(model: String, usage u: Usage, table: [String: Price]) -> Double? {
    price(for: model, in: table).map { cost(usage: u, price: $0) }
  }

  public static func cost(usage u: Usage, price p: Price) -> Double {
    let w5 = Double(u.cacheWrite - u.cacheWrite1h)
    let sum =
      Double(u.input) * p.input + Double(u.output) * p.output + w5 * p.cacheWrite
      + Double(u.cacheWrite1h) * (p.cacheWrite1h ?? p.cacheWrite) + Double(u.cacheRead) * p.cacheRead
    return sum / 1_000_000
  }
}
