import AppKit
import EpochControlKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // `--snapshot out.png`: render the popover to an image and quit (layout checks).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        EpochControlApp.main()
    }
}

struct EpochControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = RunStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            Image(nsImage: MenuIcon.make(for: store.iconState))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon (PRD APP1)
    }
}
