import AppKit

@main
struct RenderStyles {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks = 0
        for style in MenuBarStyle.allCases {
            for width in [60.0, 76, 140, .nan] {
                for ratio in [0.0, 0.001, 0.25, 0.5, 0.99, 1, -1, 2, .nan, .infinity] {
                    for state in [TBFocusState.idle, .running, .paused, .completed] {
                        let image = TBProgressImage.make(progress: ratio, state: state, width: width, style: style)
                        precondition(image.isTemplate && image.size.height == 18)
                        precondition(image.size.width == (width.isFinite ? width : 76) + 28)
                        precondition(image.tiffRepresentation != nil)
                        checks += 1
                    }
                }
            }
        }
        for dark in [false, true] {
            let image = NSImage(size: NSSize(width: 800, height: 270), flipped: false) { rect in
                (dark ? NSColor(calibratedWhite: 0.11, alpha: 1) : .white).setFill()
                rect.fill()
                let ink = dark ? NSColor(calibratedWhite: 0.9, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1)
                let font = NSFont.systemFont(ofSize: 12)
                for (index, value) in ["0%", "25%", "56%", "100%"].enumerated() {
                    (value as NSString).draw(at: NSPoint(x: 236 + index * 137, y: 232), withAttributes: [.font: font, .foregroundColor: ink])
                }
                for (row, style) in MenuBarStyle.allCases.enumerated() {
                    let y = CGFloat(190 - row * 47)
                    (style.name as NSString).draw(at: NSPoint(x: 25, y: y + 3), withAttributes: [.font: font, .foregroundColor: ink])
                    for (column, ratio) in [0.0, 0.25, 0.56, 1].enumerated() {
                        let progress = TBProgressImage.make(progress: ratio, state: ratio == 1 ? .completed : .running, width: 90, style: style)
                        progress.lockFocus()
                        ink.setFill()
                        NSRect(origin: .zero, size: progress.size).fill(using: .sourceIn)
                        progress.unlockFocus()
                        progress.isTemplate = false
                        progress.draw(in: NSRect(x: CGFloat(207 + column * 137), y: y, width: 118, height: 18))
                    }
                }
                return true
            }
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("styles-\(dark ? "dark" : "light").png"))
        }
        print("\(checks) render checks passed")
    }
}
