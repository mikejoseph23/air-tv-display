// SPDX-License-Identifier: MIT
import AppKit

/// Toggleable perf overlay: fps, decode ms/frame, dropped frames, queue depth, and the
/// receiver-side latency (buffer arrival -> decoded -> on screen, p50/p95/max, M8). Refreshes
/// twice a second while visible. Toggle with "h" in the receiver window, or start it on
/// with `--hud` / `AIRTV_HUD=1`.
final class VideoHUD {
    let view: NSTextField
    private let stats: VideoStats
    private var timer: Timer?

    init(stats: VideoStats) {
        self.stats = stats
        view = NSTextField(labelWithString: "")
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.textColor = .systemGreen
        view.drawsBackground = true
        view.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
    }

    var isVisible: Bool { !view.isHidden }

    func setVisible(_ on: Bool) {
        view.isHidden = !on
        timer?.invalidate(); timer = nil
        guard on else { return }
        _ = stats.windowed()   // start a fresh window
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func toggle() { setVisible(!isVisible) }

    private func refresh() {
        let s = stats.windowed()
        let hw = s.hardware.map { $0 ? "hardware" : "SOFTWARE" } ?? "-"
        view.stringValue = String(format: " %dx%d  %@ decode \n %.1f fps   decode %.2f ms (max %.2f) \n dropped: decode %d  present %d \n queue %d (max %d)   frames %d \n",
                                  s.width, s.height, hw, s.fps, s.decodeMsAvg, s.decodeMsMax,
                                  s.decodeDropped, s.presentDropped, s.queueDepth, s.maxQueueDepth, s.presented)
            + " arrival->decoded \(s.arrivalToDecoded.line) \n arrival->on screen \(s.arrivalToPresented.line) \n"
    }
}
