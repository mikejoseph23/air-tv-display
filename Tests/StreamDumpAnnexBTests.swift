// SPDX-License-Identifier: MIT
import XCTest

/// M4T: the M4 stream dump, produced the way the app produces it (`AIRTV_DUMP_SECONDS` read by
/// `RaopServer.start`, buffers through `handleVideo`), is valid Annex-B H.264. Fixture access
/// units stand in for a live mirror session; `ffprobe`/`ffmpeg` from the M0 env cross-check.
final class StreamDumpAnnexBTests: XCTestCase {
    static let ffBin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/m0-mamba/root/envs/ux/bin")

    var dir: URL!
    var savedEnv: [String: String?] = [:]

    override func setUpWithError() throws {
        _ = RtspLog.shared   // keep rtsp.log where it was; only the dump moves
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("m4t-dump-\(UUID().uuidString)")
        for k in ["AIRTV_DUMP_SECONDS", "AIRTV_LOG_DIR"] { savedEnv[k] = ProcessInfo.processInfo.environment[k] }
        setenv("AIRTV_DUMP_SECONDS", "60", 1)
        setenv("AIRTV_LOG_DIR", dir.path, 1)
    }

    override func tearDownWithError() throws {
        for (k, v) in savedEnv { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Runs `units` (with failed-decrypt buffers interleaved) through a fresh server's
    /// `handleVideo` and returns the dump file's bytes.
    func dump(_ units: [Data], deviceID: String) throws -> Data {
        let s = RaopServer()
        try s.start(name: "M4T Dump", port: 0, deviceID: deviceID, advertise: false)
        let bad: [UInt8] = [1, 0, 0, 0, 0x65, 0x88, 0xde, 0xad]   // UxPlay's failed-decrypt marker
        for (i, u) in units.enumerated() {
            if i % 7 == 3 { bad.withUnsafeBufferPointer { s.handleVideo($0.baseAddress!, $0.count, nalCount: 1, h265: false) } }
            u.withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: false) }
        }
        // h265 buffers are never dumped as H.264.
        units[0].withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: true) }
        s.stop()   // closes the dump
        return try Data(contentsOf: dir.appendingPathComponent("stream.h264"))
    }

    func assertCleanAnnexB(_ data: Data, units: [Data], minSPS: Int, file: String) {
        XCTAssertEqual(data, units.reduce(Data(), +), "\(file): dump is exactly the decrypted AUs, in order, nothing else")
        let (nals, leading) = AnnexB.split(data)
        XCTAssertEqual(leading, 0, "\(file): garbage before the first start code")
        XCTAssertEqual(nals.first?.type, 7, "\(file): starts with SPS")
        XCTAssertEqual(nals.dropFirst().first?.type, 8, "\(file): PPS follows SPS")
        XCTAssertFalse(nals.contains { $0.forbiddenBitSet }, "\(file): forbidden_zero_bit set")
        XCTAssertTrue(nals.allSatisfy { $0.startCodeLength == 4 }, "\(file): UxPlay writes 4-byte start codes")
        XCTAssertTrue(nals.allSatisfy { [1, 5, 6, 7, 8, 9].contains($0.type) }, "\(file): unexpected NAL type")
        XCTAssertFalse(nals.contains { $0.length < 2 }, "\(file): empty NAL between start codes")
        // Every byte is accounted for: start codes + NALs tile the file with no gaps.
        var cursor = 0
        for n in nals {
            XCTAssertEqual(n.offset, cursor, "\(file): gap before NAL at \(n.offset)")
            cursor = n.payloadOffset + n.length
        }
        XCTAssertEqual(cursor, data.count)
        XCTAssertGreaterThanOrEqual(nals.filter { $0.type == 7 }.count, minSPS, file)
        XCTAssertGreaterThanOrEqual(nals.filter { $0.type == 8 }.count, minSPS, file)
        XCTAssertGreaterThanOrEqual(nals.filter { $0.type == 5 }.count, 3, file)
    }

    func testDumpOfFixtureSessionIsCleanAnnexB() throws {
        for (file, minSPS, id) in [("synthetic-1080p.h264", 1, "02:4d:54:00:01:01"),
                                   ("synthetic-res-change.h264", 2, "02:4d:54:00:01:02")] {
            let units = try PairingFairPlayTests.accessUnits(file)
            let data = try dump(units, deviceID: id)
            assertCleanAnnexB(data, units: units, minSPS: minSPS, file: file)
        }
    }

    /// ffprobe/ffmpeg agree it is H.264 and decode every frame without errors
    /// (scripts/ffprobe-stream.sh does the same against a live `logs/stream.h264`).
    func testDumpPassesFFprobe() throws {
        let ffprobe = Self.ffBin.appendingPathComponent("ffprobe"), ffmpeg = Self.ffBin.appendingPathComponent("ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else {
            throw XCTSkip("ffprobe not found at \(ffprobe.path)")
        }
        for (file, sizes, id) in [("synthetic-1080p.h264", ["1920,1080"], "02:4d:54:00:01:03"),
                                  ("synthetic-res-change.h264", ["1920,1080", "1280,720"], "02:4d:54:00:01:04")] {
            let units = try PairingFairPlayTests.accessUnits(file)
            _ = try dump(units, deviceID: id)
            let path = dir.appendingPathComponent("stream.h264").path

            let codec = try run(ffprobe, ["-v", "error", "-f", "h264", "-select_streams", "v:0",
                                          "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", path])
            XCTAssertEqual(codec.out.trimmingCharacters(in: .whitespacesAndNewlines), "h264", file)

            func frameSizes(_ f: String) throws -> [String] {
                let r = try run(ffprobe, ["-v", "error", "-f", "h264", "-select_streams", "v:0",
                                          "-show_entries", "frame=width,height", "-of", "csv=p=0", f])
                XCTAssertEqual(r.status, 0, r.err)
                XCTAssertEqual(r.err, "", "\(file): ffprobe errors on \(f)")
                return r.out.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            }
            let lines = try frameSizes(path)
            // Buffers are slices (several per picture), so compare with the source fixture.
            XCTAssertEqual(lines, try frameSizes(PairingFairPlayTests.fixtures.appendingPathComponent(file).path),
                           "\(file): dump decodes to the same frames as the fixture")
            XCTAssertEqual(lines.count, 90, file)
            var distinct: [String] = []
            for l in lines where l != distinct.last { distinct.append(l) }
            XCTAssertEqual(distinct, sizes, "\(file): resolutions in order")

            let decode = try run(ffmpeg, ["-hide_banner", "-v", "error", "-f", "h264", "-i", path, "-f", "null", "-"])
            XCTAssertEqual(decode.status, 0, decode.err)
            XCTAssertEqual(decode.err, "", "\(file): decode errors")

            let script = try run(URL(fileURLWithPath: "/bin/bash"),
                                 [PairingFairPlayTests.repo.appendingPathComponent("scripts/ffprobe-stream.sh").path, path])
            XCTAssertEqual(script.status, 0, script.out + script.err)
            XCTAssertTrue(script.out.contains("OK"), script.out)
        }
    }

    /// A new session (mirror_video_running(true) -> beginSession) truncates; the time limit
    /// still cuts the dump on a buffer boundary.
    func testDumpTimeLimitCutsOnBufferBoundary() throws {
        let url = dir.appendingPathComponent("limit.h264")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = try XCTUnwrap(StreamDump(seconds: 1, fileURL: url))
        let units = try PairingFairPlayTests.accessUnits("synthetic-1080p.h264")
        let t0 = Date()
        for (i, u) in units.enumerated() {
            let ended = u.withUnsafeBytes { d.append($0.bindMemory(to: UInt8.self).baseAddress!, $0.count,
                                                       now: t0.addingTimeInterval(Double(i) / 30)) }
            if ended { break }
        }
        let cut = try Data(contentsOf: url)
        XCTAssertEqual(cut, units.prefix(30).reduce(Data(), +), "1 s at 30 buffers/s = the first 30 whole buffers")
        assertCleanAnnexB(cut, units: Array(units.prefix(30)), minSPS: 1, file: "limit")

        d.beginSession()   // second session overwrites
        units[0].withUnsafeBytes { _ = d.append($0.bindMemory(to: UInt8.self).baseAddress!, $0.count) }
        d.close()
        XCTAssertEqual(try Data(contentsOf: url), units[0])
    }

    // MARK: process helper

    func run(_ exe: URL, _ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        try p.run()
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
    }
}
