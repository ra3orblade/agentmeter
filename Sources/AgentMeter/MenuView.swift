import AppKit
import Charts
import MeterCore
import SwiftUI

extension Agent {
  var color: Color {
    switch self {
    case .claude: .orange
    case .codex: .teal
    case .gemini: .blue
    case .grok: .gray
    case .opencode: .purple
    }
  }
}

struct MenuView: View {
  @Bindable var model: MeterModel
  var updater: Updater?
  @State private var hoveredDay: Date?

  private var r: Report { model.report }
  private var totals: Totals { r.totals[model.period] ?? Totals() }
  private var agentLines: [Line] { r.agents[model.period] ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let error = model.error {
        Card { Text(error).font(.callout).foregroundStyle(.red) }
      } else if model.loaded && totals.turns == 0 {
        Card {
          Text("No agent activity \(model.period == .today ? "today" : "in the last \(model.period.label)").")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        agents
        projects
      }
      if !r.active.isEmpty { active }
      if !r.daily.isEmpty { history }
      footer
    }
    .padding(14)
    .frame(width: 340)
  }

  // MARK: Sections

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center) {
        Picker("Period", selection: $model.period) {
          ForEach(Period.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        Spacer()
        if !model.loaded { ProgressView().controlSize(.mini) }
      }
      HStack(alignment: .firstTextBaseline) {
        Text(Fmt.usd(totals.cost))
          .font(.system(size: 30, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText())
        Spacer()
        if let (label, value) = previousPeriod {
          Text("\(label) \(Fmt.usd(value))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      ShareBar(lines: agentLines, budget: model.period == .today ? model.dailyBudget : 0)
      HStack {
        Text("\(Fmt.tokens(totals.tokens)) tokens · \(totals.turns.formatted()) turns")
        Spacer()
        if model.period == .today, model.dailyBudget > 0 {
          Text("\(Int((totals.cost / model.dailyBudget * 100).rounded()))% of \(Fmt.usd(model.dailyBudget)) budget")
            .foregroundStyle(model.overBudget ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        } else {
          Text("API list prices")
        }
      }
      .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      if totals.unpriced > 0 {
        Label("\(totals.unpriced) turns from models with no known price", systemImage: "questionmark.circle")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }

  /// The same span just before this one, for context (a whole day against a partial one is
  /// still the useful comparison: "am I past yesterday yet?").
  private var previousPeriod: (String, Double)? {
    let cal = Calendar.current
    let today = cal.startOfDay(for: r.generated)
    func sum(from: Int, to: Int) -> Double {
      let lo = cal.date(byAdding: .day, value: from, to: today)!, hi = cal.date(byAdding: .day, value: to, to: today)!
      return r.daily.filter { $0.day >= lo && $0.day < hi }.reduce(0) { $0 + $1.cost }
    }
    switch model.period {
    case .today: return ("Yesterday", sum(from: -1, to: 0))
    case .week: return ("Previous 7 days", sum(from: -13, to: -6))
    case .month: return nil
    }
  }

  private var agents: some View {
    Section("By agent") {
      ForEach(agentLines) { line in
        Row {
          Circle().fill(line.agent?.color ?? .secondary).frame(width: 8, height: 8)
          Text(line.title)
          Spacer(minLength: 8)
          if totals.cost > 0 {
            Text(Fmt.percent(line.totals.cost / totals.cost)).foregroundStyle(.secondary)
          }
          Text(Fmt.usd(line.totals.cost)).frame(minWidth: 64, alignment: .trailing)
        }
        .help("\(Fmt.tokens(line.totals.tokens)) tokens · \(line.totals.turns) turns")
      }
    }
  }

  private var projects: some View {
    let lines = Array((r.projects[model.period] ?? []).prefix(5))
    let top = lines.first?.totals.cost ?? 0
    return Section("By project") {
      ForEach(lines) { line in
        Row {
          Text(line.title).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
          Capsule()
            .fill(.tertiary)
            .frame(width: top > 0 ? max(2, 48 * line.totals.cost / top) : 0, height: 4)
            .frame(width: 48, alignment: .trailing)
          Text(Fmt.usd(line.totals.cost)).frame(minWidth: 64, alignment: .trailing)
        }
        .help(line.id)
      }
    }
  }

  private var active: some View {
    Section("Active now", trailing: r.active.count > 5 ? "\(r.active.count) sessions" : nil) {
      ForEach(r.active.prefix(5)) { s in
        let project = s.project.isEmpty ? s.agent.label : (s.project as NSString).lastPathComponent
        Row {
          Circle().fill(s.agent.color).frame(width: 8, height: 8)
          VStack(alignment: .leading, spacing: 1) {
            Text(s.title ?? project).lineLimit(1)
            Text(
              [s.title == nil ? nil : project, Fmt.model(s.model), Fmt.ago(s.last, now: r.generated)]
                .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 8)
          Text(Fmt.usd(s.costToday)).frame(minWidth: 64, alignment: .trailing)
        }
        .help(s.project)
      }
      if r.active.count > 5 {
        Text("+\(r.active.count - 5) more, \(Fmt.usd(r.active.dropFirst(5).reduce(0) { $0 + $1.costToday })) today")
          .font(.caption).foregroundStyle(.secondary)
          .padding(.leading, 16)
      }
    }
  }

  private var history: some View {
    let cal = Calendar.current
    let hovered = hoveredDay.map { cal.startOfDay(for: $0) }
    let today = cal.startOfDay(for: r.generated)
    let focus = hovered ?? today
    let focusCost = r.daily.filter { $0.day == focus }.reduce(0) { $0 + $1.cost }
    return Section("Last 30 days", trailing: "\(focus == today ? "Today" : focus.formatted(.dateTime.month(.abbreviated).day())) \(Fmt.usd(focusCost))") {
      Chart(r.daily) { d in
        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Cost", d.cost))
          .foregroundStyle(by: .value("Agent", d.agent.label))
          .cornerRadius(2)
          .opacity(hovered == nil || d.day == hovered ? 1 : 0.35)
      }
      .chartForegroundStyleScale(domain: Agent.allCases.map(\.label), range: Agent.allCases.map(\.color))
      .chartLegend(.hidden)
      .chartXSelection(value: $hoveredDay)
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
          AxisValueLabel(format: .dateTime.month(.abbreviated).day(), collisionResolution: .greedy)
        }
      }
      .chartYAxis {
        AxisMarks(values: .automatic(desiredCount: 3)) { v in
          AxisGridLine().foregroundStyle(.quaternary)
          AxisValueLabel { if let n = v.as(Double.self) { Text(Fmt.axisUSD(n)) } }
        }
      }
      .frame(height: 96)
      .padding(.vertical, 2)
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Group {
        if model.loaded {
          Text("Updated \(Fmt.ago(r.generated, now: Date()))")
        } else {
          Text("Indexing agent logs…")
        }
      }
      .font(.caption).foregroundStyle(.tertiary)
      Spacer()
      Menu {
        Picker("Menu bar shows", selection: $model.menuBarStyle) {
          ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
        }
        Picker("Daily budget alert", selection: $model.dailyBudget) {
          Text("Off").tag(0.0)
          ForEach([10.0, 25, 50, 100, 200, 500], id: \.self) { Text(Fmt.usd($0)).tag($0) }
        }
        Toggle("Launch at login", isOn: $model.launchAtLogin).disabled(!model.bundled)
        Divider()
        Section(pricesCaption) {
          Button("Update prices from LiteLLM") { model.updatePrices() }
          Button("Edit price overrides…") { openPricing() }
        }
        if let updater, updater.available {
          Button("Check for Updates…") { updater.checkForUpdates() }
          Toggle("Check for updates automatically", isOn: Binding(
            get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 }))
        }
        Button("Show cache in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([Engine.supportDir.appending(path: "meter.db")])
        }
        Divider()
        Button("Quit Agent Meter") { NSApp.terminate(nil) }.keyboardShortcut("q")
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Settings")
    }
    .padding(.horizontal, 2)
  }

  private var pricesCaption: String {
    if let status = model.priceStatus { return status }
    if let d = model.engine?.pricesUpdated { return "Prices from \(d.formatted(date: .abbreviated, time: .omitted))" }
    return "Prices from \(Pricing.snapshotDate)"
  }

  /// Overrides win over every other price source. Seeded with one entry no model matches, as a
  /// template: a full copy of the table here would pin every price forever.
  private func openPricing() {
    let url = Engine.supportDir.appending(path: "pricing.json")
    if !FileManager.default.fileExists(atPath: url.path) {
      let template = #"""
        {
          "example-model-id-prefix": { "input": 1.0, "output": 2.0, "cacheWrite": 1.25, "cacheRead": 0.1 }
        }

        """#
      try? template.write(to: url, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(url)
  }
}

/// A titled group: caption above, content on a quiet rounded card.
private struct Section<Content: View>: View {
  let title: String
  var trailing: String?
  @ViewBuilder let content: Content

  init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.trailing = trailing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
      }
      .padding(.horizontal, 4)
      Card { VStack(alignment: .leading, spacing: 7) { content } }
    }
  }
}

private struct Card<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    content
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}

private struct Row<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    HStack(spacing: 8) { content }
      .font(.callout)
      .monospacedDigit()
  }
}

/// Each agent's share of the period as one segmented bar. With a daily budget, the track is the
/// budget, so the filled part reads as "how much of today's allowance is gone".
private struct ShareBar: View {
  let lines: [Line]
  let budget: Double

  var body: some View {
    let total = lines.reduce(0) { $0 + $1.totals.cost }
    let scale = max(total, budget)
    GeometryReader { g in
      HStack(spacing: 1.5) {
        ForEach(lines.filter { $0.totals.cost > 0 }) { line in
          Rectangle()
            .fill(line.agent?.color ?? .secondary)
            .frame(width: scale > 0 ? max(2, g.size.width * line.totals.cost / scale - 1.5) : 0)
        }
      }
      .frame(width: g.size.width, alignment: .leading)
      .background(.quaternary)
      .clipShape(Capsule())
    }
    .frame(height: 6)
  }
}
