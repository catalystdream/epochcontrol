import Foundation

/// One run, read from its folder at a moment in time.
public struct RunInfo: Identifiable, Sendable, Equatable {
    public var id: String
    public var dir: URL
    public var meta: Meta
    public var status: Status?
    public var state: RunState
    public var heartbeatAge: Double?

    public var name: String { meta.name ?? id }
    public var epoch: Int { status?.epoch ?? 0 }
    public var total: Int? { status?.total_epochs ?? meta.total_epochs }
    public var progress: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(epoch) / Double(total))
    }
}

public enum RunReader {
    public static let staleAfter: Double = 3 // three missed heartbeats

    /// Read one run folder. nil if it has no readable meta.json yet.
    public static func read(_ dir: URL, now: Date = Date(),
                            alive: (Int32?, Double?) -> Bool = Processes.isAlive) -> RunInfo? {
        guard let meta = Files.read(Meta.self, dir.appendingPathComponent("meta.json")) else { return nil }
        let status = Files.read(Status.self, dir.appendingPathComponent("status.json"))
        let age = Files.date(status?.heartbeat).map { max(0, now.timeIntervalSince($0)) }
        var state = RunState(rawValue: status?.state ?? "starting") ?? .starting
        if state.isLive, age == nil || age! > staleAfter {
            // A frozen process cannot update its heartbeat: alive means paused or stalled.
            if !alive(status?.pid ?? meta.pid, status?.pid_start ?? meta.pid_start) {
                state = .lost
            } else {
                let c = Files.read(Control.self, dir.appendingPathComponent("control.json"))
                state = (c?.mode == "os" && c?.command == "pause") ? .paused : .stalled
            }
        }
        return RunInfo(id: meta.run_id ?? dir.lastPathComponent, dir: dir, meta: meta,
                       status: status, state: state, heartbeatAge: age)
    }

    /// All runs, newest first.
    public static func all(in root: URL, now: Date = Date()) -> [RunInfo] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { read($0, now: now) }
    }
}

public enum Commander {
    public enum Command: String, Sendable { case pause, resume, stop }

    /// Write control.json with the next seq (after both the last command and the last one
    /// the run applied). Returns the seq written.
    @discardableResult
    public static func send(_ command: Command, to run: RunInfo, now: Date = Date()) throws -> Int {
        let url = run.dir.appendingPathComponent("control.json")
        let last = max(Files.read(Control.self, url)?.seq ?? 0, run.status?.last_seq ?? 0)
        let control = Control(schema: 1, command: command.rawValue, seq: last + 1,
                              issued_at: Files.isoNow(now), by: "app", mode: "cooperative")
        try Files.writeAtomically(try JSONEncoder().encode(control), to: url)
        return last + 1
    }
}
