import AppKit
import Charts
import EpochControlKit
import SwiftUI

// Look: dark cards with big numbers and small uppercase labels, monospaced type, one corner
// radius everywhere (Theme.radius). Liquid Glass on macOS 26 and later, materials before
// (PRD APP24). Selection moves with a spring; the details swap with a blur-fade; numbers
// roll (PRD APP25). Reduce Motion turns the movement into plain fades.

/// One curve for content and window size, so they move as one (popover resize).
enum Motion {
    static let resizeDuration: Double = 0.28
    static let resize = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: resizeDuration) // CSS "ease"
}

enum Theme {
    static let radius: CGFloat = 12      // cards, rows, tiles, buttons: the same everywhere
    static let badgeRadius: CGFloat = 6
    static let gap: CGFloat = 10
    static let green = Color(red: 0.33, green: 0.84, blue: 0.45)
    static let amber = Color(red: 0.98, green: 0.76, blue: 0.20)
    static let red = Color(red: 0.94, green: 0.33, blue: 0.31)
    static let violet = Color(red: 0.76, green: 0.40, blue: 0.95)
}

struct PopoverView: View {
    let store: RunStore
    @State private var confirmStop = false
    @State private var runsExpanded = true
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Header(store: store)
            if store.runs.isEmpty {
                EmptyState()
            } else {
                RunsCard(store: store, expanded: $runsExpanded, namespace: selection, animation: animation)
                if let run = store.selected {
                    Group {
                        Tiles(run: run)
                        LossCard(points: store.metrics[run.id] ?? [], best: run.status?.best)
                    }
                    .id(run.id) // a new run swaps the details
                    .transition(reduceMotion ? AnyTransition.opacity
                                : AnyTransition(.blurReplace).combined(with: .scale(scale: 0.98)))
                    if let error = store.lastError {
                        Text(error).font(.caption).foregroundStyle(Theme.red)
                    }
                    FooterBar(run: run, store: store, confirmStop: $confirmStop)
                } else {
                    FooterBar(run: nil, store: store, confirmStop: $confirmStop)
                }
            }
            if store.runs.isEmpty { FooterBar(run: nil, store: store, confirmStop: $confirmStop) }
        }
        .fontDesign(.monospaced)
        .padding(14)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        // Report the final height at once: the popover then resizes with the same curve as
        // the content (AppDelegate), so the window and the content move together.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { store.contentHeight = $0 }
        .focusEffectDisabled() // no keyboard-focus ring on the first button
        .animation(animation, value: store.selectedID)
        .onAppear { store.markSeen() }
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)
    }
}

// MARK: - Header

struct Header: View {
    let store: RunStore

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.green.opacity(0.9), .teal],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "chart.line.downtrend.xyaxis").font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("EpochControl").font(.title3.weight(.bold))
                Text("> training monitor").font(.callout).foregroundStyle(Theme.green)
            }
            Spacer()
            let live = store.live.count
            Badge(text: live == 0 ? "IDLE" : "\(live) RUNNING", color: live == 0 ? .secondary : Theme.green,
                  dot: live > 0, large: true)
        }
    }
}

// MARK: - Runs

