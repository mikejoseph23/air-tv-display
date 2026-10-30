import CoreVideo
import Darwin
import XCTest

/// M8: reconnect handling, a second sender, malformed video, display sleep. Drives the real
/// `RaopServer` (UxPlay's httpd on a loopback port) and the real C callback thunks.
final class RobustnessTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static func units(_ file: String) throws -> [Data] {
        VideoFormat.accessUnits(fromAnnexB: try Data(contentsOf: fixtures.appendingPathComponent(file)))
    }

    private var events: [RaopEvent] = []

    func makeServer(_ id: String = "02:11:22:33:44:80", configure: (RaopServer) -> Void = { _ in }) throws -> RaopServer {
        let s = RaopServer()
        configure(s)
        s.onEvent = { [weak self] e in self?.events.append(e) }
        try s.start(name: "M8 Test", port: 0, deviceID: id, advertise: false)
        return s
    }

    /// Spins the main run loop (events, watchdog, reset hops) until `cond` or timeout.
    @discardableResult
    func spin(until cond: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }

    func states(_ evs: [RaopEvent], from start: ReceiverState = .idle) -> ReceiverState {
        evs.reduce(start) { ReceiverStateMachine.next($0, $1) }
    }

    // MARK: RTSP client

    final class Client {
        private(set) var fd: Int32
        init(port: UInt16) throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard rc == 0 else { close(fd); throw NSError(domain: "connect", code: Int(errno)) }
        }
        deinit { disconnect() }

        /// Closes once. (A second close could hit an fd number the in-process server reused.)
        func disconnect() { if fd >= 0 { close(fd); fd = -1 } }

        /// Sends one RTSP request; returns the status line ("" on EOF / timeout).
        func request(_ method: String, _ url: String, cseq: Int) -> String {
            let req = "\(method) \(url) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: AirPlay/xxx\r\n\r\n"
            _ = req.withCString { send(fd, $0, strlen($0), 0) }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return "" }
            return String(decoding: buf[0..<n], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        }

        /// True once the server has closed this connection (recv returns 0 / ECONNRESET).
        func isClosedByServer() -> Bool {
            var b: UInt8 = 0
            let n = recv(fd, &b, 1, 0)
            return n == 0 || (n < 0 && errno == ECONNRESET)
        }
    }

    // MARK: second sender (stock: 409 Conflict while one is connected)

    func testSecondSenderGets409AndFirstKeepsTheReceiver() throws {
        let s = try makeServer()
        defer { s.stop() }
        let a = try Client(port: s.port)
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 1).contains("200"), "first sender accepted")
        let b = try Client(port: s.port)
        XCTAssertTrue(b.request("OPTIONS", "*", cseq: 1).contains("409"), "second sender rejected like stock uxplay")
        // The first is undisturbed.
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 2).contains("200"))
        // First leaves: the next sender gets in without restarting anything.
        a.disconnect()
        XCTAssertTrue(spin(until: { s.openConnectionCount <= 1 }))
        let c = try Client(port: s.port)
        XCTAssertTrue(c.request("OPTIONS", "*", cseq: 1).contains("200"), "re-select after the first sender left")
    }

    func testNoHoldLetsTheNewSenderTakeOver() throws {
        let s = try makeServer("02:11:22:33:44:81") { $0.noHold = true }
        defer { s.stop() }
        let a = try Client(port: s.port)
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 1).contains("200"))
        let b = try Client(port: s.port)
        XCTAssertTrue(b.request("OPTIONS", "*", cseq: 1).contains("200"), "nohold: newcomer admitted")
        XCTAssertTrue(spin(until: { a.isClosedByServer() }, timeout: 4), "old sender dropped")
    }

    // MARK: reconnect: sender vanished without closing (sleep, Wi-Fi drop)

    func testFeedbackWatchdogDropsSilentSenderAndReselectWorks() throws {
        let s = try makeServer("02:11:22:33:44:82") { $0.feedbackLimit = 1.5 }
        defer { s.stop() }
        let port = s.port
        let a = try Client(port: port)
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 1).contains("200"))
        // Without the reset, a sender waking up would get 409 from its own stale session.
        let early = try Client(port: port)
        XCTAssertTrue(early.request("OPTIONS", "*", cseq: 1).contains("409"))
        early.disconnect()
        XCTAssertTrue(spin(until: { s.listenerResets >= 1 }, timeout: 6), "watchdog fired")
        XCTAssertTrue(a.isClosedByServer(), "stale connection closed")
        XCTAssertEqual(s.port, port, "same port after the reset")
        XCTAssertTrue(spin(until: { self.events.contains { if case .connectionReset(RaopServer.resetReasonFeedbackTimeout) = $0 { return true }; return false } }))
        XCTAssertEqual(states(events, from: .streaming), .idle)
        let back = try Client(port: port)
        XCTAssertTrue(back.request("OPTIONS", "*", cseq: 1).contains("200"), "sender re-selects the receiver")
    }

    func testWatchdogDecision() {
        XCTAssertFalse(RaopServer.shouldReset(silence: nil, limit: 15), "no connection open")
        XCTAssertFalse(RaopServer.shouldReset(silence: 14.9, limit: 15))
        XCTAssertTrue(RaopServer.shouldReset(silence: 15.1, limit: 15))
        XCTAssertFalse(RaopServer.shouldReset(silence: 999, limit: 0), "0 = never, as stock -reset 0")
    }

    func testFeedbackKeepsConnectionAlive() throws {
        let s = try makeServer("02:11:22:33:44:83") { $0.feedbackLimit = 1 }
        defer { s.stop() }
        let a = try Client(port: s.port)
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 1).contains("200"))
        let c = RaopServer.makeCallbacks()
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            c.conn_feedback!(s.callbackContext)   // what /feedback every 2 s does (faster here)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(s.listenerResets, 0)
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 2).contains("200"))
    }

    // MARK: reconnect via the real thunks

    func testConnResetFromMirrorThreadRestartsListener() throws {
        let s = try makeServer("02:11:22:33:44:84")
        defer { s.stop() }
        let port = s.port
        let a = try Client(port: port)
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 1).contains("200"))
        let c = RaopServer.makeCallbacks()
        let ctx = s.callbackContext
        // UxPlay calls conn_reset on the mirror thread (lost connection); a burst coalesces.
        let done = DispatchSemaphore(value: 0)
        let t = Thread { for _ in 0..<3 { c.conn_reset!(ctx, 1) }; done.signal() }
        t.start()
        done.wait()   // the burst lands before the main queue runs the hop
        XCTAssertTrue(spin(until: { s.listenerResets == 1 }))
        spin(until: { false }, timeout: 0.3)
        XCTAssertEqual(s.listenerResets, 1, "one reset per burst")
        XCTAssertTrue(a.isClosedByServer())
        let b = try Client(port: port)
        XCTAssertTrue(b.request("OPTIONS", "*", cseq: 1).contains("200"))
        XCTAssertEqual(states(events, from: .streaming), .idle)
    }

    func testRepeatedConnInitDestroyResetCycles() throws {
        let pipeline = VideoPipeline(render: false)
        let s = try makeServer("02:11:22:33:44:85")
        defer { s.stop() }
        s.videoSink = pipeline
        let c = RaopServer.makeCallbacks()
        let ctx = s.callbackContext
        let units = try Self.units("synthetic-1080p.h264")
        var state = ReceiverState.idle
        for cycle in 0..<10 {
            events.removeAll()
            c.conn_init!(ctx)
            c.mirror_video_running!(ctx, true)
            for u in units.prefix(15) {
                u.withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: false) }
            }
            pipeline.decoder.waitForFrames()
            XCTAssertEqual(pipeline.stats.total().decoded, 15, "cycle \(cycle): fresh SPS decodes from frame 0")
            if cycle % 2 == 0 {
                c.mirror_video_running!(ctx, false)   // clean TEARDOWN
                c.conn_destroy!(ctx)
            } else {
                c.conn_reset!(ctx, 1)                 // dropped mid-stream
                XCTAssertTrue(spin(until: { s.listenerResets == (cycle + 1) / 2 }))
                c.conn_destroy!(ctx)
            }
            XCTAssertTrue(spin(until: { self.events.contains { if case .connectionClosed = $0 { return true }; return false } }))
            state = states(events, from: .idle)
            XCTAssertEqual(state, .idle, "cycle \(cycle) ends idle")
            XCTAssertEqual(s.openConnectionCount, 0)
            XCTAssertNil(pipeline.decoder.dimensions, "decoder state dropped between sessions")
        }
        XCTAssertTrue(s.isRunning)
        let a = try Client(port: s.port)
        XCTAssertTrue(a.request("OPTIONS", "*", cseq: 1).contains("200"), "still accepting after 10 cycles")
    }

    /// Teardown while the mirror thread is mid-frame, then a reconnect at another resolution
    /// that starts mid-GOP: the late P-frames are dropped and the new SPS takes over.
    func testTeardownMidStreamThenFreshSPSAtNewResolution() throws {
        let pipeline = VideoPipeline(render: false)
        let s = try makeServer("02:11:22:33:44:86")
        defer { s.stop() }
        s.videoSink = pipeline
        let c = RaopServer.makeCallbacks()
        let ctx = s.callbackContext
        let hd = try Self.units("synthetic-1080p.h264")
        let res = try Self.units("synthetic-res-change.h264")

        c.conn_init!(ctx)
        c.mirror_video_running!(ctx, true)
        let feeding = expectation(description: "feeder done")
        let feeder = Thread {
            for u in hd + hd {
                u.withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: false) }
            }
            feeding.fulfill()
        }
        feeder.start()
        Thread.sleep(forTimeInterval: 0.02)
        c.mirror_video_running!(ctx, false)   // teardown races the feeder
        c.conn_reset!(ctx, 1)
        wait(for: [feeding], timeout: 20)
        XCTAssertTrue(spin(until: { s.listenerResets == 1 }))
        c.conn_destroy!(ctx)
        pipeline.decoder.waitForFrames()

        // Reconnect: new session, 720p half of the res-change fixture, joined two frames late.
        let idx720 = try XCTUnwrap(res.firstIndex { u in
            let au = VideoFormat.accessUnit(u)
            guard let sps = au.sps, let pps = au.pps, let fd = try? VideoFormat.formatDescription(sps: sps, pps: pps) else { return false }
            return VideoFormat.dimensions(fd).width == 1280
        })
        let second = Array(res[(idx720 + 1)...].prefix(2)) + Array(res[idx720...])
        c.conn_init!(ctx)
        c.mirror_video_running!(ctx, true)
        let sizes = NSMutableArray()
        pipeline.decoder.onFrame = { pb, _ in sizes.add(CVPixelBufferGetWidth(pb)) }
        for u in second {
            u.withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: false) }
        }
        pipeline.decoder.waitForFrames()
        let st = pipeline.stats.total()
        XCTAssertEqual(st.decodeDropped, 2, "P-frames before the new SPS are dropped")
        XCTAssertEqual(sizes.count, res.count - idx720)
        XCTAssertEqual(Set(sizes.compactMap { $0 as? Int }), [1280])
        XCTAssertEqual(st.decodeErrors, 0)
    }

    // MARK: malformed video (fuzz)

    func testHandleVideoFuzz() throws {
        let pipeline = VideoPipeline(render: false)
        let s = RaopServer()
        s.videoSink = pipeline
        pipeline.videoSessionBegan()
        let units = try Self.units("synthetic-1080p.h264")
        var rng = SplitMix(seed: 0xA1B2)

        func feed(_ b: [UInt8]) {
            b.withUnsafeBufferPointer { s.handleVideo($0.baseAddress!, $0.count, nalCount: 1, h265: false) }
        }
        // Truncated real frames (incl. a cut SPS/PPS and cut start codes).
        for u in units.prefix(30) {
            let b = [UInt8](u)
            for _ in 0..<4 { feed(Array(b.prefix(Int(rng.next() % UInt64(b.count)) + 1))) }
        }
        // Pure garbage, and garbage behind valid start codes of every NAL type.
        for _ in 0..<300 {
            let n = Int(rng.next() % 4096) + 1
            var b = (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            if rng.next() % 2 == 0, n > 5 { b[0] = 0; b[1] = 0; b[2] = 0; b[3] = 1; b[4] = UInt8(rng.next() % 32) }
            feed(b)
        }
        // Bogus parameter sets, then a slice.
        for t: UInt8 in [0x67, 0x68] {
            feed([0, 0, 0, 1, t] + (0..<20).map { _ in UInt8(truncatingIfNeeded: rng.next()) } + [0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00])
        }
        // Tiny, start-code-only and oversized buffers.
        for b: [UInt8] in [[0], [0, 0, 0, 1], [0, 0, 1], [0, 0, 0, 1, 0, 0, 0, 1], [0, 0, 0, 1, 0x80]] { feed(b) }
        var big = [UInt8](repeating: 0xAB, count: RaopServer.maxVideoBufferBytes + 1)
        big[0] = 0; big[1] = 0; big[2] = 0; big[3] = 1; big[4] = 0x65
        feed(big)
        // Zero length must not even be read.
        s.handleVideo(UnsafePointer(bitPattern: 0x1)!, 0, nalCount: 0, h265: false)
        pipeline.decoder.waitForFrames()

        // A clean stream afterwards decodes completely: nothing was left wedged.
        pipeline.videoSessionEnded()
        pipeline.videoSessionBegan()
        for u in units {
            u.withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: false) }
        }
        pipeline.decoder.waitForFrames()
        XCTAssertEqual(pipeline.stats.total().decoded, units.count)
        XCTAssertEqual(pipeline.decoder.dimensions?.width, 1920)
    }

    // MARK: display sleep

    func testDisplaySleepAssertionHeldOnlyWhileStreaming() throws {
        XCTAssertTrue(DisplaySleepGuard.shouldHold(.streaming))
        for st in [ReceiverState.stopped, .idle, .pairing] { XCTAssertFalse(DisplaySleepGuard.shouldHold(st)) }

        let name = "AirTV M8 test \(UUID().uuidString.prefix(8))"
        let g = DisplaySleepGuard(name: name)
        XCTAssertTrue(g.hold(true))
        XCTAssertTrue(g.hold(true), "idempotent")
        let during = try pmsetAssertions()
        XCTAssertTrue(during.contains("PreventUserIdleDisplaySleep named: \"\(name)\""), during)
        g.hold(false)
        XCTAssertFalse(g.isHeld)
        XCTAssertFalse(try pmsetAssertions().contains(name), "restored after streaming")
    }

    func pmsetAssertions() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

/// Deterministic PRNG for the fuzz test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
