// SPDX-License-Identifier: MIT
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// H.264 access units in, `CVPixelBuffer`s out, through a hardware `VTDecompressionSession`.
///
/// - Parameter sets come in-band (UxPlay prepends SPS+PPS to the frame after a codec packet).
///   A new SPS/PPS pair builds a new format description; the session is kept when it can
///   accept it, else (e.g. a resolution change on the hardware decoder) recreated.
/// - Decoding is asynchronous; frames are emitted in decode order (no
///   `EnableTemporalProcessing`, so no reordering). AirPlay mirror streams carry no B-frames,
///   so decode order is display order.
/// - `decode` must be called from one thread at a time (UxPlay's mirror thread, or the fixture
///   player); `onFrame` runs on VideoToolbox's callback thread.
final class VideoDecoder {
    /// Pixel buffer and decode time (submit -> output) in milliseconds.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// Same frame with its arrival/decode timestamps (latency + A/V sync). Called after `onFrame`.
    var onTimedFrame: ((CVPixelBuffer, FrameTiming) -> Void)?
    var onLog: ((String) -> Void)?
    let stats: VideoStats
    /// false: allow a software decoder (comparison runs only).
    let requireHardware: Bool

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var frameIndex: Int64 = 0
    private(set) var usingHardware: Bool?
    /// Session generation: frames from an invalidated session are ignored.
    private var generation = 0

    /// Decode submission mode (`AIRTV_DECODE`), tuned in M8:
    /// - `async` (default): asynchronous, no 1x-real-time hint (decoder runs flat out).
    /// - `async1x`: the M5 flags (`_1xRealTimePlayback` lets the decoder pace itself; adds latency).
    /// - `sync`: decode on the calling thread; the frame is out when `decode` returns.
    enum Mode: String { case async, async1x, sync }
    let mode: Mode

    init(stats: VideoStats, requireHardware: Bool = true, mode: Mode? = nil) {
        self.stats = stats
        self.requireHardware = requireHardware
        self.mode = mode ?? ProcessInfo.processInfo.environment["AIRTV_DECODE"].flatMap(Mode.init) ?? .async
    }

