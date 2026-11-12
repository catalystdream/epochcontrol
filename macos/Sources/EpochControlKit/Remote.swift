import Foundation

// Runs on other machines (PRD REM1–REM8). The app sends a small reader, Python standard
// library only, over `ssh <host> python3 -` and reads one JSON reply. Nothing needs to be
// installed on the remote machine besides the package in the training environment. The
// request is embedded in the script as base64 JSON, so nothing is ever quoted for a shell.

public enum RemoteHost {
    /// An SSH name or `user@host`: letters, digits, `.`, `_`, `-`, one `@`; never starts with
    /// `-` (it would be read as an ssh option). Anything else is refused before it reaches ssh.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 253, let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
        return name.unicodeScalars.allSatisfy(allowed.contains)
            && name.filter { $0 == "@" }.count <= 1
    }

    /// "spark, atlas user@box" → valid names in order, duplicates removed.
    public static func parse(_ text: String) -> (hosts: [String], rejected: [String]) {
        var hosts: [String] = [], rejected: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) {
            if isValid(part) { if !hosts.contains(part) { hosts.append(part) } } else { rejected.append(part) }
        }
        return (hosts, rejected)
    }
}

/// One run as the reader reports it.
public struct RemoteRun: Decodable, Sendable {
    public var id: String
    public var dir: String
    public var meta: Meta
    public var status: Status?
    public var control: Control?
    public var age: Double?
    public var alive: Bool?
    public var metrics_from: Int
    public var metrics_to: Int
    public var metrics: [String]
    /// True when the chart points were not asked for (an ended run nobody is looking at):
    /// keep what is already loaded.
    public var skipped: Bool?
}

public struct RemoteReply: Decodable, Sendable {
    public var schema: Int
    public var root: String
    public var runs: [RemoteRun]
}

public struct RemoteSendReply: Decodable, Sendable {
    public var ok: Bool
    public var seq: Int?
    public var error: String?
}

public enum RemoteError: Error, Equatable, LocalizedError {
    case timedOut
    case failed(code: Int32, message: String)
    case badReply(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut: "no answer in time"
        case .failed(_, let message): message
        case .badReply(let m): "unexpected reply: \(m)"
        }
    }
}

/// How the reader reaches a machine: ssh in the app, plain `python3 -` in the tests.
public struct RemoteTransport: Sendable {
    public var argv: [String]
    public var environment: [String: String]?
    public var timeout: Double

    public init(argv: [String], environment: [String: String]? = nil, timeout: Double = 20) {
        self.argv = argv; self.environment = environment; self.timeout = timeout
    }

