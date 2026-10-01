import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Not thread-safe: the engine owns it on one serial queue.
final class SQLite {
  private(set) var db: OpaquePointer?

  init(path: String, readOnly: Bool = false) throws {
    let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
      let msg = String(cString: sqlite3_errmsg(db))
      sqlite3_close(db)
      throw StoreError.open(msg)
    }
    sqlite3_busy_timeout(db, 2000)
  }

  deinit { sqlite3_close(db) }

  func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
    }
  }

  func prepare(_ sql: String) throws -> Statement {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
    }
    return Statement(stmt)
  }
}

enum StoreError: Error { case open(String), sql(String) }

final class Statement {
  let stmt: OpaquePointer
  init(_ stmt: OpaquePointer) { self.stmt = stmt }
  deinit { sqlite3_finalize(stmt) }

  func bind(_ values: [Any?]) {
    sqlite3_reset(stmt)
    sqlite3_clear_bindings(stmt)
    for (i, v) in values.enumerated() {
      let idx = Int32(i + 1)
      switch v {
      case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
      case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
      case let d as Double: sqlite3_bind_double(stmt, idx, d)
      default: sqlite3_bind_null(stmt, idx)
      }
    }
  }

  func run(_ values: [Any?] = []) {
    bind(values)
    sqlite3_step(stmt)
  }

  /// Steps through all rows, handing each to `row`.
  func query(_ values: [Any?] = [], _ row: (Row) -> Void) {
    bind(values)
    while sqlite3_step(stmt) == SQLITE_ROW { row(Row(stmt: stmt)) }
  }
}

struct Row {
  let stmt: OpaquePointer
  func string(_ i: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, i) else { return nil }
    return String(cString: c)
  }
  func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
  func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
  func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
  func data(_ i: Int32) -> Data? {
    guard let p = sqlite3_column_blob(stmt, i) else { return nil }
    return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
  }
}

/// The meter's own cache: every turn seen, plus how far into each source it has read.
public final class Store {
  static let schemaVersion = 2
  let sql: SQLite
  private let upsertTurn: Statement
  private let upsertFile: Statement
  private let upsertTitle: Statement

