import AppKit

@MainActor
enum TBProgressImage {
    static let size = NSSize(width: 104, height: 18)

    static func make(progress: Double, state: TBFocusState, width: Double = 76, style: MenuBarStyle = .minimal) -> NSImage {
        let ratio = progress.isFinite ? min(1, max(0, progress)) : 0
        let width = width.isFinite ? min(140, max(60, width)) : 76
        let image = NSImage(size: NSSize(width: width + 28, height: 18), flipped: false) { _ in
            let track = NSRect(x: 22, y: 6, width: width, height: 6)
            switch style {
            case .minimal:
                drawFill(NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3), rect: track, fraction: ratio)
            case .segmented:
                let count = 10
                let gap: CGFloat = 2
                let segmentWidth = (track.width - gap * CGFloat(count - 1)) / CGFloat(count)
                for index in 0..<count {
                    let rect = NSRect(x: track.minX + CGFloat(index) * (segmentWidth + gap), y: 5.5, width: segmentWidth, height: 7)
                    drawFill(NSBezierPath(roundedRect: rect, xRadius: 1.4, yRadius: 1.4), rect: rect,
                             fraction: min(1, max(0, ratio * Double(count) - Double(index))))
                }
            case .cursor:
                let line = NSRect(x: track.minX, y: 8, width: track.width, height: 2)
                drawFill(NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1), rect: line, fraction: ratio)
                if ratio > 0 {
                    NSColor.black.setFill()
                    let center = track.minX + 3 + (track.width - 6) * ratio
                    NSBezierPath(ovalIn: NSRect(x: center - 3, y: 6, width: 6, height: 6)).fill()
                }
            case .dots:
                let count = 12
                let diameter: CGFloat = 3.5
                let gap = (track.width - CGFloat(count) * diameter) / CGFloat(count - 1)
                for index in 0..<count {
                    let rect = NSRect(x: track.minX + CGFloat(index) * (diameter + gap), y: 7.25, width: diameter, height: diameter)
                    drawFill(NSBezierPath(ovalIn: rect), rect: rect,
                             fraction: min(1, max(0, ratio * Double(count) - Double(index))))
                }
            }
            let symbol: String
            switch state {
            case .idle: symbol = "play"
            case .running: symbol = "circle.dotted"
            case .paused: symbol = "pause.fill"
            case .completed: symbol = "checkmark"
            }
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            if let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                mark.draw(in: NSRect(x: 3, y: 3, width: 12, height: 12))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawFill(_ path: NSBezierPath, rect: NSRect, fraction: Double) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        path.fill()
        guard fraction > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.black.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
