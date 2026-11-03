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
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.run()
    }
}

/// A status item with an NSPopover. Unlike a MenuBarExtra window, the popover stays attached
/// to the icon and grows or shrinks from the top when the content changes height (Harrish,
/// 3 Nov: collapsing Runs moved the window to the middle of the screen).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = RunStore()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var lastIcon: MenuIcon.State?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon (PRD APP1)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        updateIcon()
        store.onRefresh = { [weak self] in self?.updateIcon() }

        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = [.preferredContentSize] // the popover follows the content's height
        popover.contentViewController = host
        popover.behavior = .transient // closes when you click elsewhere
        popover.animates = true
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            store.markSeen()
        }
    }

    private func updateIcon() {
        let state = store.iconState
        guard state != lastIcon else { return }
        lastIcon = state
        item.button?.image = MenuIcon.make(for: state)
    }
}
