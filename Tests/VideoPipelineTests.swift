import CoreVideo
import XCTest

/// M5: Annex-B -> AVCC, format descriptions, hardware decode of the synthetic fixtures
/// (incl. a mid-stream resolution change), the frame mailbox, color math, and the
/// RaopServer -> VideoSink hook.
final class VideoPipelineTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func units(_ file: String) throws -> [Data] {
        VideoFormat.accessUnits(fromAnnexB: try Data(contentsOf: fixtures.appendingPathComponent(file)))
    }

    /// Decodes every unit; returns output sizes in order.
    func decodeAll(_ units: [Data], decoder: VideoDecoder) -> [String] {
        let lock = NSLock()
        var sizes: [String] = []
        decoder.onFrame = { pb, _ in
            lock.lock(); sizes.append("\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"); lock.unlock()
        }
        for u in units {
            u.withUnsafeBytes { decoder.decode($0.bindMemory(to: UInt8.self).baseAddress!, $0.count) }
        }
        decoder.waitForFrames()
        lock.lock(); defer { lock.unlock() }
        return sizes
    }

    // MARK: format

    func testAnnexBToAVCC() throws {
        let units = try Self.units("synthetic-1080p.h264")
        XCTAssertEqual(units.count, 90)
        let au = VideoFormat.accessUnit(units[0])
        let sps = try XCTUnwrap(au.sps), pps = try XCTUnwrap(au.pps)
        XCTAssertEqual(sps.first.map { $0 & 0x1F }, 7)
        XCTAssertEqual(pps.first.map { $0 & 0x1F }, 8)
        XCTAssertTrue(au.hasIDR)
        XCTAssertGreaterThanOrEqual(au.sliceCount, 1, "x264 sliced threads: several slices per picture")

        // Walk the AVCC bytes: every NAL is behind a 4-byte BE length, none is SPS/PPS.
        var off = 0, lengths: [Int] = []
        let b = [UInt8](au.avcc)
        while off < b.count {
            let n = Int(b[off]) << 24 | Int(b[off + 1]) << 16 | Int(b[off + 2]) << 8 | Int(b[off + 3])
            XCTAssertGreaterThan(n, 0)
            XCTAssertFalse([7, 8, 9].contains(b[off + 4] & 0x1F))
            lengths.append(n)
            off += 4 + n
        }
        XCTAssertEqual(off, b.count)
        XCTAssertEqual(lengths, au.nalLengths)
        // Same payload bytes as the Annex-B input, minus parameter sets and start codes.
        let annexNALs = AnnexB.split(units[0]).nals.filter { ![7, 8, 9].contains($0.type) }
        XCTAssertEqual(annexNALs.map(\.length), lengths)

        let fd = try VideoFormat.formatDescription(sps: sps, pps: pps)
        XCTAssertEqual(VideoFormat.dimensions(fd).width, 1920)
        XCTAssertEqual(VideoFormat.dimensions(fd).height, 1080)

        let p = VideoFormat.accessUnit(units[1])
        XCTAssertNil(p.sps)
        XCTAssertFalse(p.hasIDR)
        XCTAssertEqual(p.sliceCount, au.sliceCount)
    }

    func testResChangeFixtureCarriesTwoParameterSets() throws {
        let units = try Self.units("synthetic-res-change.h264")
        var dims: [String] = []
        for u in units {
            let au = VideoFormat.accessUnit(u)
            if let s = au.sps, let p = au.pps {
                let d = VideoFormat.dimensions(try VideoFormat.formatDescription(sps: s, pps: p))
                let k = "\(d.width)x\(d.height)"
                if dims.last != k { dims.append(k) }
            }
        }
        XCTAssertEqual(dims, ["1920x1080", "1280x720"])
    }

    // MARK: decode

    func testHardwareDecodeOfFixture() throws {
        let stats = VideoStats()
        let d = VideoDecoder(stats: stats)
        let sizes = decodeAll(try Self.units("synthetic-1080p.h264"), decoder: d)
        XCTAssertEqual(d.usingHardware, true, "VideoToolbox must use the hardware decoder")
        XCTAssertEqual(sizes.count, 90)
        XCTAssertEqual(Set(sizes), ["1920x1080"])
        let s = stats.total()
        XCTAssertEqual(s.decodeErrors, 0)
        XCTAssertEqual(s.decodeDropped, 0)
        XCTAssertLessThan(s.decodeMsAvg, 33, "decode must keep up with 30 fps")
    }

    func testMidStreamResolutionChange() throws {
        let stats = VideoStats()
        let d = VideoDecoder(stats: stats)
        let sizes = decodeAll(try Self.units("synthetic-res-change.h264"), decoder: d)
        XCTAssertEqual(sizes.count, 90, "no frame lost across the change")
        XCTAssertEqual(sizes.first, "1920x1080")
        XCTAssertEqual(sizes.last, "1280x720")
        // Exactly one switch, in order.
        let switches = zip(sizes, sizes.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(switches, 1)
        XCTAssertEqual(stats.total().decodeErrors, 0)
        XCTAssertGreaterThanOrEqual(stats.total().formatChanges, 1)
        XCTAssertEqual(d.dimensions?.width, 1280)
    }

    func testFramesBeforeParameterSetsAreDroppedThenStreamRecovers() throws {
        let units = try Self.units("synthetic-1080p.h264")
        let stats = VideoStats()
        let d = VideoDecoder(stats: stats)
        // Join mid-GOP: P-frames with no SPS/PPS yet, then the stream from its IDR.
        let sizes = decodeAll(Array(units[5..<10]) + units, decoder: d)
        XCTAssertEqual(stats.total().decodeDropped, 5)
        XCTAssertEqual(sizes.count, 90)
        // Garbage must not crash the decoder.
        let junk: [UInt8] = [0, 0, 0, 1, 0x65, 0xFF, 0x00, 0x12]
        junk.withUnsafeBufferPointer { d.decode($0.baseAddress!, $0.count) }
        d.waitForFrames()
        // Reset, then a new session starts from its own SPS/PPS.
        d.reset()
        XCTAssertNil(d.dimensions)
        XCTAssertEqual(decodeAll(Array(units.prefix(30)), decoder: d).count, 30)
    }

    func testRaopServerFeedsVideoSink() throws {
        let pipeline = VideoPipeline(render: false)
        let s = RaopServer()
        s.videoSink = pipeline
        let units = try Self.units("synthetic-1080p.h264")
        pipeline.videoSessionBegan()
        for u in units {
            u.withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: false) }
        }
        // UxPlay's failed-decrypt marker is not passed on.
        let bad: [UInt8] = [1, 0, 0, 0, 0x65, 0x88]
        bad.withUnsafeBufferPointer { s.handleVideo($0.baseAddress!, $0.count, nalCount: 1, h265: false) }
        pipeline.decoder.waitForFrames()
        let st = pipeline.stats.total()
        XCTAssertEqual(st.received, 90)
        XCTAssertEqual(st.decoded, 90)
        pipeline.videoSessionEnded()
        XCTAssertNil(pipeline.decoder.dimensions, "session end drops the decoder state")
    }

    /// Off-screen CAMetalLayer: decoded frames reach the GPU and get presented, and the
    /// queue never exceeds 2.
    func testRendererPresentsDecodedFrames() throws {
        let pipeline = VideoPipeline()
        let r = try XCTUnwrap(pipeline.renderer, "no Metal device")
        r.layer.drawableSize = CGSize(width: 1920, height: 1080)
        let units = try Self.units("synthetic-1080p.h264")
        pipeline.videoSessionBegan()
        for u in units.prefix(30) {
            u.withUnsafeBytes { pipeline.videoAccessUnit($0.bindMemory(to: UInt8.self).baseAddress!, $0.count) }
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        pipeline.decoder.waitForFrames()
        r.flush()
        let st = pipeline.stats.total()
        XCTAssertEqual(st.decoded, 30)
        XCTAssertGreaterThan(st.presented, 0)
        XCTAssertEqual(st.presented + st.presentDropped, 30, "every decoded frame is presented or dropped")
        XCTAssertLessThanOrEqual(st.maxQueueDepth, 2)
    }

    // MARK: present helpers

    func testMailboxKeepsLatestAndCountsDrops() {
        var m = FrameMailbox<Int>()
        XCTAssertNil(m.take())
        XCTAssertFalse(m.put(1))
        XCTAssertTrue(m.put(2))
        XCTAssertTrue(m.put(3))
        XCTAssertEqual(m.dropped, 2)
        XCTAssertEqual(m.take(), 3)
        XCTAssertNil(m.take())
        m.put(4); m.clear()
        XCTAssertNil(m.pending)
    }

    func testColorConversion() {
        for bt601 in [false, true] {
            let v = VideoColor.conversion(fullRange: false, bt601: bt601)
            let black = VideoColor.apply(v, SIMD3(16, 128, 128) / 255)
            let white = VideoColor.apply(v, SIMD3(235, 128, 128) / 255)
            for i in 0..<3 {
                XCTAssertEqual(black[i], 0, accuracy: 1e-4)
                XCTAssertEqual(white[i], 1, accuracy: 1e-4)
            }
            // Pure-red-ish chroma raises R above G and B.
            let red = VideoColor.apply(v, SIMD3(81, 90, 240) / 255)
            XCTAssertGreaterThan(red.x, 0.8)
            XCTAssertLessThan(red.y, 0.2)
        }
        let f = VideoColor.conversion(fullRange: true, bt601: false)
        XCTAssertEqual(VideoColor.apply(f, SIMD3(1, 0.5019608, 0.5019608)).x, 1, accuracy: 1e-4)
        XCTAssertEqual(MemoryLayout<VideoColor.Conversion>.stride, 64, "must match the Metal Conv struct")
    }

    func testAspectFit() {
        XCTAssertEqual(VideoGeometry.aspectFit(content: CGSize(width: 1920, height: 1080), in: CGSize(width: 5120, height: 2880)),
                       CGRect(x: 0, y: 0, width: 5120, height: 2880))
        // 16:10 sender on a 16:9 screen: pillarbox.
        XCTAssertEqual(VideoGeometry.aspectFit(content: CGSize(width: 1680, height: 1050), in: CGSize(width: 1920, height: 1080)),
                       CGRect(x: 96, y: 0, width: 1728, height: 1080))
        // Portrait: pillarbox.
        let r = VideoGeometry.aspectFit(content: CGSize(width: 1080, height: 1920), in: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(r.height, 1080)
        XCTAssertEqual(r.midX, 960, accuracy: 1)
    }
}