struct RunsCard: View {
    let store: RunStore
    @Binding var expanded: Bool
    let namespace: Namespace.ID
    let animation: Animation
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.resize) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(store.shown.prefix(6)) { run in
                            RoundedRectangle(cornerRadius: 2).fill(stateColor(run.state)).frame(width: 9, height: 9)
                        }
                    }
                    Text("Runs").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(summary).font(.callout).foregroundStyle(Theme.green)
            // The rows stay in place; only the list's height animates between 0 and its
            // measured height. Inserting and removing them made the glass lay out twice,
            // which showed as a jerk after expanding.
            GlassGroup(spacing: 4) {
                VStack(spacing: 2) {
                    ForEach(store.shown) { run in
                        RunRow(run: run, selected: run.id == store.selectedID, namespace: namespace) {
                            withAnimation(animation) { store.selectedID = run.id }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            .frame(height: expanded ? (listHeight > 0 ? listHeight : nil) : 0, alignment: .top)
            .opacity(expanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(expanded)
        }
        .padding(12)
        .card()
        .clipped()
    }

    private var summary: String {
        let live = store.live.count
        let paused = store.live.filter { $0.state == .paused }.count
        if live == 0 { return "nothing training" }
        return paused > 0 ? "\(live) training · \(paused) paused" : "\(live) training"
    }
}

struct RunRow: View {
    let run: RunInfo
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(stateColor(run.state)).frame(width: 8, height: 8).padding(.top, 5)
                    .shadow(color: run.state.isLive ? stateColor(run.state).opacity(0.7) : .clear, radius: 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(run.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Badge(text: run.state.rawValue.uppercased(), color: stateColor(run.state))
                    }
                    Text(progressText(run) + (run.total != nil ? " epochs" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                Text(duration(run.status?.timing?.active_s ?? 0))
                    .font(.caption).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
            .selectionHighlight(selected, in: namespace)
        }
        .buttonStyle(.plain)
        .animation(.default, value: run.epoch)
    }
}

// MARK: - Tiles

struct Tiles: View {
    let run: RunInfo

    var body: some View {
        let s = run.status
        Grid(horizontalSpacing: Theme.gap, verticalSpacing: Theme.gap) {
            GridRow {
            Tile(icon: "gauge.with.dots.needle.67percent", title: "Progress", iconColor: Theme.green,
                 badge: Badge(text: run.state.rawValue.uppercased(), color: stateColor(run.state)),
                 value: run.progress.map { "\(Int(($0 * 100).rounded()))" } ?? "\(run.epoch)",
                 unit: run.progress != nil ? "%" : "", side: "Done",
                 bar: run.progress, barColor: run.state == .paused ? Theme.amber : Theme.green,
                 lines: [progressText(run) + " · ETA " + ((s?.eta_s).map { run.state == .running ? duration($0) : "—" } ?? "—")])
            Tile(icon: "trophy.fill", title: "Best val", iconColor: Theme.amber,
                 badge: bestBadge(s), value: s?.best.map { $0.value.formatted(.number.precision(.significantDigits(4))) } ?? "—",
                 unit: "", side: s?.best.map { "ep \($0.epoch)" } ?? "",
                 bar: nil, barColor: .clear,
                 lines: [s?.best.map { "\($0.monitor ?? "val") · \($0.mode ?? "min") · green on chart" } ?? "no value logged"])
            }
            GridRow {
            patienceTile(s)
            Tile(icon: "clock.fill", title: "Time", iconColor: Theme.violet,
                 badge: (s?.timing?.slept_s ?? 0) > 0 ? Badge(text: "SLEPT", color: .secondary) : nil,
                 value: duration(s?.timing?.active_s ?? 0), unit: "", side: "Active",
                 bar: nil, barColor: .clear,
                 lines: ["paused \(duration(s?.timing?.paused_s ?? 0)) · slept \(duration(s?.timing?.slept_s ?? 0))"])
            }
        }
        if run.state == .stalled || run.state == .lost || s?.error != nil {
            Text(run.state == .stalled ? "No heartbeat: the process is alive but not reporting."
                 : run.state == .lost ? "The process is gone without finishing."
                 : "\(s!.error!.type): \(s!.error!.message)")
                .font(.caption).foregroundStyle(run.state == .stalled ? Theme.amber : Theme.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bestBadge(_ s: Status?) -> Badge? {
        guard s?.best != nil else { return nil }
        guard let p = s?.patience else { return nil }
        return p.since_best == 0 ? Badge(text: "IMPROVING", color: Theme.green) : Badge(text: "PLATEAU", color: Theme.amber)
    }

    private func patienceTile(_ s: Status?) -> Tile {
        guard let p = s?.patience else {
            return Tile(icon: "hourglass", title: "Patience", iconColor: .secondary, badge: nil, value: "—",
                        unit: "", side: "", bar: nil, barColor: .clear,
                        lines: ["not set: start(patience=…)"])
        }
        let share = Double(p.since_best) / Double(max(1, p.limit))
        let (text, color): (String, Color) = share >= 1 ? ("EXCEEDED", Theme.red)
            : share > 0.75 ? ("NEAR", Theme.amber) : ("OK", Theme.green)
        return Tile(icon: "hourglass", title: "Patience", iconColor: color, badge: Badge(text: text, color: color),
                    value: "\(p.since_best)", unit: "/\(p.limit)", side: "Epochs",
                    bar: min(1, share), barColor: color,
                    lines: [share >= 1 ? "since best · limit reached" : "since best · \(max(0, p.limit - p.since_best)) left"])
    }
}

struct Tile: View {
    let icon: String
    let title: String
    let iconColor: Color
    let badge: Badge?
    let value: String
    let unit: String
    let side: String
    let bar: Double?
    let barColor: Color
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption).foregroundStyle(iconColor)
                    .frame(height: 18) // the badge height, so tiles without a badge line up
                Text(title.uppercased()).font(.caption).foregroundStyle(.secondary).tracking(0.5)
                Spacer(minLength: 2)
                if let badge { badge }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(.numericText())
                Text(unit).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(side).font(.callout).foregroundStyle(.secondary)
            }
            // Every tile keeps the same rows so a row of tiles lines up.
            Bar(value: bar ?? 0, color: barColor, height: 5)
                .opacity(bar == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.4), value: bar)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) // fill the grid row
        .card()
    }
}

// MARK: - Loss chart

struct LossCard: View {
    let points: [MetricPoint]
    let best: Best?
    @State private var logScale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "chart.xyaxis.line").font(.caption).foregroundStyle(.blue)
                Text("LOSS — EPOCH 0–\(points.last?.epoch ?? 0)").font(.caption).foregroundStyle(.secondary).tracking(0.5)
                Spacer()
                if let v = points.last(where: { $0.val != nil })?.val {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(v.formatted(.number.precision(.significantDigits(4))))
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .contentTransition(.numericText())
                        Text("latest val").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                Chip(text: "Linear", on: !logScale) { logScale = false }
                Chip(text: "Log", on: logScale) { logScale = true }
            }
            if points.contains(where: { $0.train != nil || $0.val != nil }) {
                chart
            } else {
                Text("No losses logged yet: use run.log(epoch=…, train=…, val=…)")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 60)
            }
        }
        .padding(12)
        .card()
    }

    /// About four round epoch numbers, leaving room for the green best-epoch label.
    private var ticks: [Int] {
        let last = max(1, points.last?.epoch ?? 1)
        let raw = Double(last) / 4
        let magnitude = pow(10, floor(log10(max(1, raw))))
        let step = max(1, Int([1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw))
        var values = Array(stride(from: 0, through: last, by: step))
        if let b = best?.epoch { values.removeAll { abs($0 - b) < max(1, last / 9) } }
        return values
    }

    private var chart: some View {
        Chart {
            ForEach(points, id: \.epoch) { p in
                if let train = p.train, !logScale || train > 0 {
                    LineMark(x: .value("Epoch", p.epoch), y: .value("Loss", train), series: .value("Series", "train"))
                        .foregroundStyle(by: .value("Series", "train"))
                        .interpolationMethod(.catmullRom)
                }
                if let val = p.val, !logScale || val > 0 {
                    LineMark(x: .value("Epoch", p.epoch), y: .value("Loss", val), series: .value("Series", "val"))
                        .foregroundStyle(by: .value("Series", "val"))
                        .interpolationMethod(.catmullRom)
                }
            }
            if let best {
                RuleMark(x: .value("Epoch", best.epoch))
                    .foregroundStyle(by: .value("Series", "best val epoch"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                PointMark(x: .value("Epoch", best.epoch), y: .value("Loss", best.value))
                    .foregroundStyle(Theme.green)
                    .symbolSize(30)
            }
        }
        .chartForegroundStyleScale(["train": Color.blue, "val": Color.orange, "best val epoch": Theme.green])
        .chartLegend(position: .top, alignment: .leading)
        .chartYScale(type: logScale ? .log : .linear)
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
            // The best epoch, labelled in green on the axis.
            AxisMarks(values: best.map { [$0.epoch] } ?? []) { value in
                AxisValueLabel {
                    if let e = value.as(Int.self) {
                        Text("\(e)").font(.caption2.weight(.bold)).foregroundStyle(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.green, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                    }
                }
            }
        }
        .frame(height: 140)
    }
}

// MARK: - Footer

struct FooterBar: View {
    let run: RunInfo?
    let store: RunStore
    @Binding var confirmStop: Bool

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                if let run {
                    if run.state == .paused {
                        Button("Resume", systemImage: "play.fill") { store.send(.resume, to: run) }
                            .glassButton(prominent: true)
                    } else {
                        Button("Pause", systemImage: "pause.fill") { store.send(.pause, to: run) }
                            .glassButton(prominent: true)
                            .disabled(!run.state.canControl)
                    }
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { confirmStop = true }
                        .glassButton(tint: Theme.red)
                        .disabled(!run.state.canControl)
                }
                Spacer()
                if let run {
                    Button("Open folder", systemImage: "folder.fill") { NSWorkspace.shared.open(run.dir) }
                        .glassButton().labelStyle(.iconOnly).help("Open the run folder")
                }
                Button("Quit", systemImage: "xmark") { NSApplication.shared.terminate(nil) }
                    .glassButton().labelStyle(.iconOnly).help("Quit EpochControl (runs keep going)")
            }
            .controlSize(.large)
        }
        .animation(.snappy, value: run?.state)
        .alert("Stop \(run?.name ?? "")?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { if let run { store.send(.stop, to: run) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops at the end of the current epoch and saves a checkpoint if the script registered one.")
        }
    }
}

