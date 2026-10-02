import Foundation
import Sparkle

/// Sparkle self-updates from the appcast attached to the latest GitHub release (`SUFeedURL` in
/// Info.plist). Only in the bundled app: `swift run` has no Info.plist with a feed or key.
/// Sparkle asks on the second launch before it checks on its own; until then it's manual only.
@MainActor
final class Updater {
  private let controller: SPUStandardUpdaterController?

  init() {
    controller = Bundle.main.bundleIdentifier == nil ? nil
      : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }

  var available: Bool { controller != nil }

  var checksAutomatically: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set { controller?.updater.automaticallyChecksForUpdates = newValue }
  }

  func checkForUpdates() { controller?.checkForUpdates(nil) }
}
