import AppKit
import QuartzCore
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

        // Content pinned to the top: while the window shrinks, the bottom is what disappears.
        let host = NSHostingController(rootView: PopoverView(store: store)
            .frame(maxHeight: .infinity, alignment: .top))
        host.sizingOptions = [] // the popover size is set here, in step with the content
        popover.contentViewController = host
        popover.behavior = .transient // closes when you click elsewhere
        popover.animates = true
        store.onHeight = { [weak self] height in self?.resize(to: height) }
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Never taller than the screen under the icon, less a margin for the arrow.
            if let screen = button.window?.screen ?? NSScreen.main {
                store.maxHeight = screen.visibleFrame.height - 24
            }
            // Lay the content out first, so the popover opens at the right height.
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            store.markSeen()
        }
    }

    /// Resize with the same duration and curve as the SwiftUI animation (Motion.resize).
    private func resize(to height: CGFloat) {
        let size = NSSize(width: 430, height: ceil(min(height, store.maxHeight)))
        guard popover.contentSize != size else { return }
        if !popover.isShown {
            popover.contentSize = size
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.resizeDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            context.allowsImplicitAnimation = true
            popover.contentSize = size
        }
    }

    private func updateIcon() {
        let state = store.iconState
        guard state != lastIcon else { return }
        lastIcon = state
        item.button?.image = MenuIcon.make(for: state)
    }
}
