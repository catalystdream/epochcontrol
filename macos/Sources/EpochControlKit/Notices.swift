import Foundation

// Notifications (PRD APP20, APP21): what changed between two reads of the runs. Pure, so
// the rules are tested without the app. A run that was already over when first seen (app
// start, a host's first answer, the history loading more) is never news.

public struct Notice: Equatable, Sendable {
    /// Stable per event, so the same event is never sent twice.
    public var id: String
    public var title: String
    public var body: String
    /// The run to open when the notification is clicked (`RunInfo.id`).
    public var runID: String?
}

public enum Notices {
    static let ended: Set<RunState> = [.finished, .failed, .stopped, .lost]

    /// Runs that ended, and script groups that completed, since `before`.
    public static func between(before: [RunInfo], after: [RunInfo], now: Date = Date()) -> [Notice] {
        let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Notice] = []
        for run in after where ended.contains(run.state) {
            guard let prev = was[run.id], !ended.contains(prev.state) else { continue }
            out.append(notice(for: run))
        }
        let batchesBefore = Dictionary(Groups.summaries(before, now: now).map { ($0.id, $0) },
                                       uniquingKeysWith: { a, _ in a })
        for batch in Groups.summaries(after, now: now) where complete(batch) {
            guard let prev = batchesBefore[batch.id], !complete(prev) else { continue }
            out.append(notice(for: batch))
        }
        return out
    }

    /// Every run the script said it would start has started and ended. Without a declared
    /// total there is no "complete": a bash loop is briefly idle between two runs.
    static func complete(_ g: GroupSummary) -> Bool {
        guard let total = g.total else { return false }
        return g.running == 0 && g.offline == 0 && g.started >= total
    }

    static func notice(for run: RunInfo) -> Notice {
        let s = run.status
        let progress = run.total.map { "\(run.epoch)/\($0) epochs" } ?? "\(run.epoch) epochs"
        let active = Fmt.duration(s?.timing?.active_s ?? 0)
        let body: String
        switch run.state {
        case .finished:
            let best = s?.best.map { " · best \($0.monitor ?? "val") \(Fmt.value($0.value)) @\($0.epoch)" } ?? ""
            body = "\(progress)\(best) · \(active) active"
        case .failed:
            let error = s?.error.map { "\($0.type): \($0.message)" } ?? "an error"
            body = "\(error) · at \(progress)"
        case .stopped:
            body = "Stopped at \(progress) · \(active) active"
        default: // lost
            body = "The process ended without finishing, at \(progress)"
        }
        let word = run.state.rawValue.prefix(1).uppercased() + run.state.rawValue.dropFirst()
        return Notice(id: "run:\(run.id):\(run.state.rawValue)", title: "\(word) · \(run.label)",
                      body: body, runID: run.id)
    }

    static func notice(for g: GroupSummary) -> Notice {
        var parts = ["\(g.done) of \(g.total ?? g.started) finished"]
        if g.ended > 0 { parts.append("\(g.ended) stopped or failed") }
        return Notice(id: "group:\(g.id)", title: "Group done · \(g.label)",
                      body: parts.joined(separator: " · "), runID: g.runIDs.last)
    }
}

/// Numbers and times as shown: always "." for decimals (a Mac set to Italian showed
/// "1,350" for 1.350, which read as a thousand).
public enum Fmt {
    public static let locale = Locale(identifier: "en_US_POSIX")

    public static func value(_ v: Double) -> String {
        v.formatted(.number.precision(.significantDigits(4)).grouping(.never).locale(locale))
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m" }
        if s >= 60 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s)s"
    }
}
