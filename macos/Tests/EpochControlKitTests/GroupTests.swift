import Foundation
import Testing
@testable import EpochControlKit

// Groups (PRD GRP1–GRP3) and history (APP26).

private func run(_ folder: String, group: String? = "aeroconf A1", total: Int? = 9, state: RunState,
                 started: String, wall: Double = 600, host: String? = nil) -> RunInfo {
    let meta = Meta(run_id: folder, name: folder, started_at: started,
                    group: group.map { RunGroup(name: $0, total: total) })
    let status = Status(state: state.rawValue, timing: Timing(wall_s: wall))
    var r = RunInfo(id: host.map { "\($0)/\(folder)" } ?? folder, dir: URL(fileURLWithPath: "/runs/\(folder)"),
                    meta: meta, status: status, state: state, heartbeatAge: 1)
    r.host = host
    r.remoteID = host == nil ? nil : folder
    return r
}

private let now = Files.date("2026-11-11T12:00:00+01:00")!

@Test func aBashLoopIsOneBatchWithWhatIsLeft() throws {
    let runs = [
        run("20261111-100000-aaaa", state: .finished, started: "2026-11-11T10:00:00+01:00"),
        run("20261111-101100-bbbb", state: .failed, started: "2026-11-11T10:11:00+01:00"),
        run("20261111-102500-cccc", state: .running, started: "2026-11-11T10:25:00+01:00"),
        run("20261111-090000-zzzz", group: nil, state: .finished, started: "2026-11-11T09:00:00+01:00"),
    ]
    let groups = Groups.summaries(runs, now: now)
    let g = try #require(groups.first)
    #expect(groups.count == 1)
    #expect(g.name == "aeroconf A1" && g.started == 3 && g.total == 9)
    #expect(g.done == 1 && g.ended == 1 && g.running == 1 && g.toGo == 6)
    #expect(g.lastActivity == now) // still running
}

@Test func reusingTheNameLaterStartsANewBatch() {
    let runs = [
        run("20261110-100000-aaaa", state: .finished, started: "2026-11-10T10:00:00+01:00"),
        run("20261110-101100-bbbb", state: .finished, started: "2026-11-10T10:11:00+01:00"),
        run("20261111-100000-cccc", state: .running, started: "2026-11-11T10:00:00+01:00"),
    ]
    let groups = Groups.summaries(runs, now: now)
    #expect(groups.map(\.started) == [1, 2]) // newest batch first
    #expect(groups[0].toGo == 8)
}

@Test func parallelRunsAndOtherHostsAreToldApart() {
    let runs = [
        run("20261111-100000-aaaa", state: .running, started: "2026-11-11T10:00:00+01:00", host: "spark"),
        run("20261111-100001-bbbb", state: .running, started: "2026-11-11T10:00:01+01:00", host: "spark"),
        run("20261111-100002-cccc", state: .paused, started: "2026-11-11T10:00:02+01:00", host: "spark"),
        run("20261111-100000-dddd", state: .running, started: "2026-11-11T10:00:00+01:00"), // this Mac
    ]
    let groups = Groups.summaries(runs, now: now)
    #expect(groups.count == 2)
    let spark = groups.first { $0.host == "spark" }
    #expect(spark?.running == 3 && spark?.label == "aeroconf A1 · spark")
}

@Test func totalsNeverGoBelowWhatStarted() {
    let unknown = Groups.summaries([run("20261111-100000-aaaa", total: nil, state: .running,
                                        started: "2026-11-11T10:00:00+01:00")], now: now)
    #expect(unknown.first?.total == nil && unknown.first?.toGo == nil)
    let short = Groups.summaries([
        run("20261111-100000-aaaa", total: 1, state: .finished, started: "2026-11-11T10:00:00+01:00"),
        run("20261111-101100-bbbb", total: 1, state: .running, started: "2026-11-11T10:11:00+01:00"),
    ], now: now)
    #expect(short.first?.total == 2 && short.first?.toGo == 0)
}

@Test func currentGroupsAreRunningOrRecent() {
    let old = run("20261101-100000-aaaa", group: "old", state: .finished, started: "2026-11-01T10:00:00+01:00")
    let recent = run("20261111-090000-bbbb", group: "recent", state: .finished, started: "2026-11-11T09:00:00+01:00")
    #expect(Groups.current([old, recent], now: now).map(\.name) == ["recent"])
}

@Test func historyFiltersAndGroupsByDay() {
    let runs = [
        run("20261111-100000-aaaa", state: .finished, started: "2026-11-11T10:00:00+01:00"),
        run("20261111-110000-bbbb", group: nil, state: .lost, started: "2026-11-11T11:00:00+01:00", host: "spark"),
        run("20261109-100000-cccc", group: nil, state: .stopped, started: "2026-11-09T10:00:00+01:00"),
    ]
    let all = History.days(runs)
    #expect(all.map(\.day) == ["20261111", "20261109"])
    #expect(all[0].runs.map(\.id) == ["spark/20261111-110000-bbbb", "20261111-100000-aaaa"])
    #expect(History.days(runs, machine: .local).flatMap(\.runs).count == 2)
    #expect(History.days(runs, machine: .host("spark")).flatMap(\.runs).count == 1)
    #expect(History.days(runs, outcome: .failed).flatMap(\.runs).map(\.state) == [.lost])
    #expect(History.days(runs, outcome: .stopped).flatMap(\.runs).count == 1)
    let batch = Groups.summaries(runs, now: now)[0].id
    #expect(History.days(runs, group: batch).flatMap(\.runs).count == 1)
    #expect(History.days(runs, group: "no such batch").isEmpty)
}

@Test func dayTitles() {
    #expect(History.title(forDay: "20261111", now: now) == "Today")
    #expect(History.title(forDay: "20261110", now: now) == "Yesterday")
    #expect(History.title(forDay: "20261109", now: now) != "20261109")
    #expect(History.title(forDay: "bad", now: now) == "bad")
}

@Test func aDamagedGroupNeverHidesTheRun() throws {
    let decode = { (s: String) in try JSONDecoder().decode(Meta.self, from: Data(s.utf8)) }
    #expect(try decode(#"{"run_id":"x","group":{"name":"g","total":4}}"#).group == RunGroup(name: "g", total: 4))
    #expect(try decode(#"{"run_id":"x","group":{"name":"g","total":0}}"#).group?.total == nil)
    #expect(try decode(#"{"run_id":"x","group":{"total":"nine"}}"#).group?.name == "")
    #expect(try decode(#"{"run_id":"x","group":"oops"}"#).run_id == "x")
    #expect(try decode(#"{"run_id":"x","group":null}"#).group == nil)
}
