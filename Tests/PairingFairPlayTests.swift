import CryptoKit
import XCTest

/// M4: receiver identity, FairPlay against the M0 capture, and the decrypted-video signal.
final class PairingFairPlayTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let repo = fixtures.deletingLastPathComponent().deletingLastPathComponent()
    /// iMac en0 MAC and the pk stock UxPlay advertised for it in M0 (docs/discovery-findings.md).
    static let m0DeviceID = "68:fe:f7:12:96:16"
    static let m0StockPK = "f780220b2b360ffd7a7660d6c90dfa42ac6f1c4348bb2601578e781cd6233dbb"

    static func fpFixture() throws -> [String: Data] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("m0-fp-setup.json")))
        var out: [String: Data] = [:]
        for (k, v) in try XCTUnwrap(raw as? [String: String]) { if let d = Data(hex: v) { out[k] = d } }
        return out
    }

    // MARK: identity

    /// The Ed25519 key is a pure function of the deviceid (UxPlay: SHA-512 of a fixed salt +
    /// deviceid, first 32 bytes as the seed), so it survives restarts without a key file.
    func testPublicKeyIdenticalAcrossStartStopCycles() throws {
        let id = "02:11:22:33:44:55"
        var keys: [String] = []
        for _ in 0..<2 {
            let s = RaopServer()
            try s.start(name: "M4 Test", port: 0, deviceID: id, advertise: false)
            XCTAssertGreaterThan(s.port, 0)
            keys.append(s.publicKeyHex)
            s.stop()
        }
        XCTAssertNotNil(keys[0].range(of: "^[0-9a-f]{64}$", options: .regularExpression), keys[0])
        XCTAssertEqual(keys[0], keys[1])

        // Independent derivation with CryptoKit.
        let seed = Data(SHA512.hash(data: Data(("UxPlay-Persistent-Not-Secure-Public-Key" + id).utf8))).prefix(32)
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        XCTAssertEqual(keys[0], pub.hexString)
    }

    /// Same deviceid as stock UxPlay -> same pk the Studio already saw in M0.
    func testPublicKeyMatchesStockUxPlayForEn0() throws {
        let s = RaopServer()
        try s.start(name: "M4 Test", port: 0, deviceID: Self.m0DeviceID, advertise: false)
        defer { s.stop() }
        XCTAssertEqual(s.publicKeyHex, Self.m0StockPK)
    }

    // MARK: FairPlay

    /// Our linked playfair produces the same AES session key stock UxPlay derived in M0.
    func testFairPlayDecryptMatchesM0() throws {
        let f = try Self.fpFixture()
        let logger = try XCTUnwrap(logger_init())
        defer { logger_destroy(logger) }
        let fp = try XCTUnwrap(fairplay_init(logger))
        defer { fairplay_destroy(fp) }

        var m2 = [UInt8](repeating: 0, count: 142)
        var m4 = [UInt8](repeating: 0, count: 32)
        var key = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(fairplay_setup(fp, [UInt8](try XCTUnwrap(f["m1_request"])), &m2), 0)
        XCTAssertEqual(Data(m2), f["m2_response"])
        XCTAssertEqual(fairplay_handshake(fp, [UInt8](try XCTUnwrap(f["m3_request"])), &m4), 0)
        XCTAssertEqual(Data(m4), f["m4_response"])
        XCTAssertEqual(fairplay_decrypt(fp, [UInt8](try XCTUnwrap(f["setup_ekey"])), &key), 0)
        XCTAssertEqual(Data(key), f["setup_aeskey"])
    }

    /// Replays M0's GET /info + fp-setup x2 over RTSP into an in-process server and compares
    /// the replies byte-for-byte (scripts/replay-fp-setup.py, also usable against the app).
    func testFpSetupReplayOverRTSP() throws {
        let s = RaopServer()
        try s.start(name: "M4 Test", port: 0, deviceID: "02:11:22:33:44:56", advertise: false)
        defer { s.stop() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Self.repo.appendingPathComponent("scripts/replay-fp-setup.py").path, "127.0.0.1", "\(s.port)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, out)
        XCTAssertTrue(out.contains("PASS"), out)
    }

    // MARK: video signal

    /// Annex-B buffers like UxPlay's mirror thread delivers (4-byte start code per NAL).
    static func accessUnits(_ file: String) throws -> [Data] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(file))
        let nals = AnnexB.split(data).nals
        var units: [Data] = []
        var cur = Data()
        for n in nals {
            cur.append(contentsOf: [0, 0, 0, 1])
            cur.append(data[n.payloadOffset..<(n.payloadOffset + n.length)])
            if n.type == 1 || n.type == 5 { units.append(cur); cur = Data() }   // end of an AU
        }
        return units
    }

    func testDecryptedVideoDrivesStateToStreaming() throws {
        let s = RaopServer()
        try s.start(name: "M4 Test", port: 0, deviceID: "02:11:22:33:44:57", advertise: false)
        defer { s.stop() }
        var state = ReceiverState.idle
        var events: [RaopEvent] = []
        let started = expectation(description: "videoStarted")
        let failed = expectation(description: "videoDecryptFailed")
        s.onEvent = { e in
            events.append(e)
            state = ReceiverStateMachine.next(state, e)
            if case .videoStarted = e { started.fulfill() }
            if case .videoDecryptFailed = e { failed.fulfill() }
        }

        let units = try Self.accessUnits("synthetic-1080p.h264")
        XCTAssertGreaterThan(units.count, 30)
        let bad: [UInt8] = [1, 0, 0, 0, 0x65, 0x88]   // UxPlay's failed-decrypt marker
        bad.withUnsafeBufferPointer { s.handleVideo($0.baseAddress!, $0.count, nalCount: 1, h265: false) }
        for u in units.prefix(10) {
            u.withUnsafeBytes { b in
                s.handleVideo(b.bindMemory(to: UInt8.self).baseAddress!, b.count, nalCount: 1, h265: false)
            }
        }
        wait(for: [failed, started], timeout: 2)
        XCTAssertEqual(state, .streaming)
        let startedCount = events.filter { if case .videoStarted = $0 { return true }; return false }.count
        XCTAssertEqual(startedCount, 1, "videoStarted fires once per session")
        if case .videoStarted(let nals)? = events.first(where: { if case .videoStarted = $0 { return true }; return false }) {
            XCTAssertTrue(nals.hasPrefix("SPS(sc4"), nals)
            XCTAssertTrue(nals.contains("IDR"), nals)
        }
    }

    func testStateMachineTransitions() {
        typealias M = ReceiverStateMachine
        var s = ReceiverState.idle
        s = M.next(s, .connectionOpened(open: 1)); XCTAssertEqual(s, .pairing)
        s = M.next(s, .clientRequest(name: "Studio", model: "Mac15,14", deviceID: "x")); XCTAssertEqual(s, .pairing)
        s = M.next(s, .mirrorRunning(true)); XCTAssertEqual(s, .pairing, "SETUP alone is not streaming")
        s = M.next(s, .videoDecryptFailed); XCTAssertEqual(s, .pairing)
        s = M.next(s, .videoStarted(nals: "")); XCTAssertEqual(s, .streaming)
        s = M.next(s, .connectionOpened(open: 2)); XCTAssertEqual(s, .streaming)
        s = M.next(s, .connectionClosed(open: 1)); XCTAssertEqual(s, .streaming)
        s = M.next(s, .mirrorRunning(false)); XCTAssertEqual(s, .pairing)
        s = M.next(s, .connectionClosed(open: 0)); XCTAssertEqual(s, .idle)
        s = M.next(s, .videoStarted(nals: "")); XCTAssertEqual(s, .streaming)
        s = M.next(s, .connectionReset(reason: 0)); XCTAssertEqual(s, .idle)
        XCTAssertEqual(M.next(.stopped, .videoStarted(nals: "")), .stopped)
    }

    // MARK: dump + fixtures

    func testStreamDumpStopsAfterConfiguredSeconds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m4-dump-\(UUID().uuidString).h264")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(StreamDump(seconds: 0, fileURL: url), "off by default")
        let d = try XCTUnwrap(StreamDump(seconds: 1, fileURL: url))
        d.beginSession()
        let units = try Self.accessUnits("synthetic-1080p.h264")
        let t0 = Date()
        var written = 0
        for (i, u) in units.enumerated() {
            let ended = u.withUnsafeBytes { d.append($0.bindMemory(to: UInt8.self).baseAddress!, $0.count,
                                                       now: t0.addingTimeInterval(Double(i) / 30)) }
            if ended { break }
            written += u.count
        }
        d.close()
        XCTAssertTrue(d.finished)
        XCTAssertEqual(d.bytesWritten, written)
        let dumped = try Data(contentsOf: url)
        XCTAssertEqual(dumped.count, written)
        let types = Set(AnnexB.split(dumped).nals.map(\.type))
        XCTAssertTrue(types.isSuperset(of: [5, 7, 8]))
    }

    func testFixturesAreCleanAnnexB() throws {
        for (file, minSPS) in [("synthetic-1080p.h264", 1), ("synthetic-res-change.h264", 2)] {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(file))
            XCTAssertLessThan(data.count, 2_000_000, file)
            let (nals, leading) = AnnexB.split(data)
            XCTAssertEqual(leading, 0, "\(file): bytes before the first start code")
            XCTAssertEqual(nals.first?.type, 7, "\(file) starts with SPS")
            XCTAssertFalse(nals.contains { $0.forbiddenBitSet }, file)
            XCTAssertGreaterThanOrEqual(nals.filter { $0.type == 7 }.count, minSPS, file)
            XCTAssertGreaterThanOrEqual(nals.filter { $0.type == 5 }.count, 3, file)
        }
    }
}

extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var it = hex.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(v)
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
