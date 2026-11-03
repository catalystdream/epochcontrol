import Darwin
import Foundation

public enum Processes {
    /// True if the process exists, belongs to this user, and started at `start` (seconds
    /// since the epoch, within 2 s) when given: a reused pid is not the same run (PRD CTL6).
    public static func isAlive(pid: Int32?, start: Double?) -> Bool {
        guard let pid, pid > 0 else { return false }
        if kill(pid, 0) != 0 { return false } // ESRCH: gone; EPERM: another user's, never ours
        guard let start, start > 0, let now = startTime(pid) else { return true }
        return abs(now - start) <= 2
    }

    /// Process start time from the kernel, seconds since the epoch.
    public static func startTime(_ pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
}
