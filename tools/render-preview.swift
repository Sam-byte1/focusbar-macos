import AppKit
import SwiftUI

@main
struct RenderPreview {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            appearance.performAsCurrentDrawingAppearance {
                let size = NSSize(width: 480, height: 180)
                let image = NSImage(size: size, flipped: false) { _ in
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: .zero, size: size).fill()
                    let samples: [(Double, TBFocusState, String)] = [(0, .idle, "准备开始"), (0.25, .running, "25%"), (0.5, .paused, "已暂停 · 50%"), (1, .completed, "已完成 · 100%")]
                    for (index, sample) in samples.enumerated() {
                        let y = CGFloat(130 - index * 34)
                        let progress = TBProgressImage.make(progress: sample.0, state: sample.1)
                        let rect = NSRect(x: 28, y: y, width: 104, height: 18)
                        progress.lockFocus()
                        NSColor.labelColor.setFill()
                        NSRect(origin: .zero, size: progress.size).fill(using: .sourceIn)
                        progress.unlockFocus()
                        progress.isTemplate = false
                        progress.draw(in: rect)
                        (sample.2 as NSString).draw(at: NSPoint(x: 160, y: y + 1), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
                    }
                    return true
                }
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: output.appendingPathComponent("progress-\(name).png"))
                }
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FocusBar-preview-\(UUID().uuidString)")
            let store = FocusStore(directory: temp)
            let timer = TBTimer(store: store)
            timer.suppressAlerts = true
            let view = TBPopoverView(timer: timer, store: store, openWindow: {}).environment(\.colorScheme, name == "dark" ? .dark : .light)
            let renderer = ImageRenderer(content: view.padding(0).background(Color(nsColor: name == "dark" ? NSColor(calibratedWhite: 0.12, alpha: 1) : .windowBackgroundColor)))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("panel-\(name).png"))
            }
            timer.shutdown()
        }
    }
}
