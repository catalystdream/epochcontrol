import Foundation
import Testing
@testable import EpochControlKit

private let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    .appendingPathComponent("runs")
private let exampleID = "20261103-104512-7f3a"
// The example status heartbeat is 2026-11-03T13:20:24+01:00.
private let heartbeat = Files.date("2026-11-03T13:20:24+01:00")!

private func copyFixtures() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(at: fixtures, to: dir)
    return dir
}

@Test func decodesTheSchemaExamples() throws {
    let run = try #require(RunReader.read(fixtures.appendingPathComponent(exampleID),
                                          now: heartbeat.addingTimeInterval(1)))
    #expect(run.state == .running)
    #expect(run.name == "tft-lstm lumo s43")
    #expect(run.epoch == 140 && run.total == 600)
    #expect(run.status?.best == Best(value: 0.02336, epoch: 128, monitor: "val", mode: "min"))
    #expect(run.status?.timing?.slept_s == 2292.3)
    #expect(abs((run.progress ?? 0) - 140.0 / 600) < 1e-9)
}

@Test func skipsBadMetricLines() {
    let points = Files.metrics(fixtures.appendingPathComponent(exampleID).appendingPathComponent("metrics.jsonl"))
    #expect(points.map(\.epoch) == [140, 141, 142])
    #expect(points[2].val == nil && points[0].val == 0.0236)
}

@Test func halfWrittenOrMissingFilesNeverCrash() {
    let runs = RunReader.all(in: fixtures, now: heartbeat)
    #expect(runs.map(\.id) == [exampleID, "20261103-090000-aaaa", "20261103-080000-bbbb"]) // no meta: skipped
    let damaged = runs[1]
    #expect(damaged.status == nil)
    #expect(RunReader.all(in: URL(fileURLWithPath: "/nonexistent")).isEmpty)
}

@Test func staleHeartbeatMeansStalledOrLost() {
    let dir = fixtures.appendingPathComponent(exampleID)
    let later = heartbeat.addingTimeInterval(60)
    #expect(RunReader.read(dir, now: later, alive: { _, _ in true })?.state == .stalled)
    #expect(RunReader.read(dir, now: later, alive: { _, _ in false })?.state == .lost)
    #expect(RunReader.read(dir, now: heartbeat.addingTimeInterval(2), alive: { _, _ in false })?.state == .running)
    // Ended runs keep their state whatever the heartbeat says.
    #expect(RunReader.read(fixtures.appendingPathComponent("20261103-080000-bbbb"), now: later)?.state == .finished)
}

@Test func osPauseReadsAsPausedNotStalled() throws {
    let root = try copyFixtures()
    let dir = root.appendingPathComponent(exampleID)
    let c = Control(schema: 1, command: "pause", seq: 1, issued_at: Files.isoNow(), by: "app", mode: "os")
    try Files.writeAtomically(try JSONEncoder().encode(c), to: dir.appendingPathComponent("control.json"))
    #expect(RunReader.read(dir, now: heartbeat.addingTimeInterval(60), alive: { _, _ in true })?.state == .paused)
}

@Test func commandsUseTheNextSeqAndAreAtomic() throws {
    let root = try copyFixtures()
    let run = try #require(RunReader.read(root.appendingPathComponent(exampleID), now: heartbeat))
    #expect(try Commander.send(.pause, to: run) == 1)
    #expect(try Commander.send(.resume, to: run) == 2)
    let url = run.dir.appendingPathComponent("control.json")
    let control = try #require(Files.read(Control.self, url))
    #expect(control.command == "resume" && control.by == "app" && control.mode == "cooperative")
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: run.dir.path).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty)
}

@Test func thisProcessIsAliveAndAReusedPidIsNot() {
    let me = getpid()
    let start = Processes.startTime(me)
    #expect(start != nil)
    #expect(Processes.isAlive(pid: me, start: start))
    #expect(!Processes.isAlive(pid: me, start: 1))          // different start: reused pid
    #expect(!Processes.isAlive(pid: 99_999_999, start: nil))  // no such process
}

@Test func runsDirectoryHonoursTheEnvironment() {
    #expect(Files.runsDirectory(environment: ["EPOCHCONTROL_HOME": "/tmp/x"]).path == "/tmp/x/runs")
    #expect(Files.runsDirectory(environment: [:]).path.hasSuffix("Library/Application Support/EpochControl/runs"))
}