// MARK: - Small parts

struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No runs yet").font(.headline)
            Text("> install the package in your training environment").font(.caption).foregroundStyle(Theme.green)
            Text("pip install epochcontrol").font(.callout).textSelection(.enabled)
            Text("> wrap your epoch loop").font(.caption).foregroundStyle(Theme.green)
            Text("for epoch in epochcontrol.loop(range(200)):").font(.caption).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var dot = false
    var large = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 7, height: 7) }
            Text(text).font((large ? Font.callout : .caption2).weight(.bold))
        }
        .padding(.horizontal, large ? 10 : 6).padding(.vertical, large ? 5 : 2)
        .foregroundStyle(color == .secondary ? Color.secondary : .black.opacity(0.85))
        .background(color == .secondary ? AnyShapeStyle(.quaternary) : AnyShapeStyle(color),
                    in: RoundedRectangle(cornerRadius: large ? Theme.radius : Theme.badgeRadius))
        .contentTransition(.interpolate)
    }
}

struct Chip: View {
    let text: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text).font(.caption.weight(on ? .bold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .foregroundStyle(on ? Color.primary : .secondary)
                .background(on ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.badgeRadius).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
    }
}

/// A plain progress bar, drawn so it looks the same everywhere (and in snapshots).
struct Bar: View {
    let value: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(height, g.size.width * value))
            }
        }
        .frame(height: height)
    }
}

