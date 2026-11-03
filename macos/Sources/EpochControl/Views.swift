import AppKit
import Charts
import EpochControlKit
import SwiftUI

struct PopoverView: View {
    let store: RunStore
    @State private var confirmStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("EpochControl").font(.headline)
                Spacer()
                Text(Host.current().localizedName ?? "").font(.caption).foregroundStyle(.secondary)
            }
            if store.runs.isEmpty {
                EmptyState()
            } else {
                RunList(store: store)
                if let run = store.selected {
                    RunCard(run: run)
                    LossChart(points: store.metrics[run.id] ?? [], best: run.status?.best)
                    Controls(run: run, store: store, confirmStop: $confirmStop)
                }
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Text("Quitting does not affect your runs").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { store.markSeen() }
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RunList: View {
    let store: RunStore

    var body: some View {
        VStack(spacing: 2) {
            ForEach(store.shown) { run in
                Button {
                    store.selectedID = run.id
                } label: {
                    HStack(spacing: 8) {
                        StatePill(state: run.state, compact: true)
                        Text(run.name).lineLimit(1)
                        Spacer()
                        Text(progressText(run)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(run.id == store.selectedID ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RunCard: View {
    let run: RunInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                StatePill(state: run.state, compact: false)
            }
            if let progress = run.progress {
                Bar(value: progress, color: run.state == .paused ? .orange : .accentColor, height: 6)
            }
            HStack {
                Text(progressText(run))
                Spacer()
                if let eta = run.status?.eta_s, run.state == .running { Text("ETA \(duration(eta))") }
            }
            .font(.caption.monospacedDigit())
            if let p = run.status?.patience {
                let share = Double(p.since_best) / Double(max(1, p.limit))
                HStack(spacing: 6) {
                    Text("No improvement for \(p.since_best) / \(p.limit)").font(.caption)
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
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
                    }
                    if let val = p.val {
                        LineMark(x: .value("Epoch", p.epoch), y: .value("Loss", val), series: .value("Series", "val"))
                            .foregroundStyle(by: .value("Series", "val"))
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
        }
    }
}

struct Controls: View {
    let run: RunInfo
    let store: RunStore
    @Binding var confirmStop: Bool

    var body: some View {
        HStack {
            if run.state == .paused {
                Button("Resume") { store.send(.resume, to: run) }
            } else {
                Button("Pause") { store.send(.pause, to: run) }.disabled(!run.state.canControl)
            }
            Button("Stop", role: .destructive) { confirmStop = true }.disabled(!run.state.canControl)
            Spacer()
            Button("Open folder") { NSWorkspace.shared.open(run.dir) }.buttonStyle(.borderless).font(.caption)
        }
        .alert("Stop \(run.name)?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { store.send(.stop, to: run) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops at the end of the current epoch and saves a checkpoint if the script registered one.")
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
        } else {
            Text(state.rawValue.uppercased())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(color)
                .background(color.opacity(0.15), in: Capsule())
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
