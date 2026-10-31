// SPDX-License-Identifier: MIT
import AVFoundation
import XCTest

final class AudioDecoderTests: XCTestCase {
    /// Fixture format (tools/make-audio-fixtures.swift): repeated [u32 BE length][packet].
    static func packets(_ name: String) throws -> [Data] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let d = try Data(contentsOf: url)
        var out: [Data] = [], i = 0
        while i + 4 <= d.count {
            let n = d[i..<i + 4].reduce(0) { Int($0) << 8 | Int($1) }
            i += 4
            out.append(d.subdata(in: i..<i + n)); i += n
        }
        return out
    }

    private func decodeAll(_ name: String, codec: AudioCodec) throws -> (pcm: [Int16], packets: Int) {
        let dec = try AudioDecoder(codec: codec)
        let pkts = try Self.packets(name)
        var pcm: [Int16] = []
        for p in pkts {
            XCTAssertTrue(codec.looksValid(firstByte: p[p.startIndex]), "UxPlay's first-byte check")
            let bytes = try p.withUnsafeBytes { try dec.decode($0) }
            XCTAssertEqual(bytes.count, Int(codec.framesPerPacket * AudioDecoder.bytesPerFrame),
                           "every packet decodes to exactly spf frames")
            bytes.withUnsafeBytes { pcm.append(contentsOf: $0.bindMemory(to: Int16.self)) }
        }
        return (pcm, pkts.count)
    }

    /// Rising zero crossings of one channel, ignoring the first `skip` frames (codec priming).
    private func frequency(_ pcm: [Int16], channel: Int, skip: Int) -> Double {
        let frames = pcm.count / 2
        var crossings = 0
        var prev = pcm[skip * 2 + channel]
        for i in (skip + 1)..<frames {
            let v = pcm[i * 2 + channel]
            if prev < 0 && v >= 0 { crossings += 1 }
            prev = v
        }
        return Double(crossings) / (Double(frames - skip) / AudioDecoder.sampleRate)
    }

    func testALACFixtureDecodesToExpectedPCM() throws {
        let (pcm, n) = try decodeAll("synthetic-alac.pkts", codec: .alac)
        XCTAssertEqual(n, 125)
        XCTAssertEqual(pcm.count, n * 352 * 2, "interleaved stereo Int16")
        XCTAssertEqual(frequency(pcm, channel: 0, skip: 352), 440, accuracy: 6)
        XCTAssertEqual(frequency(pcm, channel: 1, skip: 352), 880, accuracy: 10)
        XCTAssertGreaterThan(pcm.map { abs(Int($0)) }.max()!, 11000, "full-scale tone survived (lossless)")
    }

    func testAACELDFixtureDecodesToExpectedPCM() throws {
        let (pcm, n) = try decodeAll("synthetic-aac-eld.pkts", codec: .aacELD)
        XCTAssertEqual(n, 91)
        XCTAssertEqual(pcm.count, n * 480 * 2)
        XCTAssertEqual(frequency(pcm, channel: 0, skip: 960), 440, accuracy: 8)
        XCTAssertEqual(frequency(pcm, channel: 1, skip: 960), 880, accuracy: 16)
        XCTAssertGreaterThan(pcm.map { abs(Int($0)) }.max()!, 8000, "lossy but audible")
    }

    func testPCMPassThroughAndFormat() throws {
        let dec = try AudioDecoder(codec: .pcm)
        let raw = [UInt8](repeating: 7, count: 1408)
        let out = try raw.withUnsafeBytes { try dec.decode($0) }
        XCTAssertEqual(out.count, 1408)
        let d = AudioDecoder.pcmDescription
        XCTAssertEqual(d.mSampleRate, 44100); XCTAssertEqual(d.mChannelsPerFrame, 2); XCTAssertEqual(d.mBitsPerChannel, 16)
    }

    func testGarbageDoesNotCrash() throws {
        let dec = try AudioDecoder(codec: .alac)
        let junk = [UInt8](repeating: 0xAB, count: 20)
        // Either a clean error or some frames; the point is it returns.
        _ = try? junk.withUnsafeBytes { try dec.decode($0) }
        dec.reset()
    }

    func testFloatBufferConversion() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        var s: [Int16] = [16384, -16384, -32768, 0]   // L0 R0 L1 R1
        let data = Data(bytes: &s, count: 8)
        let b = try XCTUnwrap(AudioRenderer.floatBuffer(from: data, frames: 2, format: fmt))
        XCTAssertEqual(b.frameLength, 2)
        XCTAssertEqual(b.floatChannelData![0][0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(b.floatChannelData![1][0], -0.5, accuracy: 1e-6)
        XCTAssertEqual(b.floatChannelData![0][1], -1.0, accuracy: 1e-6)
        XCTAssertEqual(b.floatChannelData![1][1], 0.0, accuracy: 1e-6)
    }

    /// Drives the real engine path (decode + AVAudioEngine) without asserting on sound.
    /// Skips when the machine has no usable output device.
    func testRendererPlaysFixtureAndStopsCleanly() throws {
        let r = AudioRenderer { _, _ in }
        r.setVolume(db: -144)   // mute: never audible during test runs
        r.start(ct: 2)
        for p in try Self.packets("synthetic-alac.pkts").prefix(30) {
            p.withUnsafeBytes { r.process($0.bindMemory(to: UInt8.self).baseAddress!, count: p.count, ntpLocal: 0) }
        }
        r.flush()
        r.setVolume(db: -10)
        XCTAssertEqual(r.currentVolumeDB, -10)
        XCTAssertEqual(r.currentGain, AudioVolume.gain(airPlayDB: -10))
        Thread.sleep(forTimeInterval: 0.2)
        r.stop()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(r.audioTimelineShiftNanos, 0)
    }
}
