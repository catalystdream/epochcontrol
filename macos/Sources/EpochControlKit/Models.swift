import Foundation

// The run folder files, as in schemas/ (format version 1). Every field is optional so a
// newer or damaged file never fails to decode as a whole (PRD APP17, NF9).

public struct Meta: Codable, Sendable, Equatable {
    public var schema: Int?
    public var run_id: String?
    public var name: String?
    public var pid: Int32?
    public var pid_start: Double?
    public var host: String?
    public var started_at: String?
    public var total_epochs: Int?
    public var source: String?
    public var run_dir: String?
    public var script: String?
}

public struct Best: Codable, Sendable, Equatable {
    public var value: Double
    public var epoch: Int
    public var monitor: String?
    public var mode: String?
}

public struct Patience: Codable, Sendable, Equatable {
    public var limit: Int
    public var since_best: Int
}

public struct Timing: Codable, Sendable, Equatable {
    public var wall_s: Double
    public var active_s: Double
    public var paused_s: Double
    public var slept_s: Double

    public init(wall_s: Double = 0, active_s: Double = 0, paused_s: Double = 0, slept_s: Double = 0) {
        self.wall_s = wall_s; self.active_s = active_s; self.paused_s = paused_s; self.slept_s = slept_s
    }
}

public struct RunError: Codable, Sendable, Equatable {
    public var type: String
    public var message: String
}

public struct Status: Codable, Sendable, Equatable {
    public var schema: Int?
    public var run_id: String?
    public var state: String?
    public var epoch: Int?
    public var total_epochs: Int?
    public var best: Best?
    public var patience: Patience?
    public var timing: Timing?
    public var eta_s: Double?
    public var heartbeat: String?
    public var pid: Int32?
    public var pid_start: Double?
    public var last_seq: Int?
    public var error: RunError?
}

public struct Control: Codable, Sendable, Equatable {
    public var schema: Int
    public var command: String
    public var seq: Int
    public var issued_at: String
    public var by: String
    public var mode: String
}

/// One line of metrics.jsonl. Only the values the app draws.
public struct MetricPoint: Sendable, Equatable {
    public var epoch: Int
    public var train: Double?
    public var val: Double?
    public var lr: Double?
}

/// What a run is, as shown. `stalled` and `lost` are worked out here, never written by
/// the package (PRD §11).
public enum RunState: String, Sendable, CaseIterable {
    case starting, running, paused, stopping, stopped, finished, failed, stalled, lost

    public var isLive: Bool { [.starting, .running, .paused, .stopping].contains(self) }
    public var canControl: Bool { [.starting, .running, .paused].contains(self) }
}
