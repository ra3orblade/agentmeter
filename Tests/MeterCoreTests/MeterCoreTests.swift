import Foundation
import Testing

@testable import MeterCore

private func lines(_ s: String) -> [Data] { s.split(separator: "\n").map { Data($0.utf8) } }

private func feed(_ p: LineParser, _ s: String, state: inout FileState) -> [Turn] {
  lines(s).flatMap { p.parse(line: $0, state: &state) }
}

@Suite struct PricingTests {
  @Test func longestPrefixWins() {
    let t = Pricing.builtIn
    #expect(Pricing.price(for: "claude-fable-5-1", in: t)?.cacheRead == 0.25)
    #expect(Pricing.price(for: "claude-fable-5-2", in: t)?.cacheRead == 1)
    #expect(Pricing.price(for: "claude-haiku-4-5-20251001", in: t)?.input == 1)
    #expect(Pricing.price(for: "mystery-model", in: t) == nil)
  }

  @Test func oneHourCacheWritesPricedApart() {
    let u = Usage(input: 1_000_000, output: 0, cacheWrite: 2_000_000, cacheWrite1h: 1_000_000, cacheRead: 0)
    // 1M input @5 + 1M 5m-write @6.25 + 1M 1h-write @10
    #expect(Pricing.cost(model: "claude-opus-5", usage: u, table: Pricing.builtIn) == 21.25)
  }
}

@Suite struct ParserTests {
  @Test func claudeStreamedLinesShareAnIdAndProjectIsLaunchDir() {
    var st = FileState()
    let turns = feed(
      ClaudeParser(),
      """
      {"type":"user","cwd":"/repo","sessionId":"s1","timestamp":"2026-10-01T10:00:00.000Z"}
      {"type":"assistant","cwd":"/repo/sub","timestamp":"2026-10-01T10:00:01.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}}}
      {"type":"assistant","timestamp":"2026-10-01T10:00:02.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":50,"cache_read_input_tokens":900,"cache_creation_input_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":10}}}}
      {"type":"assistant","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
      """, state: &st)
    #expect(turns.count == 2)
    #expect(Set(turns.map(\.id)) == ["cc:m1"])
    #expect(turns.last?.usage == Usage(input: 1, output: 50, cacheWrite: 10, cacheWrite1h: 10, cacheRead: 900))
    #expect(turns.last?.project == "/repo")
    #expect(turns.last?.session == "s1")
  }

  @Test func claudeAcceptsSpacedJSON() {
    var st = FileState()
    let turns = feed(
      ClaudeParser(),
      #"{"type": "assistant", "cwd": "/r", "timestamp": "2026-10-01T10:00:00.123456Z", "message": {"id": "m", "model": "claude-opus-5", "usage": {"output_tokens": 3}}}"#,
      state: &st)
    #expect(turns.count == 1)
    #expect(turns.first?.ts == parseDate("2026-10-01T10:00:00.123Z"))
  }

  @Test func datesWithAnyFraction() {
    let base = parseDate("2026-10-01T10:00:00Z")!
    #expect(parseDate("2026-10-01T10:00:00.5Z") == base.addingTimeInterval(0.5))
    #expect(parseDate("2026-10-01T10:00:00.250000+00:00") == base.addingTimeInterval(0.25))
    #expect(parseDate("nonsense") == nil)
  }

  @Test func codexSubtractsCachedInput() {
    var st = FileState()
    let turns = feed(
      CodexParser(),
      """
      {"type":"session_meta","payload":{"id":"cx1","cwd":"/proj"}}
      {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
      {"timestamp":"2026-10-01T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":20,"reasoning_output_tokens":5}}}}
      {"type":"event_msg","payload":{"type":"token_count","info":null}}
      """, state: &st)
    #expect(turns.count == 1)
    #expect(turns[0].usage == Usage(input: 200, output: 20, cacheRead: 800))
    #expect(turns[0].model == "gpt-5-codex")
    #expect(turns[0].project == "/proj")
  }

