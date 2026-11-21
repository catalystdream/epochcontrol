import AppKit
import EpochControlKit
import UserNotifications

/// Sends the notices worked out by `Notices` (PRD APP20, APP21). macOS notifications when
/// the system allows them; an unsigned build may not get them (PRD risk R3), and then
/// `osascript`'s `display notification` is used instead (it shows under Script Editor).
/// A click on a notification opens the popover on that run.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the run to show when a notification is clicked.
    var onOpen: ((String) -> Void)?
    /// A short line for the bell button's help text.
    var onStatus: ((String) -> Void)?
    private var useFallback = false
    private var sent: Set<String> = []
    private let center: UNUserNotificationCenter?

    override init() {
        // UNUserNotificationCenter needs a bundle: not there when run as a bare executable.
        center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    func authorize() {
        guard let center else { useFallback = true; onStatus?("on (Script Editor notifications)"); return }
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                useFallback = false
                onStatus?(granted ? "on" : "blocked: allow EpochControl in System Settings → Notifications")
            } catch {
                useFallback = true // R3: not allowed for this build
                onStatus?("on (Script Editor notifications: \(error.localizedDescription))")
            }
        }
    }

    func post(_ notices: [Notice]) {
        for n in notices where sent.insert(n.id).inserted {
            guard let center, !useFallback else { fallback(n); continue }
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            if let run = n.runID { content.userInfo = ["run": run] }
            let request = UNNotificationRequest(identifier: n.id, content: content, trigger: nil)
            Task {
                do { try await center.add(request) } catch { fallback(n) }
            }
        }
    }

    /// Title and body go in as arguments, never into the script text, so a run name can
    /// never be read as AppleScript.
    private func fallback(_ n: Notice) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                       "-e", "end run", n.title, n.body]
        try? p.run()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound] // also while the app is in front
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let run = response.notification.request.content.userInfo["run"] as? String else { return }
        await MainActor.run { self.onOpen?(run) }
    }
}
