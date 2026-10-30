import Foundation

/// Maps UxPlay's "local NTP" timestamps to the monotonic host clock.
///
/// `audio_decode_struct.ntp_time_local` and `video_decode_struct.ntp_time_local` are both
/// `CLOCK_REALTIME` nanoseconds (raop_ntp_get_local_time) at which the sender wants that
/// frame presented, already corrected by the NTP-sync offset. Audio and video therefore
/// share one timeline; this is the single conversion both paths should use.
enum AudioClock {
    /// Monotonic host time in nanoseconds (same base as `mach_absolute_time` on Apple Silicon
    /// and Intel after timebase conversion; `CLOCK_UPTIME_RAW`).
    static func hostNanosNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static func realtimeNanosNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }

    /// Host-clock instant for an `ntp_time_local` value. Returns nil for 0 (UxPlay reports 0
    /// until the first NTP exchange has completed).
    static func hostNanos(forNTPLocal ntp: UInt64,
                          realtimeNow: UInt64 = realtimeNanosNow(),
                          hostNow: UInt64 = hostNanosNow()) -> UInt64? {
        guard ntp != 0 else { return nil }
        let delta = Int64(bitPattern: ntp &- realtimeNow)
        let h = Int64(bitPattern: hostNow) &+ delta
        return h > 0 ? UInt64(h) : nil
    }

    /// Converts a host-clock nanosecond value to `mach_absolute_time` ticks (for AVAudioTime).
    static func machTicks(fromHostNanos n: UInt64) -> UInt64 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        // CLOCK_UPTIME_RAW nanoseconds = ticks * numer / denom
        return UInt64(Double(n) * Double(tb.denom) / Double(tb.numer))
    }
}

/// Decides where each decoded packet goes on the player's timeline so audio stays on the
/// sender's clock. Pure (time is passed in) so it is unit tested without audio hardware.
///
/// The first packet after start / flush / underrun fixes a `shift` between the sender's
/// timeline and the host clock (normally the packet is on time and shift is 0; if it
/// arrived late the start is delayed by `minLead` and the shift records that). Later
/// packets are expected back-to-back; a gap is bridged with silence, an overlap is dropped,
/// and a large error restarts the stream.
struct AudioScheduler {
    enum Action: Equatable {
        /// Restart the player: stop, then begin this packet at host time (ns).
        case start(atHostNanos: UInt64)
        /// Queue directly after what is already scheduled.
        case append
        /// Queue this many frames of silence, then the packet.
        case padSilence(frames: Int)
        /// Packet is already in the past relative to the queue; skip it.
        case drop
    }

    static let sampleRate = 44100.0
    var tolerance: Int64 = 25_000_000       // 25 ms: jitter absorbed without correction
    var resyncThreshold: Int64 = 400_000_000
    var minLead: Int64 = 40_000_000         // earliest start after "now"
    var maxLead: Int64 = 4_000_000_000      // targets further out than this are not trusted

    private(set) var startHost: Int64?
    private(set) var framesQueued: Int64 = 0
    /// Nanoseconds the playout timeline is later than the sender's timeline (>= 0 usually).
    /// Video that wants to stay in sync should be presented this much later as well.
    private(set) var shiftNanos: Int64 = 0

    var isStarted: Bool { startHost != nil }

    mutating func reset() { startHost = nil; framesQueued = 0; shiftNanos = 0 }

    static func nanos(forFrames f: Int64) -> Int64 { Int64(Double(f) * 1_000_000_000 / sampleRate) }
    static func frames(forNanos n: Int64) -> Int { Int((Double(n) * sampleRate / 1_000_000_000).rounded()) }

    /// Host time (ns) at which the next appended frame will play.
    var nextHostNanos: Int64? { startHost.map { $0 + Self.nanos(forFrames: framesQueued) } }

    mutating func plan(targetHostNanos target: UInt64?, frames: Int, now: UInt64) -> Action {
        let now = Int64(now)
        guard startHost != nil, let next = nextHostNanos else {
            return begin(target: target, frames: frames, now: now)
        }
        if next < now { return begin(target: target, frames: frames, now: now)}   // underrun
        guard let target else { framesQueued += Int64(frames); return .append }

        let wanted = Int64(target) + shiftNanos
        let d = wanted - next
        if abs(d) <= tolerance { framesQueued += Int64(frames); return .append }
        if abs(d) > resyncThreshold { return begin(target: target, frames: frames, now: now) }
        if d > 0 {
            let pad = Self.frames(forNanos: d)
            framesQueued += Int64(pad + frames)
            return .padSilence(frames: pad)
        }
        return .drop
    }

    private mutating func begin(target: UInt64?, frames: Int, now: Int64) -> Action {
        let earliest = now + minLead
        var at = earliest
        shiftNanos = 0
        if let t = target.map(Int64.init) {
            if t >= earliest && t - now <= maxLead { at = t } else { shiftNanos = earliest - t }
        }
        startHost = at
        framesQueued = Int64(frames)
        return .start(atHostNanos: UInt64(at))
    }
}

/// AirPlay volume (dB, -30...0, -144 = mute) to a linear gain, the way stock uxplay's
/// `audio_set_volume` does it (flat profile; `taper` is `-taper`; `dbLow`/`dbHigh` are `-db`).
enum AudioVolume {
    static let muteSignal: Float = -144.0

    static func gain(airPlayDB volume: Float, dbLow: Double = -30, dbHigh: Double = 0, taper: Bool = false) -> Float {
        var v = volume
        let frac: Double
        if v == muteSignal { frac = 0 }
        else if v < -30 { v = -30; frac = 0 }
        else if v > 0 { v = 0; frac = 1 }
        else if v == -30 { frac = 0 }
        else if v == 0 { frac = 1 }
        else { frac = min(1.0, Double((30 + v) / 30)) }
        if frac == 0 { return 0 }
        let dbFlat = dbLow + (dbHigh - dbLow) * frac
        var db = dbFlat
        if taper { db = max(dbHigh + 10.0 * (log10(frac) / log10(2.0)), dbFlat) }
        return Float(min(10.0, pow(10.0, 0.05 * db)))
    }

    /// The dB value `audio_set_client_volume` reports back: what uxplay stores in
    /// `current_volume` (out-of-range values clamped to -30...0, mute kept as -144).
    static func stored(_ volume: Float) -> Float {
        if volume == muteSignal { return volume }
        return min(0, max(-30, volume))
    }
}
