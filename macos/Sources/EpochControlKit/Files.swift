import Foundation

public enum Files {
    /// `EPOCHCONTROL_HOME/runs` if set, else ~/Library/Application Support/EpochControl/runs.
    public static func runsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["EPOCHCONTROL_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("runs")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EpochControl/runs")
    }

    /// Decode a JSON file; nil if it is missing, half-written or not valid (PRD APP17).
    public static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Lines of metrics.jsonl. A bad or partial line is skipped.
    public static func metrics(_ url: URL) -> [MetricPoint] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return metrics(lines: text.split(separator: "\n").map(String.init))
    }

    /// The same, from lines already read (a remote run's metrics arrive as lines).
    public static func metrics(lines: [String]) -> [MetricPoint] {
        var out: [MetricPoint] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let epoch = obj["epoch"] as? Int else { continue }
            out.append(MetricPoint(epoch: epoch, train: obj["train"] as? Double,
                                   val: obj["val"] as? Double, lr: obj["lr"] as? Double))
        }
        return out
    }

    /// Write to a temp file in the same folder, then rename: a reader never sees half a file.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return try? Date(s, strategy: .iso8601)
    }

    public static func isoNow(_ d: Date = Date()) -> String {
        d.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }
}
