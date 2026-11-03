import EpochControlKit
import Foundation
import Observation

/// Re-reads the runs folder every second (PRD APP16: new runs within 2 s). Reading never
/// writes; only the buttons write control.json. Quitting the app never touches a run.
@MainActor
@Observable
final class RunStore {
    private(set) var runs: [RunInfo] = []
    private(set) var metrics: [String: [MetricPoint]] = [:]
    var selectedID: String?
    var lastError: String?
    private var metricSizes: [String: Int] = [:]
    private var seenEnded: Set<String> = []
    private let root: URL
    private var task: Task<Void, Never>?
    /// Called after every refresh, e.g. to redraw the menu-bar icon.
    @ObservationIgnored var onRefresh: (() -> Void)?
    /// Height the popover content needs; set by the view, followed by the popover.
    @ObservationIgnored var contentHeight: CGFloat = 0 { didSet { if contentHeight != oldValue { onHeight?(contentHeight) } } }
    @ObservationIgnored var onHeight: ((CGFloat) -> Void)?

    init(root: URL = Files.runsDirectory(), autoRefresh: Bool = true) {
        self.root = root
        refresh()
        seenEnded = Set(runs.filter { !$0.state.isLive }.map(\.id)) // ended before launch: not news
        if autoRefresh {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        runs = RunReader.all(in: root)
        if selectedID == nil || !runs.contains(where: { $0.id == selectedID }) {
            selectedID = (runs.first(where: { $0.state.isLive }) ?? runs.first)?.id
        }
        if let run = selected { loadMetrics(run) }
        onRefresh?()
    }

    var selected: RunInfo? { runs.first { $0.id == selectedID } }
    var live: [RunInfo] { runs.filter { $0.state.isLive } }
    /// Live runs first, then the most recent ended ones.
    var shown: [RunInfo] { live + runs.filter { !$0.state.isLive }.prefix(5) }

    private func loadMetrics(_ run: RunInfo) {
        let url = run.dir.appendingPathComponent("metrics.jsonl")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard metricSizes[run.id] != size else { return }
        metricSizes[run.id] = size
        metrics[run.id] = Files.metrics(url)
    }

    func markSeen() { seenEnded.formUnion(runs.filter { !$0.state.isLive }.map(\.id)) }

    var iconState: MenuIcon.State {
        if runs.contains(where: { $0.state == .failed && !seenEnded.contains($0.id) }) { return .failed }
        if let run = live.last { // the oldest live run (PRD APP4)
            return .active(progress: run.progress, paused: run.state == .paused,
                           stalled: run.state == .stalled, count: live.count)
        }
        if runs.contains(where: { $0.state == .finished && !seenEnded.contains($0.id) }) { return .finishedUnseen }
        return .idle
    }

    func send(_ command: Commander.Command, to run: RunInfo) {
        do {
            try Commander.send(command, to: run)
            lastError = nil
        } catch {
            lastError = "Could not write the command: \(error.localizedDescription)"
        }
        refresh()
    }
}
