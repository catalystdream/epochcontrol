import EpochControlKit
import Foundation
import Observation

/// Re-reads the runs folder every second (PRD APP16: new runs within 2 s). Reading never
/// writes; only the buttons write control.json. Quitting the app never touches a run.
/// Remote hosts are polled over ssh every few seconds in the background (PRD REM2); the
/// last answer is kept, so an unreachable host shows its runs as offline (REM6).
@MainActor
@Observable
final class RunStore {
    static let hostsKey = "remoteHosts"
    static let remoteInterval: Duration = .seconds(5)

    /// What the app knows about one remote host.
    struct HostState {
        var runs: [RunInfo] = []
        var metrics: [String: [MetricPoint]] = [:] // by run folder name
        var offsets: [String: Int] = [:]           // metrics.jsonl bytes already read
        var lastOK: Date?
        var error: String?
        var polling = false
    }

    private(set) var runs: [RunInfo] = []
    private(set) var metrics: [String: [MetricPoint]] = [:]
    private(set) var hostStates: [String: HostState] = [:]
    /// SSH names, saved in the app's preferences (PRD REM1).
    var hosts: [String] {
        didSet {
            UserDefaults.standard.set(hosts, forKey: Self.hostsKey)
            for gone in Set(hostStates.keys).subtracting(hosts) { hostStates[gone] = nil }
            refresh()
            if autoRefresh { pollRemotes() }
        }
    }
    /// Selecting a run loads its chart data at once, before the details swap in.
    var selectedID: String? { didSet { if let run = selected { loadMetrics(run) } } }
    var lastError: String?
    private var metricSizes: [String: Int] = [:]
    private var seenEnded: Set<String> = []
    private let root: URL
    private let autoRefresh: Bool
    private var task: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    /// Called after every refresh, e.g. to redraw the menu-bar icon.
    @ObservationIgnored var onRefresh: (() -> Void)?
    /// Height the popover content needs; set by the view, followed by the popover.
    @ObservationIgnored var contentHeight: CGFloat = 0 { didSet { if contentHeight != oldValue { onHeight?(contentHeight) } } }
    @ObservationIgnored var onHeight: ((CGFloat) -> Void)?

    init(root: URL = Files.runsDirectory(), autoRefresh: Bool = true) {
        self.root = root
        self.autoRefresh = autoRefresh
        let saved = UserDefaults.standard.stringArray(forKey: Self.hostsKey) ?? []
        self.hosts = saved.filter(RemoteHost.isValid)
        refresh()
        seenEnded = Set(runs.filter { !$0.state.isLive }.map(\.id)) // ended before launch: not news
        if autoRefresh {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.refresh()
                }
            }
            remoteTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.pollRemotes()
                    try? await Task.sleep(for: RunStore.remoteInterval)
                }
            }
        }
    }

    func refresh() {
        let local = RunReader.all(in: root)
        let remote = hosts.flatMap { hostStates[$0]?.runs ?? [] }
        // Folder names start with the start time, so one sort mixes hosts in time order.
        runs = (local + remote).sorted { ($0.remoteID ?? $0.dir.lastPathComponent) > ($1.remoteID ?? $1.dir.lastPathComponent) }
        if selectedID == nil || !runs.contains(where: { $0.id == selectedID }) {
            selectedID = (runs.first(where: { $0.state.isLive }) ?? runs.first)?.id
        }
        // Every listed run's losses stay loaded, so switching never shows an empty chart.
        for run in shown { loadMetrics(run) }
        onRefresh?()
    }

    var selected: RunInfo? { runs.first { $0.id == selectedID } }
    var live: [RunInfo] { runs.filter { $0.state.isLive } }
    /// Live runs first, then the most recent ended ones.
    var shown: [RunInfo] { live + runs.filter { !$0.state.isLive }.prefix(5) }

    private func loadMetrics(_ run: RunInfo) {
        if let host = run.host, let rid = run.remoteID { // arrives with each poll
            metrics[run.id] = hostStates[host]?.metrics[rid] ?? []
            return
        }
        let url = run.dir.appendingPathComponent("metrics.jsonl")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard metricSizes[run.id] != size else { return }
        metricSizes[run.id] = size
        metrics[run.id] = Files.metrics(url)
    }

    // MARK: Remote hosts

    /// Start a poll for every host that is not already being polled. Never waits.
    func pollRemotes() {
        for host in hosts where hostStates[host]?.polling != true {
            Task { await poll(host) }
        }
    }

    private func poll(_ host: String) async {
        var state = hostStates[host] ?? HostState()
        guard !state.polling else { return }
        state.polling = true
        hostStates[host] = state
        let result: Result<RemoteReply, Error>
        do { result = .success(try await Remote.read(via: .ssh(host), offsets: state.offsets)) }
        catch { result = .failure(error) }
        guard hosts.contains(host), var s = hostStates[host] else { return } // removed meanwhile
        s.polling = false
        switch result {
        case .success(let reply):
            var keep: [String: [MetricPoint]] = [:], offsets: [String: Int] = [:]
            for r in reply.runs {
                let new = Files.metrics(lines: r.metrics)
                keep[r.id] = r.metrics_from == 0 ? new : (s.metrics[r.id] ?? []) + new
                offsets[r.id] = r.metrics_to
            }
            s.metrics = keep
            s.offsets = offsets
            s.runs = Remote.runs(from: reply, host: host)
            s.lastOK = Date()
            s.error = nil
        case .failure(let error):
            s.error = error.localizedDescription
            // Last known state, greyed: never lost or stalled because the Mac lost the line.
            s.runs = s.runs.map { run in
                var r = run
                if r.state.isLive || r.state == .stalled { r.state = .offline }
                return r
            }
        }
        hostStates[host] = s
        refresh()
    }

    // MARK: Commands

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
        if let host = run.host, let rid = run.remoteID {
            Task {
                do {
                    try await Remote.send(command, run: rid, via: .ssh(host))
                    lastError = nil
                } catch {
                    lastError = "\(host): could not send \(command.rawValue) (\(error.localizedDescription))"
                }
                await poll(host)
            }
            return
        }
        do {
            try Commander.send(command, to: run)
            lastError = nil
        } catch {
            lastError = "Could not write the command: \(error.localizedDescription)"
        }
        refresh()
    }
}
