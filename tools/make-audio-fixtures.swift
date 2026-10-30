// Generates Tests/Fixtures/synthetic-{alac,aac-eld}.pkts: one second of a stereo test tone
// (440 Hz left, 880 Hz right, 44.1 kHz) encoded with AudioToolbox, stored as repeated
// [u32 big-endian length][packet bytes]. Usage:
//   swiftc -O tools/make-audio-fixtures.swift -o /tmp/make-audio-fixtures && /tmp/make-audio-fixtures Tests/Fixtures
import AudioToolbox
import Foundation

let rate = 44100.0
let seconds = 1.0

func tone() -> [Int16] {
    let n = Int(rate * seconds)
    var s = [Int16](); s.reserveCapacity(n * 2)
    for i in 0..<n {
        let t = Double(i) / rate
        s.append(Int16(sin(2 * .pi * 440 * t) * 12000))
        s.append(Int16(sin(2 * .pi * 880 * t) * 12000))
    }
    return s
}

func encode(format: AudioFormatID, flags: UInt32, spf: UInt32, pcm: [Int16]) -> [[UInt8]] {
    var src = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
        mBitsPerChannel: 16, mReserved: 0)
    var dst = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: format, mFormatFlags: flags, mBytesPerPacket: 0,
        mFramesPerPacket: spf, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    var conv: AudioConverterRef?
    let st = AudioConverterNew(&src, &dst, &conv)
    guard st == noErr, let conv else { fatalError("AudioConverterNew \(st)") }
    var maxPacket: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    AudioConverterGetProperty(conv, kAudioConverterPropertyMaximumOutputPacketSize, &sz, &maxPacket)

    final class Src { var pcm: [Int16]; var pos = 0; init(_ p: [Int16]) { pcm = p } }
    let source = Src(pcm)
    var packets: [[UInt8]] = []
    let out = UnsafeMutableRawPointer.allocate(byteCount: Int(maxPacket), alignment: 16)
    while true {
        var n: UInt32 = 1
        var desc = AudioStreamPacketDescription()
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: maxPacket, mData: out))
        let r = AudioConverterFillComplexBuffer(conv, { _, ioN, ioData, _, user in
            let s = Unmanaged<Src>.fromOpaque(user!).takeUnretainedValue()
            let remaining = s.pcm.count / 2 - s.pos
            if remaining <= 0 { ioN.pointee = 0; return -1 }
            let take = min(Int(ioN.pointee), remaining, 1024)
            // pcm array storage stays valid for the converter call; copy to a stable buffer.
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: take * 4, alignment: 4)
            s.pcm.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress! + s.pos * 4, byteCount: take * 4) }
            s.pos += take
            ioN.pointee = UInt32(take)
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(take * 4), mData: bytes)
            return noErr
        }, Unmanaged.passUnretained(source).toOpaque(), &n, &abl, &desc)
        if n > 0 {
            packets.append(Array(UnsafeRawBufferPointer(start: out + Int(desc.mStartOffset),
                                                        count: Int(desc.mDataByteSize))))
        }
        if r != noErr || n == 0 { break }
    }
    return packets
}

func write(_ packets: [[UInt8]], to url: URL) {
    var d = Data()
    for p in packets {
        var l = UInt32(p.count).bigEndian
        d.append(Data(bytes: &l, count: 4)); d.append(contentsOf: p)
    }
    try! d.write(to: url)
    print("\(url.lastPathComponent): \(packets.count) packets, \(d.count) bytes, first byte 0x\(String(packets[0][0], radix: 16))")
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let pcm = tone()
write(encode(format: kAudioFormatAppleLossless, flags: 1, spf: 352, pcm: pcm), to: dir.appendingPathComponent("synthetic-alac.pkts"))
write(encode(format: kAudioFormatMPEG4AAC_ELD, flags: 0, spf: 480, pcm: pcm), to: dir.appendingPathComponent("synthetic-aac-eld.pkts"))
