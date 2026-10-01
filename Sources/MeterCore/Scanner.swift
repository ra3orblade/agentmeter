import Foundation

/// Finds every agent's logs under a home directory and reads only the bytes appended since the
/// last pass. All file reads are read-only; nothing is ever written next to an agent's data.
public final class Scanner {
  public let home: URL
  let store: Store
  /// Files untouched for longer than this are not indexed on first sight.
  public var horizon: TimeInterval = 90 * 86_400
  private let env: [String: String]

  public init(home: URL, store: Store, env: [String: String] = ProcessInfo.processInfo.environment) {
    self.home = home
    self.store = store
    self.env = env
  }

  struct Root {
    let dir: URL
    let parser: LineParser
    let accept: (URL) -> Bool
    /// Project for a file whose log never names one (grok keeps it in the folder name).
    var project: ((URL) -> String?)? = nil
  }

  var roots: [Root] {
    let codexHome = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".codex")
    let claudeHome = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".claude")
    return [
      Root(dir: claudeHome.appending(path: "projects"), parser: ClaudeParser()) { $0.pathExtension == "jsonl" },
      Root(dir: codexHome.appending(path: "sessions"), parser: CodexParser()) {
        $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
      },
      Root(dir: home.appending(path: ".gemini/tmp"), parser: GeminiParser()) {
        $0.pathExtension == "jsonl" && $0.path.contains("/chats/")
      },
      Root(
        dir: home.appending(path: ".grok/sessions"), parser: GrokParser(),
        accept: { $0.lastPathComponent == "updates.jsonl" },
        project: { $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.removingPercentEncoding }
      ),
    ]
  }

  var opencodeDir: URL {
    let data = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".local/share")
    return data.appending(path: "opencode")
  }

  /// Directories worth watching for changes (whether or not they exist yet).
  public var watchPaths: [String] { roots.map(\.dir.path) + [opencodeDir.path] }

  /// One pass over every source, or only over `changed` file paths when given (from FSEvents).
  /// Returns the number of turns written.
  @discardableResult
  public func scan(now: Date = Date(), changed: [String]? = nil) -> Int {
    var n = 0
    store.transaction {
      let roots = self.roots
      if let changed {
        for path in Set(changed) {
          let url = URL(fileURLWithPath: path)
          if let root = roots.first(where: { path.hasPrefix($0.dir.path + "/") && $0.accept(url) }) {
            n += read(url, root: root, now: now)
          }
        }
        if changed.contains(where: { $0.hasPrefix(opencodeDir.path + "/") }) { n += readOpencode(now: now) }
      } else {
        for root in roots {
          for file in files(in: root.dir, accept: root.accept) {
            n += read(file, root: root, now: now)
          }
        }
        n += readOpencode(now: now)
      }
    }
    return n
  }

  private func files(in dir: URL, accept: (URL) -> Bool) -> [URL] {
    guard
      let e = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { return [] }
    var out: [URL] = []
    for case let url as URL in e where accept(url) { out.append(url) }
    return out
  }

  private func read(_ url: URL, root: Root, now: Date) -> Int {
    let path = url.path
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let size = (attrs[.size] as? NSNumber)?.intValue,
      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
    else { return 0 }

    var src = store.source(path)
    if src == nil && now.timeIntervalSince1970 - mtime > horizon { return 0 }
    if let s = src, s.offset == size, s.mtime == mtime { return 0 }
    if let s = src, s.offset > size { src = nil }  // truncated or rewritten: start over
    var source = src ?? Store.Source(offset: 0, mtime: mtime, state: FileState())
    if source.state.project == nil, let p = root.project?(url) { source.state.project = p }

    guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
    defer { try? fh.close() }
    var n = 0
    var offset = source.offset
    let chunkSize = 8 << 20
    var carry = Data()
    try? fh.seek(toOffset: UInt64(offset))
    while let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty {
      var buf = carry
      buf.append(chunk)
      var turns: [Turn] = []
      let consumed = Self.forEachLine(in: buf) { line in
        turns += root.parser.parse(line: line, state: &source.state)
      }
      offset += consumed - carry.count
      carry = buf.subdata(in: consumed..<buf.count)
      store.insert(turns)
      n += turns.count
    }
    // A trailing partial line stays unread until its newline lands.
    source.offset = offset
    source.mtime = mtime
    store.save(path, source)
    if let title = source.state.title, let session = source.state.session {
      store.setTitle(title, agent: root.parser.agent, session: session)
    }
    return n
  }

  /// Calls `body` with each newline-terminated, non-empty line of a zero-based `buf`; returns the
  /// byte count consumed (everything up to and including the last newline).
  static func forEachLine(in buf: Data, _ body: (Data) -> Void) -> Int {
    var ranges: [Range<Int>] = []
    let consumed: Int = buf.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return 0 }
      var start = 0
      while start < raw.count, let p = memchr(base + start, 0x0A, raw.count - start) {
        let nl = base.distance(to: p)
        if nl > start { ranges.append(start..<nl) }
        start = nl + 1
      }
      return start
    }
    for r in ranges { body(buf.subdata(in: r)) }
    return consumed
  }

  /// opencode keeps sessions in SQLite (WAL, safe to read while it writes). The cursor is the
  /// highest `time_updated` (ms) seen, stored in the source's offset.
  private func readOpencode(now: Date) -> Int {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: opencodeDir.path) else { return 0 }
    var n = 0
    for name in names where name.hasPrefix("opencode") && name.hasSuffix(".db") {
      let path = opencodeDir.appending(path: name).path
      guard let db = try? SQLite(path: path, readOnly: true) else { continue }
      var source = store.source(path) ?? Store.Source(offset: 0, mtime: 0, state: FileState())
      let floor = max(source.offset, Int((now.timeIntervalSince1970 - horizon) * 1000))
      guard
        let stmt = try? db.prepare(
          """
          SELECT m.id, m.session_id, m.time_created, m.time_updated, m.data, s.directory
          FROM message m JOIN session s ON s.id = m.session_id
          WHERE m.time_updated > ? ORDER BY m.time_updated ASC
          """)
      else { continue }  // a schema we don't know: skip rather than guess
      var turns: [Turn] = []
      var cursor = floor
      stmt.query([floor]) { r in
        cursor = max(cursor, r.int(3))
        guard let id = r.string(0), let sid = r.string(1), let data = r.data(4) ?? r.string(4).map({ Data($0.utf8) })
        else { return }
        let fallback = Date(timeIntervalSince1970: Double(r.int(2)) / 1000)
        if let t = OpencodeMapper.turn(session: sid, messageId: id, data: data, project: r.string(5) ?? "", fallback: fallback) {
          turns.append(t)
        }
      }
      store.insert(turns)
      n += turns.count
      source.offset = cursor
      store.save(path, source)
    }
    return n
  }
}
