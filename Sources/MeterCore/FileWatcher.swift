import CoreServices
import Foundation

/// FSEvents on a set of directories, reporting changed file paths in batches. Events are
/// coalesced by the system over `latency` seconds, so a busy session costs one callback per
/// batch, not one per line written.
public final class FileWatcher {
  private var stream: FSEventStreamRef?
  private let handler: ([String]) -> Void

  public init?(paths: [String], latency: TimeInterval = 1.0, queue: DispatchQueue, handler: @escaping ([String]) -> Void) {
    let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
    guard !existing.isEmpty else { return nil }
    self.handler = handler
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
      let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      watcher.handler(Array(array.prefix(count)))
    }
    let flags = UInt32(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }
}
