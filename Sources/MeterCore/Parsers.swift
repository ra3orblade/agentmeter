import Foundation

public enum Agent: String, CaseIterable, Codable, Sendable {
  case claude, codex, gemini, grok, opencode

  public var label: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .gemini: "Gemini CLI"
    case .grok: "Grok"
    case .opencode: "opencode"
    }
  }
}

/// One billed model response. `id` is stable across rescans, so re-reading a line overwrites
/// its own row instead of adding a duplicate.
public struct Turn: Equatable, Sendable {
  public var id: String
  public var agent: Agent
  public var session: String
  public var project: String
  public var model: String
  public var ts: Date
  public var usage: Usage
  /// Cost the agent reported itself (opencode). Wins over the pricing table.
  public var fixedCost: Double?

  public init(
    id: String, agent: Agent, session: String, project: String, model: String, ts: Date, usage: Usage,
    fixedCost: Double? = nil
  ) {
    self.id = id
    self.agent = agent
    self.session = session
    self.project = project
    self.model = model
    self.ts = ts
    self.usage = usage
    self.fixedCost = fixedCost
  }
}

/// What a parser remembers about a file between incremental reads. The session header sits at
/// the top of most logs, so later chunks only make sense with it.
public struct FileState: Codable, Equatable, Sendable {
  public var session: String?
  public var project: String?
  public var model: String?
  public var counter = 0
  public var title: String?

  public init(session: String? = nil, project: String? = nil, model: String? = nil) {
    self.session = session
    self.project = project
    self.model = model
  }
}

// MARK: - JSON helpers

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
  func obj(_ k: String) -> JSON? { self[k] as? JSON }
  func str(_ k: String) -> String? { self[k] as? String }
  func int(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
}

func parseJSON(_ line: Data) -> JSON? {
  (try? JSONSerialization.jsonObject(with: line)) as? JSON
}

