import Foundation
import MeterCore
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

enum MenuBarStyle: String, CaseIterable, Identifiable {
  case gaugeAndCost, cost, gauge
  var id: String { rawValue }
  var label: String {
    switch self {
    case .gaugeAndCost: "Gauge and cost"
    case .cost: "Cost only"
    case .gauge: "Gauge only"
    }
  }
}

@MainActor
@Observable
final class MeterModel {
  private(set) var report = Report.empty
  private(set) var loaded = false
  private(set) var error: String?

  var period: Period {
    didSet { UserDefaults.standard.set(period.rawValue, forKey: "period") }
  }
  /// Daily spend that triggers one notification per day. 0 = off.
  var dailyBudget: Double {
    didSet { UserDefaults.standard.set(dailyBudget, forKey: "dailyBudget") }
  }

  var menuBarStyle: MenuBarStyle {
    didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
  }

  private(set) var engine: Engine?
  /// Status of the last "Update prices" run, shown in the settings menu.
  private(set) var priceStatus: String?
  private var timer: Timer?

  /// Notifications and login items need a real app bundle; `swift run` has none.
  let bundled = Bundle.main.bundleIdentifier != nil

  init() {
    period = UserDefaults.standard.string(forKey: "period").flatMap(Period.init) ?? .today
    dailyBudget = UserDefaults.standard.double(forKey: "dailyBudget")
    menuBarStyle = UserDefaults.standard.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init) ?? .gaugeAndCost
    do {
      // Overrides exist for tools/screenshots.sh, which renders a synthetic home, never yours.
      let env = ProcessInfo.processInfo.environment
      engine = try Engine(
        home: env["AGENTMETER_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser,
        dir: env["AGENTMETER_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? Engine.supportDir)
    } catch {
      self.error = "Can't open the cache: \(error)"
    }
    refresh()
    // FSEvents drives updates; the timer is the safety net that also finds newly installed
    // agents and keeps "2m ago" honest.
    engine?.watch { [weak self] report in
      Task { @MainActor in self?.apply(report) }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh() {
    engine?.refresh { [weak self] report in
      Task { @MainActor in self?.apply(report) }
    }
  }

  private func apply(_ r: Report) {
    report = r
    loaded = true
    checkBudget()
  }

  func updatePrices() {
    guard let engine else { return }
    priceStatus = "Updating prices…"
    Task {
      do {
        let n = try await engine.updatePrices()
        priceStatus = "Prices updated: \(n) models"
        refresh()
      } catch {
        priceStatus = "Price update failed: \(error.localizedDescription)"
      }
    }
  }

  /// Where the gauge needle points, 0…1. Against the daily budget when one is set (full = budget
  /// reached); otherwise against a typical day, so an average day sits upright in the middle.
  var gaugeLevel: Double {
    let today = report.totals[.today]?.cost ?? 0
    if dailyBudget > 0 { return min(1, today / dailyBudget) }
    let typical = typicalDay
    return typical > 0 ? min(1, today / (2 * typical)) : 0
  }

  /// Mean spend of the last 7 complete days that had any.
  var typicalDay: Double {
    let cal = Calendar.current
    let today = cal.startOfDay(for: report.generated)
    let start = cal.date(byAdding: .day, value: -7, to: today)!
    var byDay: [Date: Double] = [:]
    for d in report.daily where d.day >= start && d.day < today { byDay[d.day, default: 0] += d.cost }
    return byDay.isEmpty ? 0 : byDay.values.reduce(0, +) / Double(byDay.count)
  }

  var overBudget: Bool {
    dailyBudget > 0 && (report.totals[.today]?.cost ?? 0) >= dailyBudget
  }

  private func checkBudget() {
    guard overBudget, bundled else { return }
    let day = Fmt.dayKey(Date())
    guard UserDefaults.standard.string(forKey: "alertedDay") != day else { return }
    UserDefaults.standard.set(day, forKey: "alertedDay")
    let spent = Fmt.usd(report.totals[.today]?.cost ?? 0)
    let budget = Fmt.usd(dailyBudget)
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = "Daily budget reached"
      content.body = "Agents have used \(spent) today (budget \(budget))."
      center.add(UNNotificationRequest(identifier: "budget-\(day)", content: content, trigger: nil))
    }
  }

  // MARK: Launch at login

  /// Stored so the view observes it; re-read from the system after every change.
  var launchAtLogin = Bundle.main.bundleIdentifier != nil && SMAppService.mainApp.status == .enabled {
    didSet {
      guard bundled, launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
      try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}