    /// BatchMode: never prompt (a prompt would hang a background poll). ControlMaster=no: a
    /// persisted master would keep our pipes open and the poll would wait for it to exit.
    public static func ssh(_ host: String, connectTimeout: Int = 5) -> RemoteTransport {
        RemoteTransport(argv: ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes",
                               "-o", "ConnectTimeout=\(connectTimeout)",
                               "-o", "ControlMaster=no",
                               "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                               "--", host, "python3 -"])
    }

    /// Run the transport with `input` on stdin and return stdout. Off the main thread.
    public func run(_ input: Data) async throws -> Data {
        let transport = self
        return try await Task.detached { try transport.runBlocking(input) }.value
    }

    /// Blocking version of `run`, for a background thread only.
    func runBlocking(_ input: Data) throws -> Data {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            if let environment { p.environment = environment }
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            try p.run()
            // Read both pipes while the process runs, so a full pipe never blocks it.
            let out = Collector(), err = Collector()
            let group = DispatchGroup()
            for (pipe, sink) in [(outPipe, out), (errPipe, err)] {
                group.enter()
                DispatchQueue.global().async { sink.data = pipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            }
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
            if done.wait(timeout: .now() + timeout) == .timedOut {
                p.terminate()
                _ = done.wait(timeout: .now() + 2)
                throw RemoteError.timedOut
            }
            _ = group.wait(timeout: .now() + 2)
            guard p.terminationStatus == 0 else {
                let text = String(decoding: err.data, as: UTF8.self)
                let line = text.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
                throw RemoteError.failed(code: p.terminationStatus, message: line)
            }
            return out.data
    }
}

private final class Collector: @unchecked Sendable { var data = Data() }

public enum Remote {
    /// Read the newest run folders, with only the metrics bytes after `offsets[runID]`.
    /// With `want`, chart points come only for live runs and those run folders, so a long
    /// history stays cheap to poll (PRD APP26).
    public static func read(via transport: RemoteTransport, offsets: [String: Int] = [:],
                            limit: Int = 30, want: [String]? = nil) async throws -> RemoteReply {
        var request: [String: Any] = ["op": "read", "offsets": offsets, "limit": limit]
        if let want { request["want"] = want }
        let data = try await transport.run(script(request))
        do { return try JSONDecoder().decode(RemoteReply.self, from: data) } catch {
            throw RemoteError.badReply(String(decoding: data.prefix(120), as: UTF8.self))
        }
    }

    /// Write control.json for one run on the remote machine. Returns the seq written.
    @discardableResult
    public static func send(_ command: Commander.Command, run runID: String,
                            via transport: RemoteTransport) async throws -> Int {
        let data = try await transport.run(script(["op": "send", "run": runID, "command": command.rawValue]))
        guard let reply = try? JSONDecoder().decode(RemoteSendReply.self, from: data) else {
            throw RemoteError.badReply(String(decoding: data.prefix(120), as: UTF8.self))
        }
        guard reply.ok, let seq = reply.seq else { throw RemoteError.failed(code: 3, message: reply.error ?? "not applied") }
        return seq
    }

    /// Turn a reply into runs the app shows. Ids are `host/run_id`, so they never clash with
    /// local runs or another host's.
    public static func runs(from reply: RemoteReply, host: String) -> [RunInfo] {
        reply.runs.map { r in
            var info = RunReader.classify(id: r.meta.run_id ?? r.id, dir: URL(fileURLWithPath: r.dir),
                                          meta: r.meta, status: r.status, control: r.control,
                                          age: r.age, alive: { _, _ in r.alive ?? false })
            info.host = host
            info.remoteID = r.id
            info.id = "\(host)/\(r.id)"
            return info
        }
    }

    static func script(_ request: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Data(("REQ = \"\(json.base64EncodedString())\"\n" + reader).utf8)
    }

    /// The reader. Python 3.6+, standard library only. Mirrors `_paths.py` and `_proc.py`,
    /// and writes control.json the way `Commander.send` does.
    static let reader = #"""
import base64, json, os, sys
from datetime import datetime, timezone

REQ = json.loads(base64.b64decode(REQ).decode("utf-8"))
LIVE = ("starting", "running", "paused", "stopping")


def runs_root():
    home = os.environ.get("EPOCHCONTROL_HOME")
    if home:
        return os.path.join(os.path.expanduser(home), "runs")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/EpochControl/runs")
    data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(data, "epochcontrol", "runs")


def read_json(path):
    try:
        with open(path) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except Exception:
        return None


def start_time(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            ticks = int(f.read().rsplit(")", 1)[1].split()[19])
        with open("/proc/stat") as f:
            btime = next(int(l.split()[1]) for l in f if l.startswith("btime"))
        return btime + ticks / os.sysconf("SC_CLK_TCK")
    except Exception:
        return None


def alive(pid, start):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False  # gone, or another user's
    if not start:
        return True
    now = start_time(pid)
    return True if now is None else abs(now - float(start)) <= 2


def age_of(stamp):
    try:
        s = stamp[:-1] + "+00:00" if stamp.endswith("Z") else stamp
        then = datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
        off = s[19:]
        if off.startswith("."):
            off = off.lstrip(".0123456789")
        sign = -1 if off.startswith("-") else 1
        digits = off[1:].replace(":", "")  # "+01:00" (Python) and "+0100" (Swift) alike
        hh, mm = (int(digits[:2]), int(digits[2:4] or 0)) if off else (0, 0)
        then = then.replace(tzinfo=timezone.utc).timestamp() - sign * (hh * 3600 + mm * 60)
        return max(0.0, datetime.now(timezone.utc).timestamp() - then)
    except Exception:
        return None


def metrics_since(path, start):
    try:
        size = os.path.getsize(path)
    except OSError:
        return 0, 0, []
    if start > size:
        start = 0  # the file was rewritten: send it all again
    with open(path, "rb") as f:
        f.seek(start)
        data = f.read(4 * 1024 * 1024)
    end = data.rfind(b"\n") + 1  # whole lines only; a half-written line waits for the next poll
    lines = [l for l in data[:end].decode("utf-8", "replace").split("\n") if l.strip()]
    return start, start + end, lines


def do_read(root):
    try:
        names = [n for n in os.listdir(root)
                 if not n.startswith(".") and os.path.isdir(os.path.join(root, n))]
    except OSError:
        names = []
    out = []
    offsets = REQ.get("offsets") or {}
    want = REQ.get("want")
    want = set(want) if isinstance(want, list) else None
    for n in sorted(names, reverse=True)[: int(REQ.get("limit", 30))]:
        d = os.path.join(root, n)
        meta = read_json(os.path.join(d, "meta.json"))
        if meta is None:
            continue
        meta.pop("argv", None)  # may hold secrets: never leaves the machine (PRD REM8, NF6)
        status = read_json(os.path.join(d, "status.json"))
        control = read_json(os.path.join(d, "control.json"))
        s = status or {}
        age = age_of(s["heartbeat"]) if isinstance(s.get("heartbeat"), str) else None
        live = s.get("state", "starting") in LIVE
        is_alive = alive(s.get("pid") or meta.get("pid"), s.get("pid_start") or meta.get("pid_start")) if live else None
        skipped = want is not None and not live and n not in want
        if skipped:
            frm = to = int(offsets.get(n, 0))
            lines = []
        else:
            frm, to, lines = metrics_since(os.path.join(d, "metrics.jsonl"), int(offsets.get(n, 0)))
        out.append({"id": n, "dir": d, "meta": meta, "status": status, "control": control,
                    "age": age, "alive": is_alive, "metrics_from": frm, "metrics_to": to,
                    "metrics": lines, "skipped": skipped})
    return {"schema": 1, "root": root, "runs": out}


def do_send(root):
    n, cmd = REQ.get("run", ""), REQ.get("command")
    if cmd not in ("pause", "resume", "stop"):
        return {"ok": False, "error": "unknown command"}
    if not n or "/" in n or n.startswith(".") or not os.path.isdir(os.path.join(root, n)):
        return {"ok": False, "error": "no such run on this machine"}
    d = os.path.join(root, n)
    c = read_json(os.path.join(d, "control.json")) or {}
    s = read_json(os.path.join(d, "status.json")) or {}
    last = max(c.get("seq") if isinstance(c.get("seq"), int) else 0,
               s.get("last_seq") if isinstance(s.get("last_seq"), int) else 0)
    body = {"schema": 1, "command": cmd, "seq": last + 1,
            "issued_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            "by": "app", "mode": "cooperative"}
    tmp = os.path.join(d, ".control.json.tmp-%d" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(body, f)
    os.replace(tmp, os.path.join(d, "control.json"))
    return {"ok": True, "seq": last + 1}


root = runs_root()
op = REQ.get("op")
reply = do_read(root) if op == "read" else do_send(root) if op == "send" else {"ok": False, "error": "unknown op"}
sys.stdout.write(json.dumps(reply))
"""#
}
