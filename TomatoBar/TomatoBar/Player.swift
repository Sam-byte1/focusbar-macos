import AppKit

// No bundled third-party audio: local previews use a macOS-provided sound.
@MainActor
final class TBPlayer {
    func playDing() {
        NSSound(named: "Glass")?.play()
    }
}