private let isoFrac: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ s: String?) -> Date? {
  guard let s else { return nil }
  return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

/// Byte-level substring test, so the multi-megabyte lines that carry no usage are never decoded.
func contains(_ line: Data, _ needle: [UInt8]) -> Bool {
  line.withUnsafeBytes { hay in
    needle.withUnsafeBytes { n in
      memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil
    }
  }
}

// MARK: - Parsers

public protocol LineParser: Sendable {
  var agent: Agent { get }
  /// Feed one complete line; returns the turns it closes.
  func parse(line: Data, state: inout FileState) -> [Turn]
}

/// Claude Code: `~/.claude/projects/<slug>/<session>.jsonl` (+ `<session>/subagents/*.jsonl`).
/// Streamed responses repeat one `message.id` over several lines; the last usage wins.
public struct ClaudeParser: LineParser {
  public let agent = Agent.claude
  public init() {}
  private static let assistant = Array(#""type":"assistant""#.utf8)
  private static let cwd = Array(#""cwd":""#.utf8)
  private static let aiTitle = Array(#""type":"ai-title""#.utf8)

  public func parse(line: Data, state: inout FileState) -> [Turn] {
    let isAssistant = contains(line, Self.assistant)
    let needsCwd = state.project == nil && contains(line, Self.cwd)
    let isTitle = !isAssistant && contains(line, Self.aiTitle)
    guard isAssistant || needsCwd || isTitle, let d = parseJSON(line) else { return [] }
    if isTitle, let t = d.str("aiTitle"), !t.isEmpty { state.title = t }
    // The launch directory names the project; later `cd`s inside the session don't move it.
    if state.project == nil, let cwd = d.str("cwd"), !cwd.isEmpty { state.project = cwd }
    if let sid = d.str("sessionId"), state.session == nil { state.session = sid }
    guard d.str("type") == "assistant", let m = d.obj("message"), let u = m.obj("usage") else { return [] }
    guard let id = m.str("id") ?? d.str("uuid") else { return [] }
    let model = m.str("model") ?? "unknown"
    if model == "<synthetic>" { return [] }
    let usage = Usage(
      input: u.int("input_tokens"),
      output: u.int("output_tokens"),
      cacheWrite: u.int("cache_creation_input_tokens"),
      cacheWrite1h: u.obj("cache_creation")?.int("ephemeral_1h_input_tokens") ?? 0,
      cacheRead: u.int("cache_read_input_tokens")
    )
    return [
      Turn(
        id: "cc:\(id)", agent: .claude, session: state.session ?? "", project: state.project ?? "",
        model: model, ts: parseDate(d.str("timestamp")) ?? Date(), usage: usage)
    ]
  }
}

/// Codex CLI: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Usage arrives as `token_count`
/// events; `input_tokens` includes the cached part.
public struct CodexParser: LineParser {
  public let agent = Agent.codex
  public init() {}

  public func parse(line: Data, state: inout FileState) -> [Turn] {
    guard let d = parseJSON(line) else { return [] }
    let p = d.obj("payload") ?? [:]
    switch d.str("type") {
    case "session_meta":
      state.session = p.str("id") ?? p.str("session_id") ?? state.session
      state.project = p.str("cwd") ?? state.project
    case "turn_context":
      if let m = p.str("model") { state.model = m }
      if state.project == nil, let cwd = p.str("cwd") { state.project = cwd }
    case "event_msg" where p.str("type") == "token_count":
      guard let u = p.obj("info")?.obj("last_token_usage") else { return [] }
      let cached = u.int("cached_input_tokens")
      let input = u.int("input_tokens"), output = u.int("output_tokens")
      let reasoning = u.int("reasoning_output_tokens")
      let ts = d.str("timestamp") ?? ""
      let sid = state.session ?? "codex"
      return [
        Turn(
          id: "cx:\(sid)-\(ts)-\(input)-\(cached)-\(output)-\(reasoning)", agent: .codex, session: sid,
          project: state.project ?? "", model: state.model ?? "gpt-5", ts: parseDate(ts) ?? Date(),
          usage: Usage(input: max(0, input - cached), output: output, cacheRead: cached))
      ]
    default: break
    }
    return []
  }
}

/// Gemini CLI: `~/.gemini/tmp/<hash>/chats/session-*.jsonl` — a metadata record, then messages;
/// only `type: "gemini"` messages carry tokens. `tokens.input` includes the cached part.
public struct GeminiParser: LineParser {
  public let agent = Agent.gemini
  public init() {}

  public func parse(line: Data, state: inout FileState) -> [Turn] {
    guard let d = parseJSON(line) else { return [] }
    if let set = d.obj("$set") {
      if let s = set.str("summary") { state.title = s }
      return []
    }
    if let sid = d.str("sessionId"), d["projectHash"] != nil {
      state.session = sid
      if let dirs = d["directories"] as? [String], let first = dirs.first { state.project = first }
      if let s = d.str("summary") { state.title = s }
      return []
    }
    guard d.str("type") == "gemini", let id = d.str("id") else { return [] }
    let t = d.obj("tokens") ?? [:]
    let cached = t.int("cached")
    if let m = d.str("model") { state.model = m }
    let sid = state.session ?? "gemini"
    return [
      Turn(
        id: "gm:\(sid)-\(id)", agent: .gemini, session: sid, project: state.project ?? "",
        model: state.model ?? "gemini-2.5-pro", ts: parseDate(d.str("timestamp")) ?? Date(),
        usage: Usage(input: max(0, t.int("input") - cached), output: t.int("output") + t.int("tool"), cacheRead: cached))
    ]
  }
}

/// Grok CLI: `~/.grok/sessions/<url-encoded-cwd>/<session>/updates.jsonl` — ACP session/update
/// events; `turn_completed` carries usage. Turns have no id of their own, so they are numbered
/// in file order (the counter survives incremental reads in `FileState`).
public struct GrokParser: LineParser {
  public let agent = Agent.grok
  public init() {}

  public func parse(line: Data, state: inout FileState) -> [Turn] {
    guard let d = parseJSON(line) else { return [] }
    let p = d.obj("params") ?? [:]
    if let sid = p.str("sessionId") { state.session = sid }
    guard let u = p.obj("update") else { return [] }
    if let m = u.obj("_meta")?.str("modelId") { state.model = m }
    guard u.str("sessionUpdate") == "turn_completed" else { return [] }
    let usage = u.obj("usage") ?? [:]
    let cached = usage.int("cachedReadTokens")
    let ts = (d["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
    let sid = state.session ?? "grok"
    defer { state.counter += 1 }
    return [
      Turn(
        id: "gk:\(sid)-t\(state.counter)", agent: .grok, session: sid, project: state.project ?? "",
        model: state.model ?? "grok-4", ts: ts,
        usage: Usage(
          input: max(0, usage.int("inputTokens") - cached), output: usage.int("outputTokens"), cacheRead: cached))
    ]
  }
}

/// opencode keeps one `message.data` JSON per row in `opencode.db`; assistant rows carry tokens
/// and the exact cost opencode charged.
public enum OpencodeMapper {
  public static func turn(session: String, messageId: String, data: Data, project: String, fallback: Date) -> Turn? {
    guard let d = parseJSON(data), (d.str("type") ?? d.str("role")) == "assistant" else { return nil }
    let t = d.obj("tokens") ?? [:]
    let cache = t.obj("cache") ?? [:]
    let model: String =
      d.str("model") ?? d.obj("model")?.str("id") ?? d.str("modelID") ?? "opencode"
    var ts = fallback
    if let created = d.obj("time")?["created"] as? NSNumber {
      ts = Date(timeIntervalSince1970: created.doubleValue / 1000)
    }
    let cost = (d["cost"] as? NSNumber)?.doubleValue
    return Turn(
      id: "oc:\(session)-\(messageId)", agent: .opencode, session: session, project: project, model: model, ts: ts,
      usage: Usage(
        input: t.int("input"), output: t.int("output"), cacheWrite: cache.int("write"), cacheRead: cache.int("read")),
      fixedCost: (cost ?? 0) > 0 ? cost : nil)
  }
}
