import Foundation
import Testing
@testable import EpochControlKit

// Notifications (PRD APP20, APP21), number format and timestamps.

private func run(_ folder: String, _ state: RunState, group: String? = nil, total: Int? = nil,
                 host: String? = nil, epoch: Int = 600, best: Double? = 0.4716,
                 started: String = "2026-11-19T08:07:13+01:00") -> RunInfo {
    let meta = Meta(run_id: folder, name: "aeroconf \(folder.suffix(4))", started_at: started, total_epochs: 600,
                    group: group.map { RunGroup(name: $0, total: total) })
    var status = Status(state: state == .lost ? "running" : state.rawValue, epoch: epoch, total_epochs: 600,
                        timing: Timing(wall_s: 13_000, active_s: 12_960))
    if let best { status.best = Best(value: best, epoch: 567, monitor: "val", mode: "min") }
    if state == .failed { status.error = RunError(type: "ValueError", message: "nan loss") }
    var r = RunInfo(id: host.map { "\($0)/\(folder)" } ?? folder, dir: URL(fileURLWithPath: "/r/\(folder)"),
                    meta: meta, status: status, state: state, heartbeatAge: 1)
    r.host = host
    r.remoteID = host == nil ? nil : folder
    return r
}

@Test func aRunThatEndsIsNewsOnce() throws {
    let before = [run("20261119-080713-9e60", .running, host: "spark")]
    let after = [run("20261119-080713-9e60", .finished, host: "spark")]
    let n = try #require(Notices.between(before: before, after: after).first)
    #expect(n.title == "Finished · spark · aeroconf 9e60")
    #expect(n.body == "600/600 epochs · best val 0.4716 @567 · 3h 36m active")
    #expect(n.runID == "spark/20261119-080713-9e60")
    #expect(Notices.between(before: after, after: after).isEmpty) // already over: not news again
}

@Test func failedStoppedAndLostSayWhy() {
    let a = "20261119-080713-aaaa"
    let failed = Notices.between(before: [run(a, .running)], after: [run(a, .failed, epoch: 120)])
    #expect(failed.first?.title.hasPrefix("Failed") == true)
    #expect(failed.first?.body == "ValueError: nan loss · at 120/600 epochs")
    let stopped = Notices.between(before: [run(a, .paused)], after: [run(a, .stopped, epoch: 391)])
    #expect(stopped.first?.body.hasPrefix("Stopped at 391/600 epochs") == true)
    let lost = Notices.between(before: [run(a, .stalled)], after: [run(a, .lost, epoch: 50)])
    #expect(lost.first?.title.hasPrefix("Lost") == true)
}

@Test func runsAlreadyOverWhenFirstSeenAreNotNews() {
    // App start, a host's first answer, or the history loading 300 runs.
    #expect(Notices.between(before: [], after: [run("20261119-080713-aaaa", .finished)]).isEmpty)
    // A remote run that ended while the host was offline is news when it comes back.
    let id = "20261119-080713-bbbb"
    #expect(Notices.between(before: [run(id, .offline, host: "spark")],
                            after: [run(id, .finished, host: "spark")]).count == 1)
}

@Test func aGroupIsDoneOnlyWhenEveryDeclaredRunEnded() {
    let g = "aeroconf A1"
    let r1 = run("20261119-080000-0001", .finished, group: g, total: 2, started: "2026-11-19T08:00:00+01:00")
    let r2live = run("20261119-090000-0002", .running, group: g, total: 2, started: "2026-11-19T09:00:00+01:00")
    let r2done = run("20261119-090000-0002", .failed, group: g, total: 2, started: "2026-11-19T09:00:00+01:00")
    let now = Files.date("2026-11-19T12:00:00+01:00")!
    let notices = Notices.between(before: [r1, r2live], after: [r1, r2done], now: now)
    #expect(notices.map(\.title).contains("Group done · aeroconf A1"))
    #expect(notices.first { $0.id.hasPrefix("group:") }?.body == "1 of 2 finished · 1 stopped or failed")
    // Between two runs of a bash loop (1 of 2 started, none running): not done yet.
    let r1live = run("20261119-080000-0001", .running, group: g, total: 2, started: "2026-11-19T08:00:00+01:00")
    #expect(Notices.between(before: [r1live], after: [r1], now: now).allSatisfy { !$0.id.hasPrefix("group:") })
    // Without a declared total there is no "group done".
    let a = run("20261119-080000-0003", .running, group: "open", started: "2026-11-19T08:00:00+01:00")
    let b = run("20261119-080000-0003", .finished, group: "open", started: "2026-11-19T08:00:00+01:00")
    #expect(Notices.between(before: [a], after: [b], now: now).allSatisfy { !$0.id.hasPrefix("group:") })
}

@Test func numbersAlwaysUseADecimalPoint() {
    #expect(Fmt.value(1.350) == "1.350") // 4 significant digits, as before, but a point
    #expect(Fmt.value(0.04958) == "0.04958")
    #expect(Fmt.value(1529) == "1529") // no thousands separator
    #expect(Fmt.value(177.6) == "177.6")
    #expect(Fmt.duration(12_960) == "3h 36m")
}

@Test func timestampsAreRFC3339() throws {
    let d = try #require(Files.date("2026-11-21T10:00:00+01:00"))
    #expect(Files.isoNow(d, timeZone: TimeZone(identifier: "Europe/Rome")!) == "2026-11-21T10:00:00+01:00")
    #expect(Files.isoNow(d, timeZone: TimeZone(identifier: "UTC")!) == "2026-11-21T09:00:00Z")
}
