// SPDX-License-Identifier: MIT
import CoreMedia
import CoreVideo
import XCTest

/// M5T: fills the gaps left by VideoPipelineTests: byte-exact AVCC, SPS/PPS identity through the
/// format description, and decoder behaviour around bad or repeated parameter sets mid-stream.
final class VideoPathFormatTests: XCTestCase {
    static let fixtures = ["synthetic-1080p.h264", "synthetic-res-change.h264"]

    static func units(_ file: String) throws -> [Data] { try VideoPipelineTests.units(file) }

    func be32(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }

    func decodeAll(_ units: [Data], decoder: VideoDecoder) -> [String] {
        let lock = NSLock()
        var sizes: [String] = []
        decoder.onFrame = { pb, _ in
            lock.lock(); sizes.append("\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"); lock.unlock()
        }
        for u in units { u.withUnsafeBytes { decoder.decode($0.bindMemory(to: UInt8.self).baseAddress!, $0.count) } }
        decoder.waitForFrames()
        lock.lock(); defer { lock.unlock() }
        return sizes
    }

    /// Slice-only copy of `au` (parameter sets removed), behind 4-byte start codes.
    func slicesOnly(_ au: Data) -> Data {
        var d = Data()
        for n in AnnexB.split(au).nals where n.type == 1 || n.type == 5 {
            d.append(contentsOf: [0, 0, 0, 1]); d.append(au[n.payloadOffset..<(n.payloadOffset + n.length)])
        }
        return d
    }

    // MARK: AVCC

    /// Every access unit of both fixtures: AVCC == concat(BE32(len) + NAL bytes) of the
    /// non-SPS/PPS/AUD NALs, byte for byte, and the parameter sets are the Annex-B payloads.
    func testAVCCIsByteExactForEveryUnit() throws {
        for file in Self.fixtures {
            for (i, u) in try Self.units(file).enumerated() {
                let nals = AnnexB.split(u).nals
                var expected = Data(), lens: [Int] = []
                for n in nals where ![7, 8, 9].contains(n.type) {
                    expected.append(contentsOf: be32(n.length))
                    expected.append(u[n.payloadOffset..<(n.payloadOffset + n.length)])
                    lens.append(n.length)
                }
                let au = VideoFormat.accessUnit(u)
                XCTAssertEqual(au.avcc, expected, "\(file) unit \(i)")
                XCTAssertEqual(au.nalLengths, lens, "\(file) unit \(i)")
                if let s = nals.first(where: { $0.type == 7 }) {
                    XCTAssertEqual(au.sps, u[s.payloadOffset..<(s.payloadOffset + s.length)])
                }
                if let p = nals.first(where: { $0.type == 8 }) {
                    XCTAssertEqual(au.pps, u[p.payloadOffset..<(p.payloadOffset + p.length)])
                }
            }
        }
    }

    /// 3-byte start codes and a leading AUD convert to the same AVCC as the 4-byte form.
    func testThreeByteStartCodesAndAUDConvertIdentically() throws {
        let u = try Self.units("synthetic-1080p.h264")[1]
        let four = VideoFormat.accessUnit(u)
        var three = Data()
        var i = 0
        let b = [UInt8](u)
        while i < b.count {   // rewrite 00 00 00 01 -> 00 00 01
            if i + 3 < b.count, b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 {
                three.append(contentsOf: [0, 0, 1]); i += 4
            } else { three.append(b[i]); i += 1 }
        }
        XCTAssertLessThan(three.count, u.count)
        var withAUD = Data([0, 0, 0, 1, 0x09, 0xF0]); withAUD.append(u)
        XCTAssertEqual(VideoFormat.accessUnit(three).avcc, four.avcc)
        XCTAssertEqual(VideoFormat.accessUnit(withAUD).avcc, four.avcc, "AUD is dropped")
    }

    func testDegenerateBuffersYieldEmptyAccessUnits() {
        for bytes: [UInt8] in [[], [0, 0, 0, 1], [1, 2, 3], [0, 0, 0, 1, 0x09, 0x10]] {
            let au = VideoFormat.accessUnit(Data(bytes))
            XCTAssertEqual(au.sliceCount, 0)
            XCTAssertTrue(au.avcc.isEmpty)
            XCTAssertNil(au.sps)
        }
    }

    // MARK: format description

