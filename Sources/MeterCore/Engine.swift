import Foundation

/// Owns the cache and the scanner on one serial queue; hands finished reports back.
public final class Engine: @unchecked Sendable {
  private let queue = DispatchQueue(label: "agentmeter.engine", qos: .utility)
  private let store: Store
  private let scanner: Scanner
  private let pricingURL: URL
  private let liteLLMFile: URL
  private var watcher: FileWatcher?
  private var prices: (stamp: [Date?], table: [String: Price])?
  private var last: (report: Report, prices: [String: Price])?

  public static var supportDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appending(path: "AgentMeter")
  }

  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, dir: URL = Engine.supportDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    store = try Store(path: dir.appending(path: "meter.db").path)
    scanner = Scanner(home: home, store: store)
    pricingURL = dir.appending(path: "pricing.json")
    liteLLMFile = dir.appending(path: "litellm-prices.json")
  }

  /// Calls `onChange` (on the engine's queue) with a fresh report whenever an agent writes to
  /// its logs. Without FSEvents the caller's periodic full refresh still catches everything.
  public func watch(_ onChange: @escaping @Sendable (Report) -> Void) {
    queue.async { [self] in
      watcher = FileWatcher(paths: scanner.watchPaths, queue: queue) { [weak self] paths in
        guard let self else { return }
        onChange(self.update(changed: paths))
      }
    }
  }

  /// Full scan for new log lines, then a report.
  public func refresh(_ done: @escaping @Sendable (Report) -> Void) {
    queue.async { [self] in done(update(changed: nil)) }
  }

  private func update(changed: [String]?) -> Report {
    do {
      let now = Date()
      let added = scanner.scan(now: now, changed: changed)
      let table = currentPrices()
      // Rebuilding means aggregating a month of turns. Skip it while nothing new arrived, but at
      // least once a minute so "active" and "2m ago" stay true, and at midnight.
      if let last, added == 0, last.prices == table, now.timeIntervalSince(last.report.generated) < 60,
        Calendar.current.isDate(last.report.generated, inSameDayAs: now)
      {
        return last.report
      }
      let since = Calendar.current.date(byAdding: .day, value: -31, to: Calendar.current.startOfDay(for: now))!
      let report = Report.build(from: store.buckets(since: since), prices: table, titles: store.titles(), now: now)
      last = (report, table)
      return report
    }
  }

  /// The merged price table, rebuilt only when one of its files changes.
  private func currentPrices() -> [String: Price] {
    let stamp = [liteLLMFile, pricingURL].map {
      (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    if let prices, prices.stamp == stamp { return prices.table }
    let table = Pricing.load(litellm: liteLLMFile, override: pricingURL)
    prices = (stamp, table)
    return table
  }

  /// When the downloaded price list was fetched, if ever.
  public var pricesUpdated: Date? {
    (try? liteLLMFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }

  /// The only network call the app makes, and only when asked: fetch LiteLLM's public price list.
  /// Returns how many models it priced; the file is kept only if it parses.
  public func updatePrices() async throws -> Int {
    let (data, response) = try await URLSession.shared.data(from: Pricing.liteLLMURL)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let n = Pricing.fromLiteLLM(data).count
    guard n > 0 else { throw URLError(.cannotParseResponse) }
    try data.write(to: liteLLMFile, options: .atomic)
    return n
  }
}
