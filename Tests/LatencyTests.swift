import VideoToolbox
import XCTest

/// M8: receiver-side latency instrumentation (arrival -> decoded -> presented) and the tuned
/// defaults (decode flags, vsync).
final class LatencyTests: XCTestCase {
    func testLatencyRingPercentiles() {
        var r = LatencyRing()
        XCTAssertEqual(r.summary().count, 0)
        for v in 1...100 { r.add(Double(v)) }
        r.add(.nan); r.add(-1)   // ignored
        let s = r.summary()
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.avg, 50.5, accuracy: 1e-9)
        XCTAssertEqual(s.p50, 51, accuracy: 1)
        XCTAssertEqual(s.p95, 95, accuracy: 1)
        XCTAssertEqual(s.max, 100)
        // Bounded: only the newest `capacity` samples are kept.
        for _ in 0..<LatencyRing.capacity { r.add(5) }
        XCTAssertEqual(r.summary().count, LatencyRing.capacity)
        XCTAssertEqual(r.summary().max, 5)
    }

    func testStatsCarryLatencyAndResetClearsIt() {
        let st = VideoStats()
        st.decodeLatency(ms: 2)
        st.presentLatency(ms: 8, onGlass: true)
        st.presentLatency(ms: 9, onGlass: false)
        let t = st.total()
        XCTAssertEqual(t.arrivalToDecoded.p50, 2)
        XCTAssertEqual(t.arrivalToPresented.count, 2)
        XCTAssertEqual(t.presentsOnGlass, 1)
        XCTAssertEqual(t.presentsGPUTimed, 1)
        XCTAssertTrue(t.line.contains("latency decode"))
        XCTAssertEqual(st.windowed().arrivalToPresented.count, 2, "HUD shows the rolling figures")
        st.reset()
        XCTAssertEqual(st.total().arrivalToPresented.count, 0)
    }

    func testTunedDefaults() {
        let d = VideoDecoder(stats: VideoStats(), mode: nil)
        if ProcessInfo.processInfo.environment["AIRTV_DECODE"] == nil {
            XCTAssertEqual(d.mode, .async, "M8 default: no 1x-real-time pacing hint")
        }
        XCTAssertEqual(VideoDecoder(stats: VideoStats(), mode: .async).decodeFlags, [._EnableAsynchronousDecompression])
        XCTAssertEqual(VideoDecoder(stats: VideoStats(), mode: .async1x).decodeFlags,
                       [._EnableAsynchronousDecompression, ._1xRealTimePlayback])
        XCTAssertEqual(VideoDecoder(stats: VideoStats(), mode: .sync).decodeFlags, [])
        XCTAssertFalse(VideoRenderer.vsyncDefault(env: nil), "M8 default: vsync off")
        XCTAssertFalse(VideoRenderer.vsyncDefault(env: "0"))
        XCTAssertTrue(VideoRenderer.vsyncDefault(env: "1"))
    }

    /// Every decode mode produces every frame and records arrival -> decoded for each.
    func testDecodeLatencyRecordedInEveryMode() throws {
        let units = try RobustnessTests.units("synthetic-1080p.h264")
        for mode in [VideoDecoder.Mode.async, .async1x, .sync] {
            let st = VideoStats()
            let d = VideoDecoder(stats: st, mode: mode)
            let lock = NSLock()
            var timings: [FrameTiming] = []
            d.onTimedFrame = { _, t in lock.lock(); timings.append(t); lock.unlock() }
            for (i, u) in units.enumerated() {
                u.withUnsafeBytes {
                    d.decode($0.bindMemory(to: UInt8.self).baseAddress!, $0.count,
                             timing: FrameTiming(arrival: CACurrentMediaTime(), ntpLocal: UInt64(i + 1)))
                }
            }
            d.waitForFrames()
            let s = st.total()
            XCTAssertEqual(s.decoded, units.count, "\(mode)")
            XCTAssertEqual(s.arrivalToDecoded.count, units.count, "\(mode)")
            XCTAssertLessThan(s.arrivalToDecoded.p50, 33, "\(mode): decode keeps up with 30 fps")
            lock.lock()
            XCTAssertEqual(timings.map(\.ntpLocal), (1...UInt64(units.count)).map { $0 }, "\(mode): timestamps follow their frame, in order")
            XCTAssertTrue(timings.allSatisfy { $0.decoded >= $0.arrival })
            lock.unlock()
        }
    }

    /// Off-screen layer: present latency is still recorded (GPU-completion timed when the
    /// compositor reports no on-glass time), and the A/V hook sees every timed present.
    func testPresentLatencyAndAVHookOffscreen() throws {
        let pipeline = VideoPipeline()
        let r = try XCTUnwrap(pipeline.renderer, "no Metal device")
        r.layer.drawableSize = CGSize(width: 1920, height: 1080)
        let sync = AVSync()
        pipeline.attach(avSync: sync)
        let units = try RobustnessTests.units("synthetic-1080p.h264")
        pipeline.videoSessionBegan()
        for u in units.prefix(30) {
            let ntp = AudioClock.realtimeNanosNow()   // "due now": lag = receiver latency
            u.withUnsafeBytes { pipeline.videoAccessUnit($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, ntpLocal: ntp) }
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        pipeline.decoder.waitForFrames()
        r.flush()
        Thread.sleep(forTimeInterval: 0.2)   // GPU-timed fallback fires 50 ms after completion
        let s = pipeline.stats.total()
        XCTAssertEqual(s.arrivalToPresented.count, s.presented)
        XCTAssertEqual(s.presentsOnGlass + s.presentsGPUTimed, s.presented)
        XCTAssertGreaterThan(s.presented, 0)
        XCTAssertGreaterThanOrEqual(s.arrivalToPresented.p50, s.arrivalToDecoded.p50)
        XCTAssertLessThan(s.arrivalToPresented.p50, 100)
        let rep = sync.report()
        XCTAssertEqual(rep.samples, s.presented)
        XCTAssertEqual(try XCTUnwrap(rep.videoLagMs), s.arrivalToPresented.avg, accuracy: 30,
                       "lag on a due-now timeline equals the receiver's own latency")
    }
}
