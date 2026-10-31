// SPDX-License-Identifier: MIT
import CoreVideo
import Foundation
import QuartzCore

/// What `RaopServer` feeds decrypted mirror video into. Called on UxPlay's mirror thread.
protocol VideoSink: AnyObject {
    func videoSessionBegan()
    /// One decrypted Annex-B access unit; the buffer is only valid during the call.
    func videoAccessUnit(_ p: UnsafePointer<UInt8>, _ len: Int)
    func videoSessionEnded()
    /// Same, with the frame's `ntp_time_local` (A/V sync). Defaults to the 2-argument form.
    func videoAccessUnit(_ p: UnsafePointer<UInt8>, _ len: Int, ntpLocal: UInt64)
    /// The server's A/V sync state; the sink reports presented frames into it. Default: ignored.
    func attach(avSync: AVSync?)
}

extension VideoSink {
    func videoAccessUnit(_ p: UnsafePointer<UInt8>, _ len: Int, ntpLocal: UInt64) { videoAccessUnit(p, len) }
    func attach(avSync: AVSync?) {}
}

/// Decode -> present: `VideoDecoder` into `VideoRenderer`, sharing one `VideoStats`.
/// The renderer is optional so the decoder can run headless (tests without a GPU surface).
final class VideoPipeline: VideoSink {
    let stats = VideoStats()
    let decoder: VideoDecoder
    let renderer: VideoRenderer?

    init(requireHardware: Bool = true, render: Bool = true) {
        decoder = VideoDecoder(stats: stats, requireHardware: requireHardware)
        renderer = render ? VideoRenderer(stats: stats) : nil
        decoder.onLog = { RtspLog.shared.log(.info, $0) }
        decoder.onTimedFrame = { [weak self] pb, t in self?.renderer?.enqueue(pb, timing: t) }
        renderer?.onPresented = { [weak self] t, at in
            guard t.ntpLocal != 0, let sync = self?.avSync else { return }
            sync.videoPresented(ntpLocal: t.ntpLocal, presentedHostNanos: UInt64(max(0, at) * 1e9))
        }
    }

    private let syncLock = NSLock()
    private var _avSync: AVSync?
    var avSync: AVSync? { syncLock.lock(); defer { syncLock.unlock() }; return _avSync }
    func attach(avSync: AVSync?) { syncLock.lock(); _avSync = avSync; syncLock.unlock() }

    func videoSessionBegan() {
        decoder.reset()
        stats.reset()
    }

    func videoAccessUnit(_ p: UnsafePointer<UInt8>, _ len: Int) { videoAccessUnit(p, len, ntpLocal: 0) }

    func videoAccessUnit(_ p: UnsafePointer<UInt8>, _ len: Int, ntpLocal: UInt64) {
        decoder.decode(p, len, timing: FrameTiming(arrival: CACurrentMediaTime(), ntpLocal: ntpLocal))
    }

    func videoSessionEnded() {
        let s = stats.total()
        if s.received > 0 { RtspLog.shared.log(.info, "[video] session end: " + s.line) }
        decoder.reset()
        renderer?.clear()
    }

    /// Main-thread disconnect path (connection reset/closed with no mirror teardown).
    func clearScreen() { renderer?.clear() }
}

/// `--play-fixture <file>`: feeds a raw Annex-B file through the same pipeline at a fixed
/// frame rate (raw H.264 carries no timing), on its own thread, and reports the figures.
final class VideoFixturePlayer {
    struct Options {
        var fps: Double = 30
        var loops = 1
    }

    let units: [Data]
    let options: Options
    /// Fixture frames are stamped "due now" on the shared timeline, so the measured video lag
    /// is the receiver's own arrival -> present time.
    let avSync = AVSync()
    private let pipeline: VideoPipeline

    init(file: URL, pipeline: VideoPipeline, options: Options) throws {
        units = VideoFormat.accessUnits(fromAnnexB: try Data(contentsOf: file))
        self.pipeline = pipeline
        self.options = options
        pipeline.attach(avSync: avSync)
    }

    /// Plays to the end on a background thread, then calls `done` on the main queue with the
    /// whole-run stats and the wall time spent feeding.
    func play(done: @escaping (VideoStats.Snapshot, Double) -> Void) {
        let t = Thread { [self] in
            pipeline.videoSessionBegan()
            let interval = 1.0 / options.fps
            let start = CACurrentMediaTime()
            var i = 0
            for _ in 0..<options.loops {
                for u in units {
                    // Absolute deadlines: no drift from decode or feed time.
                    let deadline = start + Double(i) * interval
                    let wait = deadline - CACurrentMediaTime()
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                    let ntp = AudioClock.realtimeNanosNow()
                    u.withUnsafeBytes { pipeline.videoAccessUnit($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, ntpLocal: ntp) }
                    i += 1
                }
            }
            // Let the last frame decode and present before reporting.
            pipeline.decoder.waitForFrames()
            Thread.sleep(forTimeInterval: interval * 2)
            pipeline.renderer?.flush()
            let fed = CACurrentMediaTime() - start
            let snap = pipeline.stats.total()
            DispatchQueue.main.async { done(snap, fed) }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    static func report(_ s: VideoStats.Snapshot, fed: Double, units: Int, options: Options, gpu: String) -> String {
        let expected = units * options.loops
        return """
        [fixture] frames=\(expected) target=\(options.fps)fps fed_in=\(String(format: "%.2f", fed))s gpu="\(gpu)" hardware=\(s.hardware.map(String.init) ?? "unknown")
        [fixture] received=\(s.received) decoded=\(s.decoded) presented=\(s.presented) fps=\(String(format: "%.2f", s.fps))
        [fixture] decode_ms avg=\(String(format: "%.2f", s.decodeMsAvg)) max=\(String(format: "%.2f", s.decodeMsMax)) dropped_decode=\(s.decodeDropped) errors=\(s.decodeErrors) dropped_present=\(s.presentDropped) max_queue=\(s.maxQueueDepth)
        [fixture] latency arrival->decoded \(s.arrivalToDecoded.line)  arrival->presented \(s.arrivalToPresented.line) (on-glass \(s.presentsOnGlass), gpu-timed \(s.presentsGPUTimed))
        [fixture] size=\(s.width)x\(s.height) format_changes=\(s.formatChanges) sessions=\(s.sessionsCreated)
        """
    }
}