func stateColor(_ state: RunState) -> Color {
    switch state {
    case .running, .starting: Theme.green
    case .paused, .stopping, .stalled: Theme.amber
    case .finished: .blue
    case .failed, .lost: Theme.red
    case .stopped: .secondary
    }
}

// MARK: - Glass with a fallback

enum Glass {
    /// `EPOCHCONTROL_NO_GLASS=1` forces the pre-26 look (snapshots cannot draw glass).
    static let on = ProcessInfo.processInfo.environment["EPOCHCONTROL_NO_GLASS"] == nil
}

/// Groups glass shapes so they blend and morph into each other (macOS 26+).
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *), Glass.on {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// A card: Liquid Glass on macOS 26+, a material before. Same radius everywhere.
    @ViewBuilder
    func card() -> some View {
        if #available(macOS 26.0, *), Glass.on {
            glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(.quaternary))
        }
    }

    /// The moving selection: on macOS 26+ one tinted glass shape morphs from row to row;
    /// before, a highlight slides with matchedGeometryEffect.
    @ViewBuilder
    func selectionHighlight(_ selected: Bool, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *), Glass.on {
            if selected {
                glassEffect(.regular.tint(Theme.green.opacity(0.28)).interactive(), in: .rect(cornerRadius: Theme.radius))
                    .glassEffectID("selection", in: namespace)
            } else {
                self
            }
        } else {
            background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.green.opacity(0.16))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        let shape = ButtonBorderShape.roundedRectangle(radius: Theme.radius)
        if #available(macOS 26.0, *), Glass.on {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(shape).tint(Theme.green)
            } else if let tint {
                buttonStyle(.glass).buttonBorderShape(shape).tint(tint)
            } else {
                buttonStyle(.glass).buttonBorderShape(shape)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent).buttonBorderShape(shape).tint(Theme.green)
            } else {
                buttonStyle(.bordered).buttonBorderShape(shape).tint(tint)
            }
        }
    }
}

func progressText(_ run: RunInfo) -> String {
    if let total = run.total { return "\(run.epoch) / \(total)" }
    return "\(run.epoch)"
}

func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m" }
    if s >= 60 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
    return "\(s)s"
}

enum Snapshot {
    @MainActor
    static func render(to url: URL) {
        let store = RunStore(autoRefresh: false)
        if let pick = ProcessInfo.processInfo.environment["EPOCHCONTROL_SELECT"] { store.selectedID = pick }
        let view = PopoverView(store: store)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8)); return
        }
        try? png.write(to: url)
        let icon = MenuIcon.make(for: store.iconState)
        if let t = icon.tiffRepresentation, let p = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            try? p.write(to: url.deletingPathExtension().appendingPathExtension("icon.png"))
        }
    }
}
