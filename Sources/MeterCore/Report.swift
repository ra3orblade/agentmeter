import Foundation

public enum Period: String, CaseIterable, Identifiable, Sendable {
  case today, week, month
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .today: "Today"
    case .week: "7 days"
    case .month: "30 days"
    }
  }
  var days: Int {
    switch self {
    case .today: 1
    case .week: 7
    case .month: 30
    }
  }
}

public struct Totals: Equatable, Sendable {
  public var cost = 0.0
  public var tokens = 0
  public var turns = 0
  /// Turns whose model has no price: their tokens count, their cost doesn't.
  public var unpriced = 0
  public init() {}
  init(cost: Double, tokens: Int, turns: Int) {
    self.cost = cost
    self.tokens = tokens
    self.turns = turns
  }
}

public struct Line: Identifiable, Equatable, Sendable {
  public var id: String
  public var agent: Agent?
  public var title: String
  public var totals: Totals
}

public struct DayCost: Identifiable, Equatable, Sendable {
  public var id: String { "\(day)-\(agent.rawValue)" }
  public var day: Date
  public var agent: Agent
  public var cost: Double
}

public struct ActiveSession: Identifiable, Equatable, Sendable {
  public var id: String { "\(agent.rawValue):\(session)" }
  public var agent: Agent
  public var session: String
  public var project: String
  /// The agent's own name for the session (Claude Code's ai-title, Gemini's summary), if any.
  public var title: String?
  public var model: String
  public var last: Date
  public var costToday: Double
}

public struct Report: Equatable, Sendable {
  public var generated: Date
  public var totals: [Period: Totals]
  public var agents: [Period: [Line]]
  public var projects: [Period: [Line]]
  public var daily: [DayCost]  // last 30 days, one entry per day × agent with spend
  public var active: [ActiveSession]

  public static let empty = Report(generated: .distantPast, totals: [:], agents: [:], projects: [:], daily: [], active: [])
}

extension Report {
  /// `activeWithin`: a session counts as active if it billed a turn this recently.
  public static func build(
    from buckets: [Store.Bucket], prices: [String: Price], titles: [String: String] = [:], now: Date = Date(),
    calendar: Calendar = .current, activeWithin: TimeInterval = 15 * 60
  ) -> Report {
    let fmt = DateFormatter()
    fmt.calendar = calendar
    fmt.timeZone = calendar.timeZone
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd"
    let startOfToday = calendar.startOfDay(for: now)
    func dayStart(_ period: Period) -> String {
      fmt.string(from: calendar.date(byAdding: .day, value: 1 - period.days, to: startOfToday)!)
    }
    let todayKey = fmt.string(from: startOfToday)

    var totals: [Period: Totals] = [:]
    var agents: [Period: [Agent: Totals]] = [:]
    var projects: [Period: [String: Totals]] = [:]
    var daily: [String: [Agent: Double]] = [:]
    var sessions: [String: ActiveSession] = [:]

    var priceOf: [String: Price?] = [:]
    for b in buckets {
      let price = priceOf[b.model] ?? { let p = Pricing.price(for: b.model, in: prices); priceOf[b.model] = p; return p }()
      let priced = price.map { Pricing.cost(usage: b.pricedUsage, price: $0) }
      let cost = (priced ?? 0) + b.fixedCost
      var t = Totals(cost: cost, tokens: b.usage.total, turns: b.turns)
      if priced == nil && b.pricedUsage.total > 0 { t.unpriced = b.turns }

      for p in Period.allCases where b.day >= dayStart(p) {
        totals[p, default: Totals()].add(t)
        agents[p, default: [:]][b.agent, default: Totals()].add(t)
        projects[p, default: [:]][repoRoot(b.project), default: Totals()].add(t)
      }
      if b.day >= dayStart(.month), cost > 0 { daily[b.day, default: [:]][b.agent, default: 0] += cost }

      let key = "\(b.agent.rawValue):\(b.session)"
      var s =
        sessions[key]
        ?? ActiveSession(
          agent: b.agent, session: b.session, project: b.project, title: titles[key], model: b.model, last: b.lastTs,
          costToday: 0)
      if b.lastTs > s.last {
        s.last = b.lastTs
        s.model = b.model
      }
      if b.day == todayKey { s.costToday += cost }
      sessions[key] = s
    }

    func lines<K>(_ m: [K: Totals], id: (K) -> String, agent: (K) -> Agent?, title: (K) -> String) -> [Line] {
      m.map { Line(id: id($0.key), agent: agent($0.key), title: title($0.key), totals: $0.value) }
        .sorted { ($0.totals.cost, $0.totals.tokens) > ($1.totals.cost, $1.totals.tokens) }
    }

    return Report(
      generated: now,
      totals: totals,
      agents: agents.mapValues { lines($0, id: \.rawValue, agent: { $0 }, title: \.label) },
      projects: projects.mapValues {
        lines($0, id: { $0 }, agent: { _ in nil }, title: { $0.isEmpty ? "Unknown" : ($0 as NSString).lastPathComponent })
      },
      daily: daily.flatMap { day, byAgent in
        byAgent.map { DayCost(day: fmt.date(from: day) ?? now, agent: $0.key, cost: $0.value) }
      }.sorted { ($0.day, $0.agent.rawValue) < ($1.day, $1.agent.rawValue) },
      active: sessions.values.filter { now.timeIntervalSince($0.last) <= activeWithin }.sorted { ($0.costToday, $0.id) > ($1.costToday, $1.id) }
    )
  }
}

/// Worktrees count toward the repository they belong to.
func repoRoot(_ path: String) -> String {
  for marker in ["/.claude/worktrees/", "/.worktrees/"] {
    if let r = path.range(of: marker) { return String(path[..<r.lowerBound]) }
  }
  return path
}

extension Totals {
  mutating func add(_ o: Totals) {
    cost += o.cost
    tokens += o.tokens
    turns += o.turns
    unpriced += o.unpriced
  }
}
