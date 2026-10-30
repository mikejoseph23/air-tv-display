import XCTest

final class AudioTimingTests: XCTestCase {
    // MARK: volume (matches uxplay.cpp audio_set_volume, default -db -30:0, flat)

    func testVolumeEndpoints() {
        XCTAssertEqual(AudioVolume.gain(airPlayDB: 0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(AudioVolume.gain(airPlayDB: -30), 0)
        XCTAssertEqual(AudioVolume.gain(airPlayDB: -144), 0, "mute signal")
    }

    func testVolumeMidpointAndClamping() {
        // -15 dB -> slider 50% -> db_flat -15 -> 10^(-15/20)
        XCTAssertEqual(AudioVolume.gain(airPlayDB: -15), Float(pow(10, -0.75)), accuracy: 1e-5)
        XCTAssertEqual(AudioVolume.gain(airPlayDB: -50), 0, "below range -> silent")
        XCTAssertEqual(AudioVolume.gain(airPlayDB: 5), 1.0, accuracy: 1e-6, "above range -> full")
    }

    func testVolumeTaperAndDbRange() {
        // tapered: db = max(0 + 10*log2(frac), flat). frac 0.5 -> -10 dB (flat would be -15 dB)
        XCTAssertEqual(AudioVolume.gain(airPlayDB: -15, taper: true), Float(pow(10, -0.5)), accuracy: 1e-5)
        // -db 60: flat range -60:0, frac 0.5 -> -30 dB
        XCTAssertEqual(AudioVolume.gain(airPlayDB: -15, dbLow: -60), Float(pow(10, -1.5)), accuracy: 1e-5)
    }

    func testStoredVolume() {
        XCTAssertEqual(AudioVolume.stored(-144), -144)
        XCTAssertEqual(AudioVolume.stored(-99), -30)
        XCTAssertEqual(AudioVolume.stored(3), 0)
        XCTAssertEqual(AudioVolume.stored(-12.5), -12.5)
    }

    // MARK: clock

    func testNTPLocalToHost() {
        let real: UInt64 = 1_800_000_000_000_000_000, host: UInt64 = 5_000_000_000
        XCTAssertEqual(AudioClock.hostNanos(forNTPLocal: real + 250_000_000, realtimeNow: real, hostNow: host), 5_250_000_000)
        XCTAssertEqual(AudioClock.hostNanos(forNTPLocal: real - 1_000_000_000, realtimeNow: real, hostNow: host), 4_000_000_000)
        XCTAssertNil(AudioClock.hostNanos(forNTPLocal: 0, realtimeNow: real, hostNow: host), "0 = NTP not synced yet")
    }

    // MARK: scheduler

    private let ms: UInt64 = 1_000_000
    private let spf = 480   // 10.88 ms

    func testOnTimeStreamAppendsContiguously() {
        var s = AudioScheduler()
        let now: UInt64 = 10_000 * ms
        var t = now + 200 * ms
        XCTAssertEqual(s.plan(targetHostNanos: t, frames: spf, now: now), .start(atHostNanos: t))
        XCTAssertEqual(s.shiftNanos, 0)
        for _ in 0..<50 {
            t += UInt64(AudioScheduler.nanos(forFrames: Int64(spf)))
            XCTAssertEqual(s.plan(targetHostNanos: t + 3 * ms, frames: spf, now: now), .append, "3 ms jitter absorbed")
        }
    }

    func testLateFirstPacketShiftsTimelineAndStaysAligned() {
        var s = AudioScheduler()
        let now: UInt64 = 10_000 * ms
        let t = now - 500 * ms   // already 500 ms late
        XCTAssertEqual(s.plan(targetHostNanos: t, frames: spf, now: now), .start(atHostNanos: now + 40 * ms))
        XCTAssertEqual(s.shiftNanos, 540 * Int64(ms))
        let t2 = t + UInt64(AudioScheduler.nanos(forFrames: Int64(spf)))
        XCTAssertEqual(s.plan(targetHostNanos: t2, frames: spf, now: now), .append, "same shift applies to later packets")
    }

    func testGapIsFilledWithSilenceAndOverlapDropped() {
        var s = AudioScheduler()
        let now: UInt64 = 10_000 * ms
        let t = now + 200 * ms
        _ = s.plan(targetHostNanos: t, frames: spf, now: now)
        let dur = UInt64(AudioScheduler.nanos(forFrames: Int64(spf)))
        // 100 ms hole (lost packets)
        let a = s.plan(targetHostNanos: t + dur + 100 * ms, frames: spf, now: now)
        guard case .padSilence(let n) = a else { return XCTFail("\(a)") }
        XCTAssertEqual(Double(n), 0.1 * 44100, accuracy: 2)
        // duplicate / early packet 100 ms behind the queue
        XCTAssertEqual(s.plan(targetHostNanos: t, frames: spf, now: now), .drop)
    }

    func testBigJumpAndUnderrunRestart() {
        var s = AudioScheduler()
        var now: UInt64 = 10_000 * ms
        let t = now + 200 * ms
        _ = s.plan(targetHostNanos: t, frames: spf, now: now)
        // sender clock jumps 2 s ahead
        let a = s.plan(targetHostNanos: t + 2000 * ms, frames: spf, now: now)
        XCTAssertEqual(a, .start(atHostNanos: t + 2000 * ms))
        // underrun: the player ran dry long ago
        now += 5000 * ms
        XCTAssertEqual(s.plan(targetHostNanos: nil, frames: spf, now: now), .start(atHostNanos: now + 40 * ms))
    }

    func testUnsyncedClockStartsAsapAndAppends() {
        var s = AudioScheduler()
        let now: UInt64 = 10_000 * ms
        XCTAssertEqual(s.plan(targetHostNanos: nil, frames: spf, now: now), .start(atHostNanos: now + 40 * ms))
        XCTAssertEqual(s.plan(targetHostNanos: nil, frames: spf, now: now), .append)
        s.reset()
        XCTAssertFalse(s.isStarted)
    }

    func testImplausiblyFarTargetIsNotTrusted() {
        var s = AudioScheduler()
        let now: UInt64 = 10_000 * ms
        XCTAssertEqual(s.plan(targetHostNanos: now + 60_000 * ms, frames: spf, now: now), .start(atHostNanos: now + 40 * ms))
    }
}
