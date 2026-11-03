import AppKit

/// The menu-bar icon: a ring that fills with progress (PRD APP2, APP3).
enum MenuIcon {
    enum State: Equatable {
        case idle
        case active(progress: Double?, paused: Bool, stalled: Bool, count: Int)
        case failed
        case finishedUnseen
    }

    static func make(for state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = rect.insetBy(dx: 2.5, dy: 2.5)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = ring.width / 2
            func circle(_ alpha: CGFloat, _ color: NSColor = .black) {
                let p = NSBezierPath(ovalIn: ring)
                p.lineWidth = 2
                color.withAlphaComponent(alpha).setStroke()
                p.stroke()
            }
            switch state {
            case .idle:
                circle(0.9)
                let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
                NSColor.black.setFill(); dot.fill()
            case .failed:
                circle(1, .systemRed)
                let bar = NSBezierPath(rect: NSRect(x: center.x - 1, y: center.y - 1, width: 2, height: 5))
                NSColor.systemRed.setFill(); bar.fill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 1, y: center.y - 4, width: 2, height: 2)).fill()
            case .finishedUnseen:
                circle(0.9)
                let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                NSColor.systemGreen.setFill(); dot.fill()
            case let .active(progress, paused, stalled, count):
                circle(0.3)
                let arc = NSBezierPath()
                let end = 90 - 360 * CGFloat(progress ?? 0.12)
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: end, clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                (stalled ? NSColor.systemOrange : NSColor.black).setStroke()
                arc.stroke()
                NSColor.black.setFill()
                if paused {
                    NSBezierPath(rect: NSRect(x: center.x - 2.5, y: center.y - 2.5, width: 1.6, height: 5)).fill()
                    NSBezierPath(rect: NSRect(x: center.x + 0.9, y: center.y - 2.5, width: 1.6, height: 5)).fill()
                } else if count > 1 {
                    let s = NSAttributedString(string: "\(min(count, 9))",
                                               attributes: [.font: NSFont.systemFont(ofSize: 7, weight: .bold)])
                    let b = s.size()
                    s.draw(at: NSPoint(x: center.x - b.width / 2, y: center.y - b.height / 2))
                }
            }
            return true
        }
        // Monochrome icons follow the menu bar colour; red and green ones keep their colour.
        image.isTemplate = !([.failed, .finishedUnseen].contains(state)) && {
            if case let .active(_, _, stalled, _) = state { return !stalled }
            return true
        }()
        return image
    }
}