  public init(path: String) throws {
    sql = try SQLite(path: path)
    // The cache is derived data: when its shape changes, rebuild it from the logs.
    var version = 0
    try sql.prepare("PRAGMA user_version").query { version = $0.int(0) }
    if version != Store.schemaVersion {
      try sql.exec("DROP TABLE IF EXISTS turns; DROP TABLE IF EXISTS sources; DROP TABLE IF EXISTS sessions;")
      try sql.exec("PRAGMA user_version = \(Store.schemaVersion)")
    }
    try sql.exec(
      """
      PRAGMA journal_mode = WAL;
      PRAGMA cache_size = -16000;
      CREATE TABLE IF NOT EXISTS turns (
        id TEXT PRIMARY KEY, agent TEXT NOT NULL, session TEXT NOT NULL, project TEXT NOT NULL,
        model TEXT NOT NULL, ts REAL NOT NULL,
        input INTEGER NOT NULL, output INTEGER NOT NULL, cw INTEGER NOT NULL, cw1h INTEGER NOT NULL,
        cr INTEGER NOT NULL, fixed_cost REAL
      );
      CREATE INDEX IF NOT EXISTS turns_ts ON turns(ts);
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY, title TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sources (
        path TEXT PRIMARY KEY, offset INTEGER NOT NULL, mtime REAL NOT NULL, state TEXT
      );
      """)
    upsertTurn = try sql.prepare(
      "INSERT OR REPLACE INTO turns VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
    upsertFile = try sql.prepare("INSERT OR REPLACE INTO sources VALUES (?,?,?,?)")
    upsertTitle = try sql.prepare("INSERT OR REPLACE INTO sessions VALUES (?, ?)")
  }

  public struct Source: Equatable {
    public var offset: Int
    public var mtime: Double
    public var state: FileState
  }

  /// Every source's cursor, loaded once: the scanner asks for each file on every pass.
  private lazy var sources: [String: Source] = {
    var out: [String: Source] = [:]
    try? sql.prepare("SELECT path, offset, mtime, state FROM sources").query { r in
      guard let path = r.string(0) else { return }
      let state = r.string(3).flatMap { try? JSONDecoder().decode(FileState.self, from: Data($0.utf8)) }
      out[path] = Source(offset: r.int(1), mtime: r.double(2), state: state ?? FileState())
    }
    return out
  }()

  public func source(_ path: String) -> Source? { sources[path] }

  public func save(_ path: String, _ s: Source) {
    guard sources[path] != s else { return }
    sources[path] = s
    let state = (try? JSONEncoder().encode(s.state)).map { String(decoding: $0, as: UTF8.self) }
    upsertFile.run([path, s.offset, s.mtime, state])
  }

  /// Session titles keyed "<agent>:<session>", as `Report` looks them up.
  public func setTitle(_ title: String, agent: Agent, session: String) {
    upsertTitle.run(["\(agent.rawValue):\(session)", title])
  }

  public func titles() -> [String: String] {
    var out: [String: String] = [:]
    try? sql.prepare("SELECT id, title FROM sessions").query { r in
      if let id = r.string(0), let t = r.string(1) { out[id] = t }
    }
    return out
  }

  public func insert(_ turns: [Turn]) {
    for t in turns {
      let u = t.usage
      upsertTurn.run([
        t.id, t.agent.rawValue, t.session, t.project, t.model, t.ts.timeIntervalSince1970,
        u.input, u.output, u.cacheWrite, u.cacheWrite1h, u.cacheRead, t.fixedCost,
      ])
    }
  }

  public func transaction(_ body: () -> Void) {
    try? sql.exec("BEGIN")
    body()
    try? sql.exec("COMMIT")
  }

  /// Token sums grouped by (local day, agent, model, session) since `since`. Turns with a fixed
  /// cost are summed apart so they are never repriced.
  public struct Bucket: Sendable {
    public var day: String
    public var agent: Agent
    public var model: String
    public var session: String
    public var project: String
    public var lastTs: Date
    public var turns: Int
    public var usage: Usage  // all tokens, for display
    public var pricedUsage: Usage  // tokens of turns without a fixed cost
    public var fixedCost: Double
  }

  public func buckets(since: Date) -> [Bucket] {
    guard
      let stmt = try? sql.prepare(
        """
        SELECT date(ts, 'unixepoch', 'localtime') AS day, agent, model, session, MAX(project), MAX(ts), COUNT(*),
          SUM(input), SUM(output), SUM(cw), SUM(cw1h), SUM(cr),
          SUM(CASE WHEN fixed_cost IS NULL THEN input ELSE 0 END),
          SUM(CASE WHEN fixed_cost IS NULL THEN output ELSE 0 END),
          SUM(CASE WHEN fixed_cost IS NULL THEN cw ELSE 0 END),
          SUM(CASE WHEN fixed_cost IS NULL THEN cw1h ELSE 0 END),
          SUM(CASE WHEN fixed_cost IS NULL THEN cr ELSE 0 END),
          COALESCE(SUM(fixed_cost), 0)
        FROM turns WHERE ts >= ? GROUP BY day, agent, model, session
        """)
    else { return [] }
    var out: [Bucket] = []
    stmt.query([since.timeIntervalSince1970]) { r in
      guard let day = r.string(0), let agent = Agent(rawValue: r.string(1) ?? "") else { return }
      out.append(
        Bucket(
          day: day, agent: agent, model: r.string(2) ?? "", session: r.string(3) ?? "",
          project: r.string(4) ?? "", lastTs: Date(timeIntervalSince1970: r.double(5)), turns: r.int(6),
          usage: Usage(input: r.int(7), output: r.int(8), cacheWrite: r.int(9), cacheWrite1h: r.int(10), cacheRead: r.int(11)),
          pricedUsage: Usage(
            input: r.int(12), output: r.int(13), cacheWrite: r.int(14), cacheWrite1h: r.int(15), cacheRead: r.int(16)),
          fixedCost: r.double(17)))
    }
    return out
  }
}