  @Test func geminiCountsOnlyModelMessages() {
    var st = FileState()
    let turns = feed(
      GeminiParser(),
      """
      {"sessionId":"g1","projectHash":"abc","directories":["/gproj"]}
      {"id":"u1","type":"user","content":"hi"}
      {"id":"a1","type":"gemini","model":"gemini-2.5-pro","timestamp":"2026-10-01T10:00:00Z","tokens":{"input":1200,"output":80,"cached":1000,"tool":6}}
      {"$set":{"summary":"x"}}
      """, state: &st)
    #expect(turns.map(\.id) == ["gm:g1-a1"])
    #expect(turns[0].usage == Usage(input: 200, output: 86, cacheRead: 1000))
    #expect(turns[0].project == "/gproj")
  }

  @Test func grokNumbersTurnsAcrossChunks() {
    let p = GrokParser()
    var st = FileState()
    let a = feed(
      p,
      """
      {"timestamp":1790000000,"params":{"sessionId":"k1","update":{"sessionUpdate":"user_message_chunk","_meta":{"modelId":"grok-code-fast-1"}}}}
      {"timestamp":1790000001,"params":{"sessionId":"k1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100,"outputTokens":5,"cachedReadTokens":60}}}}
      """, state: &st)
    let b = feed(
      p, #"{"params":{"sessionId":"k1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":10}}}}"#,
      state: &st)
    #expect(a.map(\.id) + b.map(\.id) == ["gk:k1-t0", "gk:k1-t1"])
    #expect(a[0].usage == Usage(input: 40, output: 5, cacheRead: 60))
    #expect(a[0].model == "grok-code-fast-1")
  }

  @Test func opencodeCarriesItsOwnCost() {
    let data = Data(
      #"{"role":"assistant","modelID":"claude-sonnet-5","cost":0.42,"tokens":{"input":3,"output":4,"cache":{"read":5,"write":6}},"time":{"created":1790000000000}}"#
        .utf8)
    let t = OpencodeMapper.turn(session: "o1", messageId: "m1", data: data, project: "/p", fallback: .distantPast)
    #expect(t?.fixedCost == 0.42)
    #expect(t?.usage == Usage(input: 3, output: 4, cacheWrite: 6, cacheRead: 5))
    #expect(OpencodeMapper.turn(session: "o1", messageId: "m2", data: Data(#"{"role":"user"}"#.utf8), project: "", fallback: .now) == nil)
  }
}

@Suite struct ScannerTests {
  @Test func readsOnlyAppendedCompleteLines() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "meter-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appending(path: ".claude/projects/-repo")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "s.jsonl")
    let store = try Store(path: home.appending(path: "meter.db").path)
    let scanner = Scanner(home: home, store: store, env: [:])

    func line(_ id: String) -> String {
      #"{"type":"assistant","cwd":"/repo","timestamp":"2026-10-01T10:00:00Z","message":{"id":"\#(id)","model":"claude-opus-5","usage":{"input_tokens":1000000}}}"#
    }
    // second line has no newline yet: it must wait
    try (line("a") + "\n" + line("b")).write(to: file, atomically: false, encoding: .utf8)
    #expect(scanner.scan() == 1)
    let h = try FileHandle(forWritingTo: file)
    h.seekToEndOfFile()
    h.write(Data(("\n" + line("c") + "\n").utf8))
    try h.close()
    #expect(scanner.scan() == 2)
    #expect(scanner.scan() == 0)

    let buckets = store.buckets(since: .distantPast)
    #expect(buckets.reduce(0) { $0 + $1.turns } == 3)
    let report = Report.build(
      from: buckets, prices: Pricing.builtIn, now: parseDate("2026-10-01T12:00:00Z")!, activeWithin: 0)
    #expect(report.totals[.month]?.cost == 15)  // 3 × 1M input @ $5
    #expect(report.projects[.month]?.first?.title == "repo")
  }

  @Test func worktreesFoldIntoTheirRepo() {
    #expect(repoRoot("/r/swarm/.claude/worktrees/m12-7") == "/r/swarm")
    #expect(repoRoot("/r/app") == "/r/app")
  }
}
