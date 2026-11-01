import AppKit

// Original vector artwork. No fonts, third-party images or compiled asset catalog.
@main
struct RenderIcon {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = output.appendingPathComponent("FocusBar.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let data = try render(pixels: pixels, markOnly: false)
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try data.write(to: iconset.appendingPathComponent(name))
            }
        }
        try render(pixels: 1024, markOnly: false).write(to: output.appendingPathComponent("FocusBar.png"))
        try render(pixels: 256, markOnly: true).write(to: output.appendingPathComponent("FocusBarMark.png"))
    }

    @MainActor
    static func render(pixels: Int, markOnly: Bool) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.setAllowsAntialiasing(true)
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        if !markOnly {
            let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 25
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 184, yRadius: 184).fill()
            NSGraphicsContext.restoreGraphicsState()
            let path = NSBezierPath(roundedRect: tile, xRadius: 184, yRadius: 184)
            NSGradient(starting: NSColor(calibratedWhite: 0.22, alpha: 1), ending: NSColor(calibratedWhite: 0.075, alpha: 1))!.draw(in: path, angle: -90)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        let track = NSRect(x: 244, y: 449, width: 536, height: 126)
        let shape = NSBezierPath(roundedRect: track, xRadius: 63, yRadius: 63)
        (markOnly ? NSColor.black.withAlphaComponent(0.22) : NSColor(calibratedWhite: 0.36, alpha: 1)).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (markOnly ? NSColor.black : NSColor(calibratedRed: 0.97, green: 0.965, blue: 0.94, alpha: 1)).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: 360, height: track.height), xRadius: 63, yRadius: 63).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
}
