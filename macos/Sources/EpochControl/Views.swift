import AppKit
import Charts
import EpochControlKit
import SwiftUI

// Liquid Glass on macOS 26 and later, materials before (PRD APP24). Selection moves with a
// spring; the card swaps with a blur-fade; numbers roll (PRD APP25). Reduce Motion turns
// the movement into plain fades.

struct PopoverView: View {
    let store: RunStore
    @State private var confirmStop = false
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("EpochControl").font(.headline)
                Spacer()
                Text(Host.current().localizedName ?? "").font(.caption).foregroundStyle(.secondary)
            }
            if store.runs.isEmpty {
                EmptyState()
            } else {
                RunList(store: store, namespace: selection, animation: animation)
                if let run = store.selected {
                    VStack(spacing: 12) {
                        RunCard(run: run)
                        LossChart(points: store.metrics[run.id] ?? [], best: run.status?.best)
                    }
                    .id(run.id) // a new run swaps the whole card
                    .transition(reduceMotion ? AnyTransition.opacity
                                : AnyTransition(.blurReplace).combined(with: .scale(scale: 0.98)))
                    Controls(run: run, store: store, confirmStop: $confirmStop)
                }
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Quitting does not affect your runs").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .glassButton()
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 390)
        .animation(animation, value: store.selectedID)
        .onAppear { store.markSeen() }
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No runs yet").font(.subheadline.weight(.semibold))
            Text("Install the Python package in your training environment:")
                .font(.caption).foregroundStyle(.secondary)
            Text("pip install epochcontrol").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Then wrap your epoch loop:").font(.caption).foregroundStyle(.secondary)
            Text("for epoch in epochcontrol.loop(range(200)):")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct RunList: View {
    let store: RunStore
    let namespace: Namespace.ID
    let animation: Animation

    var body: some View {
        GlassGroup(spacing: 4) {
            VStack(spacing: 3) {
                ForEach(store.shown) { run in
                    let selected = run.id == store.selectedID
                    Button {
                        withAnimation(animation) { store.selectedID = run.id }
                    } label: {
                        HStack(spacing: 8) {
                            StatePill(state: run.state, compact: true)
                            Text(run.name).lineLimit(1)
                                .fontWeight(selected ? .semibold : .regular)
                            Spacer()
                            Text(progressText(run))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .selectionHighlight(selected, in: namespace)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct RunCard: View {
    let run: RunInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(run.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                StatePill(state: run.state, compact: false)
            }
            if let progress = run.progress {
                Bar(value: progress, color: run.state == .paused ? .orange : .accentColor, height: 6)
                    .animation(.easeOut(duration: 0.4), value: progress)
            }
            HStack {
                Text(progressText(run)).contentTransition(.numericText())
                Spacer()
                if let eta = run.status?.eta_s, run.state == .running {
                    Text("ETA \(duration(eta))").contentTransition(.numericText())
                }
            }
            .font(.caption.monospacedDigit())
            .animation(.default, value: run.epoch)
            if let p = run.status?.patience {
                let share = Double(p.since_best) / Double(max(1, p.limit))
                HStack(spacing: 6) {
                    Text("No improvement for \(p.since_best) / \(p.limit)").font(.caption)
                        .contentTransition(.numericText())
                    Bar(value: min(1, share), color: share > 0.75 ? .orange : .secondary, height: 4)
                }
            }
            if let best = run.status?.best {
                Text("Best \(best.monitor ?? "val") \(best.value.formatted(.number.precision(.significantDigits(4)))) at epoch \(best.epoch)")
                    .font(.caption)
            }
            if let t = run.status?.timing {
                Text("Active \(duration(t.active_s)) · paused \(duration(t.paused_s)) · slept \(duration(t.slept_s))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if run.state == .stalled {
                Text("No heartbeat: the process is alive but not reporting.").font(.caption2).foregroundStyle(.orange)
            } else if run.state == .lost {
                Text("The process is gone without finishing.").font(.caption2).foregroundStyle(.red)
            } else if let error = run.status?.error {
                Text("\(error.type): \(error.message)").font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(12)
        .card()
    }
}

struct LossChart: View {
    let points: [MetricPoint]
    let best: Best?

    var body: some View {
        if points.contains(where: { $0.train != nil || $0.val != nil }) {
            Chart {
                ForEach(points, id: \.epoch) { p in
                    if let train = p.train {
                        LineMark(x: .value("Epoch", p.epoch), y: .value("Loss", train), series: .value("Series", "train"))
                            .foregroundStyle(by: .value("Series", "train"))
                            .interpolationMethod(.catmullRom)
                    }
                    if let val = p.val {
                        LineMark(x: .value("Epoch", p.epoch), y: .value("Loss", val), series: .value("Series", "val"))
                            .foregroundStyle(by: .value("Series", "val"))
                            .interpolationMethod(.catmullRom)
                    }
                }
                if let best {
                    RuleMark(x: .value("Best", best.epoch))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(["train": Color.blue, "val": Color.orange])
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 130)
            .padding(12)
            .card()
        }
    }
}

struct Controls: View {
    let run: RunInfo
    let store: RunStore
    @Binding var confirmStop: Bool

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                if run.state == .paused {
                    Button("Resume", systemImage: "play.fill") { store.send(.resume, to: run) }
                        .glassButton(prominent: true)
                } else {
                    Button("Pause", systemImage: "pause.fill") { store.send(.pause, to: run) }
                        .glassButton(prominent: true)
                        .disabled(!run.state.canControl)
                }
                Button("Stop", systemImage: "stop.fill", role: .destructive) { confirmStop = true }
                    .glassButton(tint: .red)
                    .disabled(!run.state.canControl)
                Spacer()
                Button("Open folder", systemImage: "folder") { NSWorkspace.shared.open(run.dir) }
                    .glassButton()
                    .labelStyle(.iconOnly)
                    .help("Open the run folder")
            }
        }
        .animation(.snappy, value: run.state)
        .alert("Stop \(run.name)?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { store.send(.stop, to: run) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops at the end of the current epoch and saves a checkpoint if the script registered one.")
        }
    }
}

struct StatePill: View {
    let state: RunState
    let compact: Bool

    var color: Color {
        switch state {
        case .running, .starting: .blue
        case .paused, .stopping, .stalled: .orange
        case .finished: .green
        case .failed, .lost: .red
        case .stopped: .secondary
        }
    }

    var body: some View {
        if compact {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: state.isLive ? color.opacity(0.6) : .clear, radius: 3)
        } else {
            Text(state.rawValue.uppercased())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundStyle(color)
                .background(color.opacity(0.15), in: Capsule())
                .contentTransition(.interpolate)
                .animation(.snappy, value: state)
        }
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
    /// A card: Liquid Glass on macOS 26+, a material before.
    @ViewBuilder
    func card(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *), Glass.on {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// The moving selection: on macOS 26+ one tinted glass shape morphs from row to row;
    /// before, a highlight slides with matchedGeometryEffect.
    @ViewBuilder
    func selectionHighlight(_ selected: Bool, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *), Glass.on {
            if selected {
                glassEffect(.regular.tint(.accentColor.opacity(0.35)).interactive(), in: .rect(cornerRadius: 9))
                    .glassEffectID("selection", in: namespace)
            } else {
                self
            }
        } else {
            background {
                if selected {
                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.18))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *), Glass.on {
            if prominent {
                buttonStyle(.glassProminent)
            } else if let tint {
                buttonStyle(.glass).tint(tint)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered).tint(tint) }
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
