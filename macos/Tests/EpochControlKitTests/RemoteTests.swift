import Foundation
import Testing
@testable import EpochControlKit

// The reader is tested by running it for real with `python3 -` on a copy of the schema
// fixtures, the same way ssh runs it on another machine, minus the ssh hop.

private let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    .appendingPathComponent("runs")
private let exampleID = "20261103-104512-7f3a"

/// A fresh EPOCHCONTROL_HOME holding a copy of the fixture runs, and a transport into it.
private func remoteHome() throws -> (runs: URL, transport: RemoteTransport) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let runs = home.appendingPathComponent("runs")
    try FileManager.default.copyItem(at: fixtures, to: runs)
    var env = ProcessInfo.processInfo.environment
    env["EPOCHCONTROL_HOME"] = home.path
    return (runs, RemoteTransport(argv: ["/usr/bin/python3", "-"], environment: env, timeout: 30))
}

@Test func hostNamesAreCheckedBeforeSsh() {
    #expect(RemoteHost.isValid("spark"))
    #expect(RemoteHost.isValid("raj@100.74.62.32"))
    #expect(RemoteHost.isValid("gpu-box.tail37e025.ts.net"))
    #expect(!RemoteHost.isValid("-oProxyCommand=touch x")) // would be an ssh option
    #expect(!RemoteHost.isValid("spark;rm"))
    #expect(!RemoteHost.isValid("a@b@c"))
    #expect(!RemoteHost.isValid(""))
    let parsed = RemoteHost.parse("spark, atlas  spark -x")
    #expect(parsed.hosts == ["spark", "atlas"] && parsed.rejected == ["-x"])
}

@Test func sshTransportNeverPromptsAndEndsOptionsBeforeTheHost() {
    let argv = RemoteTransport.ssh("spark").argv
    #expect(argv.contains("BatchMode=yes") && argv.contains("ControlMaster=no"))
    #expect(Array(argv.suffix(3)) == ["--", "spark", "python3 -"])
}

@Test func readerReadsRunsLikeTheLocalReader() async throws {
    let (runs, transport) = try remoteHome()
    let reply = try await Remote.read(via: transport)
    #expect(reply.root == runs.path)
    // Same runs, same order, as reading the folder on this Mac (no meta: skipped).
    #expect(reply.runs.map(\.id) == RunReader.all(in: runs).map(\.id))
    let shown = Remote.runs(from: reply, host: "spark")
    let example = try #require(shown.first)
    #expect(example.id == "spark/\(exampleID)" && example.host == "spark" && example.remoteID == exampleID)
    #expect(example.label == "spark · tft-lstm lumo s43")
    #expect(example.epoch == 140 && example.total == 600)
    // The fixture's heartbeat is days old and its pid is not running here: lost, worked out
    // on the remote side.
    #expect(example.state == .lost)
    let first = try #require(reply.runs.first)
    #expect(Files.metrics(lines: first.metrics).map(\.epoch) == [140, 141, 142])
}

@Test func liveRunWithFreshHeartbeatIsRunning() async throws {
    let (runs, transport) = try remoteHome()
    let statusURL = runs.appendingPathComponent(exampleID).appendingPathComponent("status.json")
    var status = try #require(Files.read(Status.self, statusURL))
    status.heartbeat = Files.isoNow()
    status.pid = getpid() // this test process: alive
    status.pid_start = nil
    try Files.writeAtomically(try JSONEncoder().encode(status), to: statusURL)
    let reply = try await Remote.read(via: transport)
    let run = try #require(Remote.runs(from: reply, host: "spark").first)
    #expect(run.state == .running)
    #expect((run.heartbeatAge ?? 99) < 5)
}

@Test func metricsComeOnlyAfterTheLastOffset() async throws {
    let (runs, transport) = try remoteHome()
    let first = try #require(try await Remote.read(via: transport).runs.first)
    #expect(first.metrics_from == 0 && !first.metrics.isEmpty)
    let again = try #require(try await Remote.read(via: transport, offsets: [exampleID: first.metrics_to]).runs.first)
    #expect(again.metrics.isEmpty && again.metrics_from == first.metrics_to)
    // A new whole line, then half a line still being written: only the whole one comes.
    let url = runs.appendingPathComponent(exampleID).appendingPathComponent("metrics.jsonl")
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    handle.write(Data("{\"epoch\":143,\"train\":0.02}\n{\"epoch\":144,".utf8))
    try handle.close()
    let more = try #require(try await Remote.read(via: transport, offsets: [exampleID: first.metrics_to]).runs.first)
    #expect(Files.metrics(lines: more.metrics).map(\.epoch) == [143])
}

@Test func recordedCommandLinesNeverLeaveTheMachine() async throws {
    let (runs, transport) = try remoteHome()
    let metaURL = runs.appendingPathComponent(exampleID).appendingPathComponent("meta.json")
    var meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
    meta["argv"] = ["train.py", "--token", "SECRET123"]
    try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
    let raw = try await transport.run(Remote.script(["op": "read", "offsets": [String: Int](), "limit": 30]))
    #expect(!String(decoding: raw, as: UTF8.self).contains("SECRET123"))
}

@Test func remoteCommandsWriteControlLikeTheApp() async throws {
    let (runs, transport) = try remoteHome()
    #expect(try await Remote.send(.pause, run: exampleID, via: transport) == 1)
    #expect(try await Remote.send(.resume, run: exampleID, via: transport) == 2)
    let dir = runs.appendingPathComponent(exampleID)
    let url = dir.appendingPathComponent("control.json")
    let control = try #require(Files.read(Control.self, url))
    #expect(control.schema == 1 && control.command == "resume" && control.seq == 2)
    #expect(control.by == "app" && control.mode == "cooperative")
    #expect(Files.date(control.issued_at) != nil)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty)
}

@Test func remoteCommandsRefuseRunsOutsideTheFolder() async throws {
    let (_, transport) = try remoteHome()
    for bad in ["../\(exampleID)", "", ".hidden", "no-such-run"] {
        await #expect(throws: RemoteError.self) { try await Remote.send(.stop, run: bad, via: transport) }
    }
}

@Test func failedOrSlowTransportsAreErrorsNotHangs() async throws {
    await #expect(throws: RemoteError.self) {
        try await Remote.read(via: RemoteTransport(argv: ["/usr/bin/false"]))
    }
    let start = Date()
    await #expect(throws: RemoteError.timedOut) {
        try await Remote.read(via: RemoteTransport(argv: ["/bin/sleep", "10"], timeout: 1))
    }
    #expect(Date().timeIntervalSince(start) < 5)
}
