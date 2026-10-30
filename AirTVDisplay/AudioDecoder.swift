import AudioToolbox
import Foundation

/// AirPlay audio compression types (`ct` in SETUP / `audio_decode_struct.ct`), the same set
/// stock UxPlay's audio_renderer.c knows.
enum AudioCodec: UInt8 {
    case pcm = 1       // 44100/16/2 S16LE, uncompressed
    case alac = 2      // 44100/16/2, spf 352 (AirPlay 1 / audio-only RAOP)
    case aacLC = 4     // 44100/2, spf 1024 (never seen in practice)
    case aacELD = 8    // 44100/2, spf 480 (mirroring)

    var framesPerPacket: UInt32 {
        switch self {
        case .pcm: return 1
        case .alac: return 352
        case .aacLC: return 1024
        case .aacELD: return 480
        }
    }

    /// UxPlay's per-codec sanity check on the first byte of a frame (audio_renderer.c).
    func looksValid(firstByte b: UInt8) -> Bool {
        switch self {
        case .aacELD: return [0x8c, 0x8d, 0x8e, 0x80, 0x81, 0x82].contains(b)
        case .alac: return b == 0x20
        case .aacLC: return b == 0xff
        case .pcm: return true
        }
    }
}

enum AudioDecoderError: Error, CustomStringConvertible {
    case create(OSStatus)
    case cookie(OSStatus)
    case decode(OSStatus)

    var description: String {
        switch self {
        case .create(let s): return "AudioConverterNew failed (\(s))"
        case .cookie(let s): return "set magic cookie failed (\(s))"
        case .decode(let s): return "AudioConverterFillComplexBuffer failed (\(s))"
        }
    }
}

/// Decodes AirPlay audio packets to interleaved Int16 / 44.1 kHz / stereo PCM with
/// AudioToolbox's `AudioConverter`. One instance per audio stream; not thread safe.
final class AudioDecoder {
    static let sampleRate: Double = 44100
    static let channels: UInt32 = 2
    static let bytesPerFrame: UInt32 = 4

    /// Output format shared by decoder and renderer.
    static var pcmDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
    }

    /// ALAC magic cookie as UxPlay sends it to GStreamer (the full 36-byte 'alac' atom:
    /// frameLength 352, 16 bit, pb 40, mb 10, kb 14, 2 ch, maxRun 255, 44100 Hz).
    static let alacCookie: [UInt8] = [
        0x00, 0x00, 0x00, 0x24, 0x61, 0x6c, 0x61, 0x63, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x60, 0x00, 0x10, 0x28, 0x0a, 0x0e, 0x02, 0x00, 0xff,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xac, 0x44]
    /// AudioSpecificConfig UxPlay uses for AAC-ELD (f8e85000) and AAC-LC (1210).
    static let eldConfig: [UInt8] = [0xf8, 0xe8, 0x50, 0x00]
    static let lcConfig: [UInt8] = [0x12, 0x10]

    let codec: AudioCodec
    private var converter: AudioConverterRef?
    private let outBuffer: UnsafeMutableRawPointer
    private let outCapacityFrames: UInt32

    init(codec: AudioCodec) throws {
        self.codec = codec
        outCapacityFrames = max(codec.framesPerPacket, 1) * 2
        outBuffer = .allocate(byteCount: Int(outCapacityFrames * Self.bytesPerFrame), alignment: 16)
        guard codec != .pcm else { return }   // no converter: PCM passes through

        var inDesc = Self.inputDescription(codec)
        var outDesc = Self.pcmDescription
        var conv: AudioConverterRef?
        let st = AudioConverterNew(&inDesc, &outDesc, &conv)
        guard st == noErr, let conv else { outBuffer.deallocate(); throw AudioDecoderError.create(st) }
        converter = conv
        if let cookie = Self.cookie(for: codec) {
            let cs = cookie.withUnsafeBytes {
                AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
            }
            if cs != noErr {
                AudioConverterDispose(conv); outBuffer.deallocate()
                throw AudioDecoderError.cookie(cs)
            }
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        outBuffer.deallocate()
    }

    static func inputDescription(_ c: AudioCodec) -> AudioStreamBasicDescription {
        var d = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: 0, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: c.framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: 0, mReserved: 0)
        switch c {
        case .alac: d.mFormatID = kAudioFormatAppleLossless; d.mFormatFlags = 1   // 16 bit source
        case .aacELD: d.mFormatID = kAudioFormatMPEG4AAC_ELD
        case .aacLC: d.mFormatID = kAudioFormatMPEG4AAC
        case .pcm: return pcmDescription
        }
        return d
    }

    static func cookie(for c: AudioCodec) -> [UInt8]? {
        switch c {
        case .alac: return alacCookie
        case .aacELD: return esds(audioSpecificConfig: eldConfig)
        case .aacLC: return esds(audioSpecificConfig: lcConfig)
        case .pcm: return nil
        }
    }

    /// AudioToolbox wants the AAC decoder config as an MPEG-4 ES descriptor ('esds' payload),
    /// not the bare AudioSpecificConfig GStreamer takes.
    static func esds(audioSpecificConfig asc: [UInt8]) -> [UInt8] {
        func tag(_ t: UInt8, _ body: [UInt8]) -> [UInt8] { [t, 0x80, 0x80, 0x80, UInt8(body.count)] + body }
        let decSpecific = tag(0x05, asc)
        let decConfig = tag(0x04, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + decSpecific)
        let slConfig = tag(0x06, [0x02])
        return tag(0x03, [0x00, 0x00, 0x00] + decConfig + slConfig)
    }

    private final class Input {
        let ptr: UnsafeRawPointer
        let size: UInt32
        var consumed = false
        let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        init(_ p: UnsafeRawPointer, _ s: UInt32) {
            ptr = p; size = s
            desc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: s)
        }
        deinit { desc.deallocate() }
    }

    /// Decodes one packet. Returns interleaved Int16 stereo bytes (4 bytes per frame).
    func decode(_ packet: UnsafeRawBufferPointer) throws -> Data {
        guard let converter else { return Data(packet) }   // PCM: UxPlay already delivers S16LE
        guard let base = packet.baseAddress, packet.count > 0 else { return Data() }
        let input = Input(base, UInt32(packet.count))
        var frames = outCapacityFrames
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: Self.channels, mDataByteSize: outCapacityFrames * Self.bytesPerFrame, mData: outBuffer))
        let st = AudioConverterFillComplexBuffer(converter, { _, ioNum, ioData, descs, user in
            let c = Unmanaged<Input>.fromOpaque(user!).takeUnretainedValue()
            if c.consumed { ioNum.pointee = 0; return -1 }   // no more input; ends this call
            c.consumed = true
            ioNum.pointee = 1
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = 1
            ioData.pointee.mBuffers.mDataByteSize = c.size
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: c.ptr)
            descs?.pointee = c.desc
            return noErr
        }, Unmanaged.passUnretained(input).toOpaque(), &frames, &abl, nil)
        withExtendedLifetime(input) {}
        // -1 is our own end-of-input marker, returned after the packet's frames were produced.
        if st != noErr && !(st == -1 && frames > 0) { throw AudioDecoderError.decode(st) }
        return Data(bytes: outBuffer, count: Int(frames * Self.bytesPerFrame))
    }

    /// Drops converter state (after a flush) so stale overlap isn't mixed into new audio.
    func reset() { if let converter { AudioConverterReset(converter) } }
}