    func testFormatDescriptionCarriesFixtureParameterSets() throws {
        for file in Self.fixtures {
            for u in try Self.units(file) {
                let au = VideoFormat.accessUnit(u)
                guard let sps = au.sps, let pps = au.pps else { continue }
                let fd = try VideoFormat.formatDescription(sps: sps, pps: pps)
                var count = 0, nalHeader: Int32 = 0
                var ptr: UnsafePointer<UInt8>?, size = 0
                XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fd, parameterSetIndex: 0, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeader), noErr)
                XCTAssertEqual(count, 2)
                XCTAssertEqual(nalHeader, 4)
                XCTAssertEqual(Data(bytes: ptr!, count: size), sps, "SPS bytes in \(file)")
                XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fd, parameterSetIndex: 1, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), noErr)
                XCTAssertEqual(Data(bytes: ptr!, count: size), pps, "PPS bytes in \(file)")
            }
        }
    }

    func testGarbageAndTruncatedParameterSetsThrow() throws {
        let au = VideoFormat.accessUnit(try Self.units("synthetic-1080p.h264")[0])
        let sps = try XCTUnwrap(au.sps), pps = try XCTUnwrap(au.pps)
        XCTAssertThrowsError(try VideoFormat.formatDescription(sps: sps.prefix(5), pps: pps), "truncated SPS")
        XCTAssertThrowsError(try VideoFormat.formatDescription(sps: sps, pps: Data()), "empty PPS")
        XCTAssertThrowsError(try VideoFormat.formatDescription(sps: Data([0x67, 0xFF, 0xFF]), pps: Data([0x68])), "garbage")
    }

    // MARK: decoder

    /// A bad SPS/PPS pair mid-stream is ignored (old format keeps decoding); a re-sent identical
    /// pair causes no format change; later frames still decode.
    func testBadAndRepeatedParameterSetsMidStream() throws {
        let units = try Self.units("synthetic-1080p.h264")
        let good = VideoFormat.accessUnit(units[0])
        let sps = try XCTUnwrap(good.sps), pps = try XCTUnwrap(good.pps)
        func withPS(_ s: Data, _ p: Data, _ au: Data) -> Data {
            var d = Data([0, 0, 0, 1]); d.append(s)
            d.append(contentsOf: [0, 0, 0, 1]); d.append(p)
            d.append(slicesOnly(au))
            return d
        }
        let stats = VideoStats()
        let d = VideoDecoder(stats: stats)
        var seq = Array(units[0..<10])
        seq.append(withPS(sps, pps, units[10]))                                    // identical re-send
        seq.append(withPS(sps.prefix(5), pps, units[11]))                          // truncated SPS
        seq.append(withPS(Data([0x67, 0xFF, 0xFF]), Data([0x68]), units[12]))      // garbage
        seq.append(contentsOf: units[13..<30])
        let sizes = decodeAll(seq, decoder: d)
        XCTAssertEqual(sizes.count, 30)
        XCTAssertEqual(Set(sizes), ["1920x1080"])
        XCTAssertEqual(stats.total().formatChanges, 0)
        XCTAssertEqual(stats.total().decodeErrors, 0)
        XCTAssertEqual(d.dimensions?.width, 1920)
    }

    /// Bad parameter sets as the very first thing: nothing decodes, nothing crashes, and a
    /// proper stream afterwards still works.
    func testGarbageParameterSetsBeforeStreamThenRecovery() throws {
        let units = try Self.units("synthetic-1080p.h264")
        var junk = Data([0, 0, 0, 1, 0x67, 0x42, 0x00])
        junk.append(contentsOf: [0, 0, 0, 1, 0x68])
        junk.append(contentsOf: [0, 0, 0, 1, 0x41, 0x9A, 0x00, 0x01])
        let d = VideoDecoder(stats: VideoStats())
        XCTAssertEqual(decodeAll([junk, junk], decoder: d).count, 0)
        XCTAssertNil(d.dimensions)
        XCTAssertEqual(decodeAll(Array(units.prefix(20)), decoder: d).count, 20)
    }

    /// Resolution change: output switches 1920x1080 -> 1280x720 exactly at the unit that
    /// carries the new parameter sets, both phases contiguous, no frame lost.
    func testResolutionSwitchHappensAtTheNewParameterSets() throws {
        let units = try Self.units("synthetic-res-change.h264")
        var dims: [String] = [], switchAt: Int?
        for (i, u) in units.enumerated() {
            let au = VideoFormat.accessUnit(u)
            if let s = au.sps, let p = au.pps {
                let d = VideoFormat.dimensions(try VideoFormat.formatDescription(sps: s, pps: p))
                let k = "\(d.width)x\(d.height)"
                if dims.last != k { dims.append(k); if dims.count == 2 { switchAt = i } }
            }
        }
        let at = try XCTUnwrap(switchAt)
        let sizes = decodeAll(units, decoder: VideoDecoder(stats: VideoStats()))
        XCTAssertEqual(sizes.count, units.count)
        XCTAssertEqual(Set(sizes[..<at]), ["1920x1080"])
        XCTAssertEqual(Set(sizes[at...]), ["1280x720"])
    }
}
