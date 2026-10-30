import AVFoundation
import Foundation

/// Decodes AirPlay audio (AAC-ELD / ALAC) and plays it through CoreAudio.
///
/// Threading: every entry point is safe to call from UxPlay's RTP / HTTP threads; the work
/// runs on one serial queue. `audio_process` buffers are copied before the callback returns.
///
/// A/V contract for the video path (M5): audio frames are placed on the host clock at
/// `AudioClock.hostNanos(forNTPLocal: ntp_time_local) + timelineShiftNanos`. To stay in sync,
/// present a video frame at `AudioClock.hostNanos(forNTPLocal: frame.ntp_time_local)
/// + audioTimelineShiftNanos + audioOutputLatencyNanos`. Both properties are readable from any
/// thread and are 0 while no audio is playing (video then simply follows its own clock).
final class AudioRenderer {
    private let queue = DispatchQueue(label: "net.iadev.airtv.audio", qos: .userInteractive)
    private let log: (RtspLog.Level, String) -> Void

    // Queue-confined state.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var decoder: AudioDecoder?
    private var codec: AudioCodec?
    private var scheduler = AudioScheduler()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioDecoder.sampleRate,
                                       channels: 2, interleaved: false)!
    private var packets = 0, dropped = 0, invalid = 0

    // Cross-thread readable state.
    private let shared = NSLock()
    private var _shift: Int64 = 0
    private var _outputLatency: Int64 = 0
    private var _dB: Float = 0
    private var _gain: Float = 1

    /// Env `AIRTV_AUDIO_SYNC=0` plays every packet as soon as it arrives (stock uxplay default).
    let timeSync: Bool
    /// Env `AIRTV_AUDIO_OFFSET_MS`: extra delay (+) or advance (-) applied to the audio timeline.
    let userOffsetNanos: Int64

    init(log: @escaping (RtspLog.Level, String) -> Void) {
        self.log = log
        let env = ProcessInfo.processInfo.environment
        timeSync = env["AIRTV_AUDIO_SYNC"] != "0"
        userOffsetNanos = Int64(env["AIRTV_AUDIO_OFFSET_MS"].flatMap(Double.init) ?? 0) * 1_000_000
    }

    deinit { teardown() }   // no queued block can still hold self here

    var audioTimelineShiftNanos: Int64 { shared.lock(); defer { shared.unlock() }; return _shift }
    var audioOutputLatencyNanos: Int64 { shared.lock(); defer { shared.unlock() }; return _outputLatency }
    /// Last AirPlay volume in dB, as reported back through `audio_set_client_volume`.
    var currentVolumeDB: Float { shared.lock(); defer { shared.unlock() }; return _dB }
    var currentGain: Float { shared.lock(); defer { shared.unlock() }; return _gain }

    // MARK: audio_get_format / stop

    /// New audio stream (`ct` is the AirPlay compression type). Safe to call again to switch codec.
    func start(ct: UInt8) {
        queue.async { [self] in
            guard let c = AudioCodec(rawValue: ct) else {
                log(.err, "audio: unknown compression type ct=\(ct)"); return
            }
            if c == codec, engine != nil { return }
            teardown()
            do { decoder = try AudioDecoder(codec: c) } catch {
                log(.err, "audio: \(c) decoder failed: \(error)"); return
            }
            codec = c
            let e = AVAudioEngine(), p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            p.volume = currentGain
            do { try e.start() } catch {
                log(.err, "audio: engine start failed: \(error)"); decoder = nil; codec = nil; return
            }
            engine = e; player = p
            p.play()
            scheduler.reset()
            packets = 0; dropped = 0; invalid = 0
            publish(shift: 0, latency: Int64(e.outputNode.presentationLatency * 1e9))
            log(.info, "audio: started \(c) timeSync=\(timeSync) offset=\(userOffsetNanos / 1_000_000)ms "
                + "outputLatency=\(Int(e.outputNode.presentationLatency * 1000))ms")
        }
    }

    /// Connection closed / session ended.
    func stop() { queue.async { [self] in teardown() } }

    /// `audio_flush`: the sender seeked or paused; drop queued audio and re-sync on the next packet.
    func flush() {
        queue.async { [self] in
            decoder?.reset()
            player?.stop(); player?.play()
            scheduler.reset()
            publish(shift: 0, latency: nil)
            log(.debug, "audio: flush")
        }
    }

    // MARK: volume

    /// `audio_set_volume`: AirPlay dB (-30...0, -144 = mute).
    func setVolume(db: Float) {
        let stored = AudioVolume.stored(db)
        let gain = AudioVolume.gain(airPlayDB: db)
        shared.lock(); _dB = stored; _gain = gain; shared.unlock()
        queue.async { [self] in player?.volume = gain }
        log(.info, "audio: AirPlay volume \(db) dB -> gain \(String(format: "%.3f", gain))")
    }

    // MARK: audio_process

    func process(_ data: UnsafePointer<UInt8>, count: Int, ntpLocal: UInt64) {
        guard count > 0 else { return }
        let copy = Data(bytes: data, count: count)
        queue.async { [self] in handle(copy, ntpLocal: ntpLocal) }
    }

    private func handle(_ packet: Data, ntpLocal: UInt64) {
        guard let player, let decoder, let codec else { return }   // not started (or failed)
        if !codec.looksValid(firstByte: packet[packet.startIndex]) {
            invalid += 1
            if invalid <= 3 { log(.err, "audio: invalid \(codec) frame, first byte 0x\(String(packet[packet.startIndex], radix: 16)); skipped") }
            return
        }
        let pcm: Data
        do { pcm = try packet.withUnsafeBytes { try decoder.decode($0) } } catch {
            invalid += 1
            if invalid <= 3 { log(.err, "audio: decode failed: \(error)") }
            return
        }
        let frames = pcm.count / Int(AudioDecoder.bytesPerFrame)
        guard frames > 0 else { return }
        packets += 1

        let now = AudioClock.hostNanosNow()
        var target = timeSync ? AudioClock.hostNanos(forNTPLocal: ntpLocal, hostNow: now) : nil
        if let t = target { target = UInt64(max(1, Int64(t) + userOffsetNanos)) }
        let action = scheduler.plan(targetHostNanos: target, frames: frames, now: now)
        guard let buf = Self.floatBuffer(from: pcm, frames: frames, format: format) else { return }

        switch action {
        case .drop:
            dropped += 1
        case .append:
            player.scheduleBuffer(buf, completionHandler: nil)
        case .padSilence(let n):
            if let s = Self.silence(frames: n, format: format) { player.scheduleBuffer(s, completionHandler: nil) }
            player.scheduleBuffer(buf, completionHandler: nil)
        case .start(let host):
            player.stop()
            player.play()
            player.scheduleBuffer(buf, at: AVAudioTime(hostTime: AudioClock.machTicks(fromHostNanos: host)),
                                  options: [], completionHandler: nil)
            let shift = scheduler.shiftNanos
            publish(shift: shift, latency: nil)
            log(.info, "audio: (re)start at +\(Int((Int64(host) - Int64(now)) / 1_000_000))ms, timeline shift \(shift / 1_000_000)ms")
        }
        if packets == 1 || packets % 1000 == 0 {
            log(.debug, "audio: packets=\(packets) dropped=\(dropped) invalid=\(invalid)")
        }
    }

    // MARK: helpers

    private func publish(shift: Int64, latency: Int64?) {
        shared.lock(); _shift = shift; if let latency { _outputLatency = latency }; shared.unlock()
    }

    private func teardown() {
        guard engine != nil || decoder != nil else { return }
        player?.stop()
        engine?.stop()
        if let p = player { engine?.detach(p) }
        player = nil; engine = nil; decoder = nil; codec = nil
        scheduler.reset()
        publish(shift: 0, latency: 0)
        log(.info, "audio: stopped (packets=\(packets) dropped=\(dropped) invalid=\(invalid))")
    }

    /// Interleaved Int16 stereo -> non-interleaved Float32 (what the mixer wants).
    static func floatBuffer(from pcm: Data, frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                ch[0][i] = Float(s[i * 2]) / 32768
                ch[1][i] = Float(s[i * 2 + 1]) / 32768
            }
        }
        return b
    }

    static func silence(frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard frames > 0, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(format.channelCount) { ch[c].update(repeating: 0, count: frames) }
        return b
    }
}
