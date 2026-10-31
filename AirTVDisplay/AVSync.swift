// SPDX-License-Identifier: MIT
import Foundation

/// A/V sync policy (M8): **video presents as soon as it is decoded; audio follows video.**
///
/// For an extend/mirror display the cursor and window latency matter more than lip sync, so
/// video is never held back. Both streams carry `ntp_time_local` on one shared timeline
/// (`AudioClock`), so "in sync" means both are played the same distance behind that timeline.
/// Video's distance is measured per presented frame (`videoLag` = on-screen host time minus the
/// frame's timeline time, smoothed); audio is then scheduled that far behind its own timeline,
/// less the output device latency so the sound leaves the speaker at the same moment.
///
/// No video (audio-only session) or no usable timestamps: the delay is 0, which is the M6
/// behaviour (audio on its own timeline).
///
/// Thread-safe: video presents arrive on the render queue, audio reads on the audio queue.
final class AVSync {
    /// Lag samples outside this window (ns) are treated as bogus timestamps and ignored.
    static let lagWindow: ClosedRange<Int64> = -1_000_000_000...1_000_000_000
    /// EMA weight of a new lag sample (~20-frame time constant: follows drift, ignores jitter).
    static let smoothing = 0.05

    private let lock = NSLock()
    private var lag: Double?
    private var samples = 0
    private var ignored = 0
    private var lagMin = Int64.max, lagMax = Int64.min
    private var lastOffset: Int64?
    private var offsetMin = Int64.max, offsetMax = Int64.min

    struct Report: Equatable {
        var videoLagMs: Double?
        var samples: Int
        var ignored: Int
        var lagMinMs: Double?
        var lagMaxMs: Double?
        /// Audio heard minus video seen, ms (+ = audio late). nil until audio has played.
        var lastOffsetMs: Double?
        var offsetMinMs: Double?
        var offsetMaxMs: Double?

        var line: String {
            func f(_ v: Double?) -> String { v.map { String(format: "%+.1f", $0) } ?? "-" }
            return "video lag \(f(videoLagMs)) ms (min \(f(lagMinMs)) max \(f(lagMaxMs)), \(samples) frames, \(ignored) ignored)"
                + "  A/V offset last \(f(lastOffsetMs)) ms (min \(f(offsetMinMs)) max \(f(offsetMaxMs)))"
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        lag = nil; samples = 0; ignored = 0; lagMin = .max; lagMax = .min
        lastOffset = nil; offsetMin = .max; offsetMax = .min
    }

    /// Video lag of one frame: host time it reached the screen minus its timeline time. nil when
    /// the frame has no timestamp (0 before UxPlay's first NTP exchange).
    static func lagSample(ntpLocal: UInt64, presentedHostNanos: UInt64,
                          realtimeNow: UInt64 = AudioClock.realtimeNanosNow(),
                          hostNow: UInt64 = AudioClock.hostNanosNow()) -> Int64? {
        guard let due = AudioClock.hostNanos(forNTPLocal: ntpLocal, realtimeNow: realtimeNow, hostNow: hostNow) else { return nil }
        return Int64(bitPattern: presentedHostNanos &- due)
    }

    /// Render queue: a frame with timeline time `ntpLocal` went on screen at `presentedHostNanos`.
    func videoPresented(ntpLocal: UInt64, presentedHostNanos: UInt64,
                        realtimeNow: UInt64 = AudioClock.realtimeNanosNow(),
                        hostNow: UInt64 = AudioClock.hostNanosNow()) {
        guard let s = Self.lagSample(ntpLocal: ntpLocal, presentedHostNanos: presentedHostNanos,
                                     realtimeNow: realtimeNow, hostNow: hostNow) else { return }
        addLag(s)
    }

    /// One measured lag (ns). Internal so tests can drive it with synthetic values.
    func addLag(_ s: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard Self.lagWindow.contains(s) else { ignored += 1; return }
        samples += 1
        lagMin = min(lagMin, s); lagMax = max(lagMax, s)
        if let l = lag { lag = l + Self.smoothing * (Double(s) - l) } else { lag = Double(s) }
    }

    /// Smoothed video lag (ns), nil until a frame with a timestamp has been presented.
    var videoLagNanos: Int64? { lock.lock(); defer { lock.unlock() }; return lag.map { Int64($0) } }

    /// How far behind its timeline audio should be scheduled (ns) so it is heard with the video.
    /// The output latency is subtracted: the scheduler places samples into the player, and the
    /// device adds `outputLatency` before they are audible.
    func audioDelayNanos(outputLatencyNanos: Int64) -> Int64 {
        guard let l = videoLagNanos else { return 0 }
        return l - outputLatencyNanos
    }

    /// The A/V offset of one audio packet as actually scheduled: it is heard at `placed + out`;
    /// its video (same timeline time `timeline`) is seen at `timeline + videoLag`. Includes the
    /// scheduler's late-start shift and jitter tolerance. Records it for the session report and
    /// returns it (ns, + = audio late). nil before any video frame was measured.
    @discardableResult
    func recordAudio(placedHostNanos placed: Int64, timelineHostNanos timeline: Int64, outputLatencyNanos out: Int64) -> Int64? {
        guard let l = videoLagNanos else { return nil }
        let off = placed + out - (timeline + l)
        lock.lock(); lastOffset = off; offsetMin = min(offsetMin, off); offsetMax = max(offsetMax, off); lock.unlock()
        return off
    }

    func report() -> Report {
        lock.lock(); defer { lock.unlock() }
        func ms(_ v: Int64) -> Double { Double(v) / 1e6 }
        return Report(videoLagMs: lag.map { $0 / 1e6 }, samples: samples, ignored: ignored,
                      lagMinMs: samples > 0 ? ms(lagMin) : nil, lagMaxMs: samples > 0 ? ms(lagMax) : nil,
                      lastOffsetMs: lastOffset.map(ms),
                      offsetMinMs: lastOffset == nil ? nil : ms(offsetMin), offsetMaxMs: lastOffset == nil ? nil : ms(offsetMax))
    }
}