    var decodeFlags: VTDecodeFrameFlags {
        switch mode {
        case .async: return [._EnableAsynchronousDecompression]
        case .async1x: return [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
        case .sync: return []
        }
    }

    deinit { reset() }

    var dimensions: (width: Int, height: Int)? {
        lock.lock(); defer { lock.unlock() }
        return format.map(VideoFormat.dimensions)
    }

    /// One UxPlay-shaped Annex-B buffer.
    func decode(_ p: UnsafePointer<UInt8>, _ len: Int, timing: FrameTiming? = nil) {
        let t = timing ?? FrameTiming(arrival: CACurrentMediaTime())
        decode(VideoFormat.accessUnit(UnsafeRawBufferPointer(start: p, count: len)), timing: t)
    }

    func decode(_ au: VideoFormat.AccessUnit, timing: FrameTiming? = nil) {
        let timing0 = timing ?? FrameTiming(arrival: CACurrentMediaTime())
        stats.received()
        lock.lock()
        let changed: Bool = {
            guard let s = au.sps, let p = au.pps else { return false }
            return s != sps || p != pps
        }()
        lock.unlock()
        if changed, let s = au.sps, let p = au.pps { applyParameterSets(sps: s, pps: p) }
        lock.lock()
        guard let session, let format, au.sliceCount > 0 else {
            lock.unlock()
            stats.decodeDropped(error: false)   // nothing to decode yet (no SPS/PPS) or no slice
            return
        }
        let pts = CMTime(value: frameIndex, timescale: 60)
        frameIndex += 1
        let gen = generation
        lock.unlock()

        let sample: CMSampleBuffer
        do { sample = try VideoFormat.sampleBuffer(avcc: au.avcc, format: format, pts: pts) } catch {
            log("sample buffer: \(error)")
            stats.decodeDropped(error: true)
            return
        }
        let submitted = CACurrentMediaTime()
        let flags = decodeFlags
        var info = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: &info) {
            [weak self] status, infoFlags, image, _, _ in
            guard let self else { return }
            let ms = (CACurrentMediaTime() - submitted) * 1000
            guard status == noErr, let image, !infoFlags.contains(.frameDropped) else {
                if status != noErr { self.log("decode callback status \(status)") }
                self.stats.decodeDropped(error: status != noErr)
                if status == kVTInvalidSessionErr { self.invalidate(generation: gen) }
                return
            }
            self.lock.lock(); let current = gen == self.generation; self.lock.unlock()
            guard current else { return }
            self.stats.decoded(ms: ms, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            var timing = timing0
            timing.decoded = CACurrentMediaTime()
            self.stats.decodeLatency(ms: (timing.decoded - timing.arrival) * 1000)
            self.onFrame?(image, ms)
            self.onTimedFrame?(image, timing)
        }
        if st != noErr {
            log("VTDecompressionSessionDecodeFrame \(st)")
            stats.decodeDropped(error: true)
            if st == kVTInvalidSessionErr { invalidate(generation: gen) }
        }
    }

    /// Blocks until every submitted frame has been output (fixture runs, tests).
    func waitForFrames() {
        lock.lock(); let s = session; lock.unlock()
        if let s { VTDecompressionSessionWaitForAsynchronousFrames(s) }
    }

    /// Waits for in-flight frames, then drops the session and parameter sets (end of a mirror
    /// session or a disconnect). The next stream starts from its own SPS/PPS.
    func reset() {
        lock.lock()
        let s = session
        session = nil; format = nil; sps = nil; pps = nil; frameIndex = 0; generation += 1
        lock.unlock()
        if let s {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
    }

    // MARK: private

    /// Called from the decode thread with the lock NOT held: waiting for in-flight frames
    /// while holding it would deadlock with the output handler.
    private func applyParameterSets(sps newSPS: Data, pps newPPS: Data) {
        let fd: CMVideoFormatDescription
        do { fd = try VideoFormat.formatDescription(sps: newSPS, pps: newPPS) } catch {
            log("bad SPS/PPS: \(error)")
            return
        }
        let (w, h) = VideoFormat.dimensions(fd)
        lock.lock()
        let first = sps == nil
        sps = newSPS; pps = newPPS
        if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fd) {
            format = fd
            lock.unlock()
            stats.formatChanged()
            log("parameter sets changed -> \(w)x\(h), session kept")
            return
        }
        let old = session
        lock.unlock()
        if let old {
            // Let the old session's last frames come out (they are still current), then retire it.
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            lock.lock(); session = nil; format = nil; generation += 1; lock.unlock()
            VTDecompressionSessionInvalidate(old)
            stats.formatChanged()
        }
        let new = makeSession(fd)
        lock.lock(); session = new; format = new == nil ? nil : fd; lock.unlock()
        log("\(first ? "stream" : "parameter sets changed") -> \(w)x\(h), new session hw=\(usingHardware.map(String.init) ?? "-")")
    }

    private func makeSession(_ fd: CMVideoFormatDescription) -> VTDecompressionSession? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var specs: [[CFString: Any]] = [[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]]
        if !requireHardware {
            specs = [[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]]
        }
        for spec in specs {
            var out: VTDecompressionSession?
            let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                                  decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &out)
            guard st == noErr, let s = out else {
                log("VTDecompressionSessionCreate \(spec) -> \(st)")
                continue
            }
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            usingHardware = Self.isHardware(s)
            stats.sessionCreated(hardware: usingHardware ?? false)
            return s
        }
        return nil
    }

    static func isHardware(_ s: VTDecompressionSession) -> Bool {
        var v: CFBoolean?
        let st = withUnsafeMutablePointer(to: &v) {
            VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: kCFAllocatorDefault, valueOut: $0)
        }
        return st == noErr && v.map(CFBooleanGetValue) == true
    }

    private func invalidate(generation gen: Int) {
        lock.lock()
        guard gen == generation, let s = session else { lock.unlock(); return }
        // Recreate on the next SPS/PPS-carrying frame; keep the parameter sets so the very
        // next frame can rebuild the session (mirror streams rarely resend an IDR).
        session = nil; generation += 1
        let fd = format
        lock.unlock()
        VTDecompressionSessionInvalidate(s)
        log("session invalidated by VideoToolbox; recreating")
        if let fd, let new = makeSession(fd) {
            lock.lock(); if session == nil { session = new } else { VTDecompressionSessionInvalidate(new) }; lock.unlock()
        }
    }

    private func log(_ m: String) { onLog?("[video] " + m) }
}
