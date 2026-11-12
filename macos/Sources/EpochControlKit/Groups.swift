import Foundation

// Groups and history (PRD GRP1–GRP3, APP26). Pure functions over runs, so they are tested
// without the app.

/// One batch of a group: the runs one script started, e.g. "aeroconf A1 · 4 of 9 done".
public struct GroupSummary: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var host: String?
    public var runIDs: [String]
    /// The total the script declared, or the runs seen if more than that.
    public var total: Int?
    public var done = 0      // finished
    public var running = 0   // live
    public var ended = 0     // stopped, failed or lost
    public var offline = 0
    public var lastActivity: Date?

    public var started: Int { runIDs.count }
    public var toGo: Int? { total.map { max(0, $0 - started) } }
    public var label: String { host.map { "\(name) · \($0)" } ?? name }
}

public enum Groups {
    /// The same group name reused after a pause this long starts a new batch, so running
    /// a script again tomorrow does not add to today's count.
    public static let batchGap: Double = 3600

    /// Batches of all grouped runs, newest first.
    public static func summaries(_ runs: [RunInfo], now: Date = Date()) -> [GroupSummary] {
        var byGroup: [String: [RunInfo]] = [:]
        for run in runs {
            guard let g = run.meta.group, !g.name.isEmpty else { continue }
            byGroup["\(run.host ?? "")\u{1}\(g.name)", default: []].append(run)
        }
        var out: [GroupSummary] = []
        for (_, members) in byGroup {
            let sorted = members.sorted { start($0) < start($1) }
            var batch: [RunInfo] = []
            var latestEnd = Date.distantPast
            for run in sorted {
                if !batch.isEmpty, start(run).timeIntervalSince(latestEnd) > batchGap {
                    out.append(summary(batch, now: now))
                    batch = []
                    latestEnd = .distantPast
                }
                batch.append(run)
                latestEnd = max(latestEnd, end(run))
            }
            if !batch.isEmpty { out.append(summary(batch, now: now)) }
        }
        return out.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// Groups worth showing at a glance: something still running, or active in the last 12 h.
    public static func current(_ runs: [RunInfo], now: Date = Date()) -> [GroupSummary] {
        summaries(runs, now: now).filter {
            $0.running > 0 || $0.offline > 0 || ($0.lastActivity.map { now.timeIntervalSince($0) < 12 * 3600 } ?? false)
        }
    }

    static func summary(_ batch: [RunInfo], now: Date) -> GroupSummary {
        let first = batch[0]
        let declared = batch.compactMap { $0.meta.group?.total }.max()
        var s = GroupSummary(id: "\(first.host ?? "")/\(first.meta.group?.name ?? "")/\(first.id)",
                             name: first.meta.group?.name ?? "", host: first.host, runIDs: batch.map(\.id),
                             total: declared.map { max($0, batch.count) })
        for run in batch {
            switch run.state {
            case .finished: s.done += 1
            case .offline: s.offline += 1
            case .stopped, .failed, .lost: s.ended += 1
            default: s.running += 1 // starting, running, paused, stopping, stalled
            }
        }
        s.lastActivity = batch.map { $0.state.isLive ? now : end($0) }.max()
        return s
    }

    static func start(_ run: RunInfo) -> Date {
        Files.date(run.meta.started_at) ?? History.date(run) ?? .distantPast
    }

    /// When a run ended: live ones have not ended yet.
    static func end(_ run: RunInfo) -> Date {
        if run.state.isLive || run.state == .stalled || run.state == .offline { return .distantFuture }
        if let wall = run.status?.timing?.wall_s { return start(run).addingTimeInterval(wall) }
        return Files.date(run.status?.heartbeat) ?? start(run)
    }
}

public enum History {
    public enum Machine: Hashable, Sendable {
        case all, local, host(String)
        public func matches(_ run: RunInfo) -> Bool {
            switch self {
            case .all: true
            case .local: run.host == nil
            case .host(let h): run.host == h
            }
        }
    }

    public enum Outcome: String, CaseIterable, Sendable {
        case all, finished, stopped, failed
        public func matches(_ run: RunInfo) -> Bool {
            switch self {
            case .all: true
            case .finished: run.state == .finished
            case .stopped: run.state == .stopped
            case .failed: run.state == .failed || run.state == .lost
            }
        }
    }

    /// Runs that pass the filters, grouped by start day (from the folder name, which
    /// starts with the local start time), newest day first.
    public static func days(_ runs: [RunInfo], machine: Machine = .all, outcome: Outcome = .all,
                            group: String? = nil) -> [(day: String, runs: [RunInfo])] {
        var order: [String] = []
        var byDay: [String: [RunInfo]] = [:]
        // A group filter keeps that batch's runs; an unknown batch shows nothing.
        let members: Set<String>? = group.map { g in Set(Groups.summaries(runs).first { $0.id == g }?.runIDs ?? []) }
        let picked = runs.filter { machine.matches($0) && outcome.matches($0) && (members?.contains($0.id) ?? true) }
        for run in picked.sorted(by: { folder($0) > folder($1) }) {
            let day = String(folder(run).prefix(8))
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(run)
        }
        return order.map { ($0, byDay[$0]!) }
    }

    static func folder(_ run: RunInfo) -> String { run.remoteID ?? run.dir.lastPathComponent }

    /// "20261111" → that day at midnight, local time.
    public static func date(fromDay day: String) -> Date? {
        guard day.count == 8, let y = Int(day.prefix(4)), let m = Int(day.dropFirst(4).prefix(2)),
              let d = Int(day.suffix(2)) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }

    static func date(_ run: RunInfo) -> Date? { date(fromDay: String(folder(run).prefix(8))) }

    /// "Today", "Yesterday", or "Mon 9 Nov".
    public static func title(forDay day: String, now: Date = Date()) -> String {
        guard let date = date(fromDay: day) else { return day }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
