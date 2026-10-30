import Foundation
import QuartzCore

/// Thread-safe counters for the video path, read by the perf HUD and the fixture report.
/// Written from UxPlay's mirror thread (submit), VideoToolbox's output thread (decode) and
/// the render queue (present).
final class VideoStats {
    struct Snapshot {
        var received = 0
        var decoded = 0
        var presented = 0
        /// Decoder-side losses: no parameter sets yet, decode errors, VT-dropped frames.
        var decodeDropped = 0
        var decodeErrors = 0
        /// Present-side losses: a newer frame replaced one that was never drawn.
        var presentDropped = 0
        var formatChanges = 0
        var sessionsCreated = 0
        var width = 0
        var height = 0
        var hardware: Bool?
        var queueDepth = 0
        var maxQueueDepth = 0
        var decodeMsAvg = 0.0
        var decodeMsMax = 0.0
        /// Over the last HUD window (`windowed()`), or whole run for `total()`.
        var fps = 0.0
        var seconds = 0.0

        var line: String {
            let hw = hardware.map { $0 ? "HW" : "SW" } ?? "-"
            return String(format: "%dx%d %@  %.1f fps  decode %.2f ms (max %.2f)  drops dec %d / present %d  queue %d (max %d)  frames %d/%d/%d  fmt %d",
                          width, height, hw, fps, decodeMsAvg, decodeMsMax, decodeDropped, presentDropped,
                          queueDepth, maxQueueDepth, received, decoded, presented, formatChanges)
        }
    }

    private let lock = NSLock()
    private var s = Snapshot()
    private var startTime: CFTimeInterval?
    private var decodeMsSum = 0.0
    // HUD window
    private var winStart: CFTimeInterval = CACurrentMediaTime()
    private var winPresented = 0
    private var winDecodeMsSum = 0.0
    private var winDecoded = 0
    private var winDecodeMax = 0.0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        s = Snapshot(); startTime = nil; decodeMsSum = 0
        winStart = CACurrentMediaTime(); winPresented = 0; winDecodeMsSum = 0; winDecoded = 0; winDecodeMax = 0
    }

    func received() { lock.lock(); s.received += 1; if startTime == nil { startTime = CACurrentMediaTime() }; lock.unlock() }
    func decodeDropped(error: Bool) {
        lock.lock(); s.decodeDropped += 1; if error { s.decodeErrors += 1 }; lock.unlock()
    }
    func decoded(ms: Double, width: Int, height: Int) {
        lock.lock()
        s.decoded += 1; decodeMsSum += ms; s.decodeMsMax = max(s.decodeMsMax, ms)
        winDecoded += 1; winDecodeMsSum += ms; winDecodeMax = max(winDecodeMax, ms)
        s.width = width; s.height = height
        lock.unlock()
    }
    func presented() { lock.lock(); s.presented += 1; winPresented += 1; lock.unlock() }
    func presentDropped() { lock.lock(); s.presentDropped += 1; lock.unlock() }
    func queueDepth(_ d: Int) { lock.lock(); s.queueDepth = d; s.maxQueueDepth = max(s.maxQueueDepth, d); lock.unlock() }
    func formatChanged() { lock.lock(); s.formatChanges += 1; lock.unlock() }
    func sessionCreated(hardware: Bool) { lock.lock(); s.sessionsCreated += 1; s.hardware = hardware; lock.unlock() }

    /// Whole-run figures (fps = presented / elapsed since the first received frame).
    func total(now: CFTimeInterval = CACurrentMediaTime()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var out = s
        out.decodeMsAvg = s.decoded > 0 ? decodeMsSum / Double(s.decoded) : 0
        out.seconds = startTime.map { now - $0 } ?? 0
        out.fps = out.seconds > 0 ? Double(s.presented) / out.seconds : 0
        return out
    }

    /// Figures since the previous call (HUD), then starts a new window.
    func windowed(now: CFTimeInterval = CACurrentMediaTime()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var out = s
        let dt = now - winStart
        out.seconds = dt
        out.fps = dt > 0 ? Double(winPresented) / dt : 0
        out.decodeMsAvg = winDecoded > 0 ? winDecodeMsSum / Double(winDecoded) : 0
        out.decodeMsMax = winDecodeMax
        winStart = now; winPresented = 0; winDecodeMsSum = 0; winDecoded = 0; winDecodeMax = 0
        return out
    }
}

/// Single-slot "latest frame wins" hand-off between the decoder and the renderer. Putting a
/// frame while one is still waiting replaces it (the old one is a late frame and is dropped),
/// so the pending queue never exceeds one frame.
struct FrameMailbox<T> {
    private(set) var pending: T?
    private(set) var dropped = 0

    /// Returns true when an undrawn frame was replaced.
    @discardableResult
    mutating func put(_ frame: T) -> Bool {
        let replaced = pending != nil
        if replaced { dropped += 1 }
        pending = frame
        return replaced
    }

    mutating func take() -> T? { defer { pending = nil }; return pending }
    mutating func clear() { pending = nil }
}
