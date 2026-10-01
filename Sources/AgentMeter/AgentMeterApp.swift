import AppKit
import MeterCore
import SwiftUI

@main
struct AgentMeterApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model = MeterModel()

  init() {
    // macOS adds new status items at the far left of the status area, which on a notched
    // MacBook with a busy menu bar is under the notch: invisible. Start near the clock instead;
    // once the user ⌘-drags it, macOS saves their position over this default.
    UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position Item-0": 300.0])
    if let i = CommandLine.arguments.firstIndex(of: "--iconset"), i + 1 < CommandLine.arguments.count {
      do {
        try Logo.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("iconset: \(error)\n".utf8))
        exit(1)
      }
    }
    Snapshot.runIfRequested(model)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuView(model: model)
    } label: {
      MenuBarLabel(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Menu bar only: no Dock icon, also when run unbundled via `swift run`.
    NSApp.setActivationPolicy(.accessory)
  }
}

struct MenuBarLabel: View {
  let model: MeterModel

  var body: some View {
    let today = model.report.totals[.today]?.cost ?? 0
    // Needle quantised to 5% steps so the image isn't redrawn for every cent.
    let level = (model.gaugeLevel * 20).rounded() / 20
    HStack(spacing: 4) {
      if model.menuBarStyle != .cost {
        if model.overBudget {
          Image(systemName: "exclamationmark.triangle.fill")
        } else {
          Image(nsImage: Logo.menuBarImage(level: level))
        }
      }
      if model.menuBarStyle != .gauge {
        Text(model.loaded ? Fmt.compactUSD(today) : "$…").monospacedDigit()
      }
    }
  }
}

/// `AgentMeter --snapshot out.png [--dark] [--period week] [--budget 50] [--bar]`: renders the
/// dropdown (or, with `--bar`, the three menu bar styles) with live data to a PNG and exits.
/// For README screenshots and for checking the layout without clicking the menu bar.
@MainActor
enum Snapshot {
  static func runIfRequested(_ model: MeterModel) {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
    let out = URL(fileURLWithPath: args[i + 1])
    let dark = args.contains("--dark")
    func value(_ flag: String) -> String? {
      args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    if let p = value("--period").flatMap({ Period(rawValue: $0) }) { model.period = p }
    if let b = value("--budget").flatMap(Double.init) { model.dailyBudget = b }
    let bar = args.contains("--bar")
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
      MainActor.assumeIsolated {
        guard model.loaded else { return }
        timer.invalidate()
        let host = NSHostingView(rootView: Group {
          if bar { MenuBarStrip(model: model) } else { MenuView(model: model).background(.background) }
        })
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
          host.cacheDisplay(in: host.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?.write(to: out)
          exit(0)
        }
      }
    }
  }
}

/// The three menu bar styles side by side on a menu-bar-like strip, for the README.
private struct MenuBarStrip: View {
  let model: MeterModel
  var body: some View {
    let today = model.report.totals[.today]?.cost ?? 0
    let level = (model.gaugeLevel * 20).rounded() / 20
    HStack(spacing: 28) {
      ForEach(MenuBarStyle.allCases) { style in
        VStack(spacing: 6) {
          HStack(spacing: 4) {
            if style != .cost { Image(nsImage: Logo.menuBarImage(level: level)) }
            if style != .gauge { Text(Fmt.compactUSD(today)).monospacedDigit() }
          }
          .font(.system(size: 13, weight: .medium))
          .fixedSize()
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
          Text(style.label).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 14)
    .background(.background)
  }
}
