import XCTest

/// M8: video-first A/V sync with synthetic timestamps. Video presents ASAP; audio is scheduled
/// as far behind the shared timeline as video is measured to be (less output latency).
final class AVSyncTests: XCTestCase {
    let ms: Int64 = 1_000_000

    func testLagSampleFromTimelineAndPresentTime() {
        // Wall clock 1_000 s, host clock 50 s. A frame due at wall 1_000.010 s is host 50.010 s.
        let rt: UInt64 = 1_000_000_000_000, host: UInt64 = 50_000_000_000
        let due = rt + 10_000_000
        XCTAssertEqual(AVSync.lagSample(ntpLocal: due, presentedHostNanos: host + 90_000_000, realtimeNow: rt, hostNow: host), 80 * ms)
        // Presented before its timeline time: negative lag is kept (audio then plays earlier too).
        XCTAssertEqual(AVSync.lagSample(ntpLocal: due, presentedHostNanos: host, realtimeNow: rt, hostNow: host), -10 * ms)
        XCTAssertNil(AVSync.lagSample(ntpLocal: 0, presentedHostNanos: host, realtimeNow: rt, hostNow: host), "no NTP yet")
    }

    func testSmoothingIgnoresBogusAndJitter() {
        let s = AVSync()
        XCTAssertNil(s.videoLagNanos)
        XCTAssertEqual(s.audioDelayNanos(outputLatencyNanos: 10 * ms), 0, "no video: audio on its own timeline")
        for i in 0..<400 { s.addLag((i % 2 == 0 ? 75 : 85) * ms) }   // +/-5 ms jitter around 80
        s.addLag(5_000 * ms)    // bogus timestamp
        s.addLag(-3_000 * ms)
        let lag = Double(s.videoLagNanos!) / 1e6
        XCTAssertEqual(lag, 80, accuracy: 3)
        let r = s.report()
        XCTAssertEqual(r.samples, 400)
        XCTAssertEqual(r.ignored, 2)
        XCTAssertEqual(r.lagMinMs, 75)
        XCTAssertEqual(r.lagMaxMs, 85)
        XCTAssertEqual(Double(s.audioDelayNanos(outputLatencyNanos: 12 * ms)) / 1e6, lag - 12, accuracy: 0.01)
        s.reset()
        XCTAssertNil(s.videoLagNanos)
        XCTAssertEqual(s.report().samples, 0)
    }

    /// Simulation: 30 fps video presented 80 ms behind the timeline, AAC-ELD audio packets
    /// (480 frames) arriving 20 ms ahead of their timeline time, output latency 15 ms. After
    /// wiring, audio is heard with the video (offset ~0); then the video lag steps to 140 ms
    /// (e.g. Wi-Fi) and audio follows it with one silence pad.
    func testAudioFollowsVideoLagThroughTheScheduler() {
        let sync = AVSync()
        var sched = AudioScheduler()
        let outLatency = 15 * ms
        let frames = 480
        let pktNanos = AudioScheduler.nanos(forFrames: Int64(frames))
        let t0: Int64 = 10_000_000_000   // host ns; the timeline is the host clock here
        var videoLag = 80 * ms
        var nextVideo = t0
        var actions: [AudioScheduler.Action] = []
        var offsets: [Int64] = []

        for k in 0..<1500 {   // ~16 s of audio
            let due = t0 + Int64(k) * pktNanos
            let now = due - 20 * ms
            if k == 750 { videoLag = 140 * ms }
            // Video frames that are on screen by `now`.
            while nextVideo + videoLag <= now {
                sync.addLag(videoLag)
                nextVideo += 33_333_333
            }
            let delay = sync.audioDelayNanos(outputLatencyNanos: outLatency)
            let a = sched.plan(targetHostNanos: UInt64(due + delay), frames: frames, now: UInt64(now))
            actions.append(a)
            if let placed = sched.lastPlacedHostNanos,
               let off = sync.recordAudio(placedHostNanos: placed, timelineHostNanos: due, outputLatencyNanos: outLatency) {
                offsets.append(off)
            }
        }
        // Heard time of packet k = scheduled host time + output latency; seen time of its video
        // = timeline + lag. Check directly from the scheduler, not only the reported offset.
        let heard = sched.nextHostNanos! - pktNanos + outLatency
        let lastDue = t0 + 1499 * pktNanos
        XCTAssertEqual(Double(heard - (lastDue + videoLag)) / 1e6, 0, accuracy: 26, "audio heard with its video")
        // Steady state before the step: on target (the startup lateness was absorbed).
        XCTAssertEqual(Double(offsets[700]) / 1e6, 0, accuracy: 3)
        XCTAssertEqual(sched.shiftNanos, 0, "late-start shift shrunk once the A/V delay made room")
        // After the step settles: within the scheduler's 25 ms jitter tolerance.
        XCTAssertTrue(offsets[(offsets.count - 400)...].allSatisfy { abs($0) <= 26 * ms },
                      "max |offset| \(offsets[(offsets.count - 400)...].map { abs($0) }.max()! / ms) ms")
        let pads = actions[750...].filter { if case .padSilence = $0 { return true }; return false }.count
        let restarts = actions[750...].filter { if case .start = $0 { return true }; return false }.count
        XCTAssertGreaterThanOrEqual(pads, 1, "the 60 ms step is bridged with silence")
        XCTAssertEqual(restarts, 0, "no restart for a step below the resync threshold")
        let r = sync.report()
        XCTAssertNotNil(r.lastOffsetMs)
        XCTAssertTrue(r.line.contains("A/V offset"))
    }

    /// Late first audio (scheduler shift) is reported as a positive offset rather than hidden.
    func testOffsetIncludesLateStartShift() {
        let sync = AVSync()
        sync.addLag(20 * ms)
        var sched = AudioScheduler()
        let now: Int64 = 5_000_000_000
        let delay = sync.audioDelayNanos(outputLatencyNanos: 10 * ms)   // 10 ms
        // Packet due 100 ms ago: starts at now + minLead, shift = 140 + 10 ms.
        let due = now - 100 * ms
        XCTAssertEqual(sched.plan(targetHostNanos: UInt64(due + delay), frames: 480, now: UInt64(now)),
                       .start(atHostNanos: UInt64(now + 40 * ms)))
        let off = sync.recordAudio(placedHostNanos: sched.lastPlacedHostNanos!, timelineHostNanos: due, outputLatencyNanos: 10 * ms)!
        XCTAssertEqual(off, 130 * ms, "heard at now+50 ms, video seen at due+20 = now-80 ms")
        XCTAssertEqual(sync.report().lastOffsetMs, 130)
    }

    func testServerWiresSyncIntoAudioAndVideoSink() {
        let s = RaopServer()
        XCTAssertTrue(s.audio.avSync === s.avSync)
        let p = VideoPipeline(render: false)
        s.videoSink = p
        XCTAssertTrue(p.avSync === s.avSync)
        // A sink that does not care about sync still conforms (protocol defaults).
        final class Plain: VideoSink {
            var n = 0
            func videoSessionBegan() {}
            func videoAccessUnit(_ p: UnsafePointer<UInt8>, _ len: Int) { n += 1 }
            func videoSessionEnded() {}
        }
        let plain = Plain()
        s.videoSink = plain
        let au: [UInt8] = [0, 0, 0, 1, 0x65, 0x88]
        au.withUnsafeBufferPointer { s.handleVideo($0.baseAddress!, $0.count, nalCount: 1, h265: false, ntpLocal: 123) }
        XCTAssertEqual(plain.n, 1, "ntp-carrying call falls back to the 2-argument form")
    }
}
