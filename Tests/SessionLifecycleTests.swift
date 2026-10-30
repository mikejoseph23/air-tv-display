import Darwin
import XCTest

/// M4T: the Swift `raop_callbacks_t` thunks under sender reconnects. Real TCP connections to an
/// in-process `RaopServer` make UxPlay's httpd thread call the real `conn_init`/`conn_destroy`
/// thunks; `ReceiverStateMachine` is driven from the events they emit, as `ReceiverController`
/// does. Leak checks use weak references (and `scripts/leaks-session-tests.sh` for `leaks`).
final class SessionLifecycleTests: XCTestCase {

    /// Records events on the main queue (where `RaopServer.emit` delivers them).
    final class Recorder {
        var events: [RaopEvent] = []
        var state = ReceiverState.idle
        var states: [ReceiverState] = [.idle]

        var opened: [Int] { events.compactMap { if case .connectionOpened(let n) = $0 { return n }; return nil } }
        var closed: [Int] { events.compactMap { if case .connectionClosed(let n) = $0 { return n }; return nil } }

        func attach(_ s: RaopServer) {
            s.onEvent = { [unowned self] e in
                self.events.append(e)
                let next = ReceiverStateMachine.next(self.state, e)
                if next != self.state { self.states.append(next) }
                self.state = next
            }
        }
    }

    // MARK: helpers

    static func connectTCP(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        return fd
    }

    /// Spins the main run loop (event delivery) until `cond` holds or `timeout` passes.
    @discardableResult
    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Lets queued `DispatchQueue.main.async` emits run.
    func drainMain(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func makeServer(_ id: String) throws -> RaopServer {
        let s = RaopServer()
        try s.start(name: "M4T Test", port: 0, deviceID: id, advertise: false)
        XCTAssertGreaterThan(s.port, 0)
        return s
    }

    // MARK: reconnects through the real thunks

    /// A sender that connects, drops, and reconnects 25 times: every conn_init is matched by a
    /// conn_destroy, the open count never goes negative, and the state machine goes
    /// idle -> pairing -> idle each time.
    func testRepeatedReconnectsBalanceOpenCountAndState() throws {
        let s = try makeServer("02:4d:54:00:00:01")
        defer { s.stop() }
        let r = Recorder(); r.attach(s)
        let cycles = 25
        for i in 1...cycles {
            let fd = try Self.connectTCP(s.port)
            waitUntil("open #\(i)") { r.opened.count == i }
            XCTAssertEqual(r.opened.last, 1)
            XCTAssertEqual(r.state, .pairing)
            Darwin.close(fd)
            waitUntil("close #\(i)") { r.closed.count == i }
            XCTAssertEqual(r.closed.last, 0)
            XCTAssertEqual(r.state, .idle)
        }
        XCTAssertEqual(r.states, Array(repeating: [ReceiverState.idle, .pairing], count: cycles).flatMap { $0 } + [.idle])
    }

    /// Overlapping connections closed in non-LIFO order (AirPlay senders open the RTSP control
    /// connection plus event/data sockets and drop them in any order). The state only returns
    /// to idle when the last one closes.
    func testInterleavedConnectionsClosedOutOfOrder() throws {
        let s = try makeServer("02:4d:54:00:00:02")
        defer { s.stop() }
        let r = Recorder(); r.attach(s)

        var fds: [String: Int32] = [:]
        for name in ["a", "b", "c"] {
            fds[name] = try Self.connectTCP(s.port)
            let want = fds.count
            waitUntil("open \(name)") { r.opened.count == want }
        }
        XCTAssertEqual(r.opened, [1, 2, 3])

        // close b, open d, close a, close c, close d
        Darwin.close(fds["b"]!)
        waitUntil("close b") { r.closed.count == 1 }
        XCTAssertEqual(r.state, .pairing)
        fds["d"] = try Self.connectTCP(s.port)
        waitUntil("open d") { r.opened.count == 4 }
        for (k, name) in ["a", "c", "d"].enumerated() {
            Darwin.close(fds[name]!)
            waitUntil("close \(name)") { r.closed.count == k + 2 }
            XCTAssertEqual(r.state, name == "d" ? .idle : .pairing, "after closing \(name)")
        }
        XCTAssertEqual(r.opened, [1, 2, 3, 3])
        XCTAssertEqual(r.closed, [2, 2, 1, 0])
    }

    /// More sockets than httpd's 12-connection limit, closed in random order from several
    /// threads at once: every accepted connection is destroyed exactly once and the count
    /// settles at 0 (no lost or double decrements in the thunks' locking).
    func testConcurrentChurnPastConnectionLimit() throws {
        let s = try makeServer("02:4d:54:00:00:03")
        defer { s.stop() }
        let r = Recorder(); r.attach(s)
        let port = s.port

        let group = DispatchGroup()
        let errors = NSLock()
        var connectErrors = 0
        for _ in 0..<4 {
            DispatchQueue.global().async(group: group) {
                var rng = SystemRandomNumberGenerator()
                for _ in 0..<10 {
                    var held: [Int32] = []
                    for _ in 0..<Int.random(in: 1...4, using: &rng) {
                        if let fd = try? Self.connectTCP(port) { held.append(fd) } else {
                            errors.lock(); connectErrors += 1; errors.unlock()
                        }
                    }
                    usleep(useconds_t(Int.random(in: 0...20_000, using: &rng)))
                    for fd in held.shuffled(using: &rng) { Darwin.close(fd) }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        // httpd's select loop wakes at least every ~1 s; queued accepts drain after closes.
        waitUntil("all connections destroyed", timeout: 15) {
            !r.opened.isEmpty && r.closed.count == r.opened.count && r.closed.last == 0
        }
        drainMain(1.2)   // nothing late
        XCTAssertEqual(r.closed.count, r.opened.count)
        XCTAssertEqual(r.closed.last, 0)
        XCTAssertTrue(r.opened.allSatisfy { (1...12).contains($0) }, "\(r.opened)")
        XCTAssertTrue(r.closed.allSatisfy { $0 >= 0 })
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(connectErrors, 0)
    }

    /// stop() with live connections: httpd destroys them during raop_destroy, so conn_destroy
    /// thunks run while the server is tearing down. Events that land after stop must not move
    /// a stopped receiver, and the same instance restarts and accepts new connections.
    func testStopWithOpenConnectionsThenRestart() throws {
        let s = try makeServer("02:4d:54:00:00:04")
        let r = Recorder(); r.attach(s)
        let fds = try (0..<3).map { _ in try Self.connectTCP(s.port) }
        waitUntil("3 open") { r.opened.count == 3 }

        s.stop()
        r.state = .stopped   // what ReceiverController.stop() does
        drainMain(0.3)
        XCTAssertEqual(r.closed.count, 3, "httpd destroyed every open connection on stop")
        XCTAssertEqual(r.closed.last, 0)
        XCTAssertEqual(r.state, .stopped, "stale events ignored after stop")
        fds.forEach { Darwin.close($0) }
        XCTAssertFalse(s.isRunning)

        try s.start(name: "M4T Test", port: 0, deviceID: "02:4d:54:00:00:04", advertise: false)
        defer { s.stop() }
        r.events.removeAll(); r.state = .idle
        let fd = try Self.connectTCP(s.port)
        waitUntil("open after restart") { r.opened == [1] }
        XCTAssertEqual(r.state, .pairing)
        Darwin.close(fd)
        waitUntil("close after restart") { r.closed == [0] }
        XCTAssertEqual(r.state, .idle)
    }

    /// A peer that sends half an RTSP request and vanishes, and one that sends garbage.
    func testPartialAndGarbageRequestsThenDisconnect() throws {
        let s = try makeServer("02:4d:54:00:00:05")
        defer { s.stop() }
        let r = Recorder(); r.attach(s)
        let payloads: [String] = ["GET /info RTSP/1.0\r\nCSeq: 1\r\nContent-Len", "\u{1}\u{2}garbage\r\n\r\n\r\n"]
        for (i, p) in payloads.enumerated() {
            let fd = try Self.connectTCP(s.port)
            waitUntil("open \(i)") { r.opened.count == i + 1 }
            _ = p.withCString { send(fd, $0, strlen($0), 0) }
            usleep(50_000)
            Darwin.close(fd)
            waitUntil("close \(i)") { r.closed.count == i + 1 }
        }
        XCTAssertEqual(r.closed, [0, 0])
        XCTAssertEqual(r.state, .idle)
        XCTAssertTrue(s.isRunning)
    }

    // MARK: leaks

    /// After connection churn, video, and stop, nothing keeps the server alive (the C side
    /// holds it unretained; emits capture it weakly).
    func testServerIsReleasedAfterSessions() throws {
        weak var weakServer: RaopServer?
        try autoreleasepool {
            let s = try makeServer("02:4d:54:00:00:06")
            weakServer = s
            let r = Recorder(); r.attach(s)
            for i in 1...5 {
                let fd = try Self.connectTCP(s.port)
                waitUntil("open \(i)") { r.opened.count == i }
                Darwin.close(fd)
                waitUntil("close \(i)") { r.closed.count == i }
            }
            for u in try PairingFairPlayTests.accessUnits("synthetic-1080p.h264").prefix(5) {
                u.withUnsafeBytes { s.handleVideo($0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nalCount: 1, h265: false) }
            }
            s.stop()
        }
        drainMain()
        XCTAssertNil(weakServer, "RaopServer leaked")
    }

    /// Dropping the last reference while a sender is still connected: deinit -> stop() ->
    /// raop_destroy calls the conn_destroy thunk on the deinitialising object. Must not crash,
    /// and the queued emits (weak self) must be no-ops.
    func testDeinitWithOpenConnectionsDoesNotCrash() throws {
        weak var weakServer: RaopServer?
        var delivered = 0
        var fds: [Int32] = []
        try autoreleasepool {
            let s = try makeServer("02:4d:54:00:00:07")
            weakServer = s
            s.onEvent = { _ in delivered += 1 }
            fds = try (0..<2).map { _ in try Self.connectTCP(s.port) }
            waitUntil("2 open") { delivered == 2 }
        }
        XCTAssertNil(weakServer, "RaopServer leaked")
        drainMain()
        XCTAssertEqual(delivered, 2, "events after deinit are dropped")
        fds.forEach { Darwin.close($0) }
    }

    /// Start/stop cycles on one instance, with redundant stops.
    func testRepeatedStartStopIsClean() throws {
        let s = RaopServer()
        for i in 0..<5 {
            try s.start(name: "M4T Test", port: 0, deviceID: "02:4d:54:00:00:08", advertise: false)
            XCTAssertTrue(s.isRunning, "cycle \(i)")
            s.stop(); s.stop()   // double stop is a no-op
            XCTAssertFalse(s.isRunning)
            XCTAssertEqual(s.port, 0)
        }
    }

    // MARK: state machine under out-of-order events

    /// Event orders a reconnecting sender (or a racing httpd thread) can produce.
    func testStateMachineOutOfOrderEvents() {
        typealias M = ReceiverStateMachine
        // Destroy before any init, and teardown events while already idle: stay idle.
        XCTAssertEqual(M.next(.idle, .connectionClosed(open: 0)), .idle)
        XCTAssertEqual(M.next(.idle, .mirrorRunning(false)), .idle)
        XCTAssertEqual(M.next(.idle, .connectionReset(reason: 0)), .idle)
        XCTAssertEqual(M.next(.idle, .videoDecryptFailed), .idle)
        // A stale close carrying open>0 (other sockets still up) does not drop to idle.
        XCTAssertEqual(M.next(.pairing, .connectionClosed(open: 1)), .pairing)
        // mirror_video_running(true) before conn_init's event is delivered.
        XCTAssertEqual(M.next(.idle, .mirrorRunning(true)), .pairing)
        // A frame before any connection event still means streaming.
        XCTAssertEqual(M.next(.idle, .videoStarted(nals: "")), .streaming)
        // Reconnect during a stream: new conn_init keeps streaming; old socket closing to 0 -> idle.
        var s = ReceiverState.streaming
        s = M.next(s, .connectionOpened(open: 2)); XCTAssertEqual(s, .streaming)
        s = M.next(s, .connectionClosed(open: 0)); XCTAssertEqual(s, .idle)
        s = M.next(s, .connectionOpened(open: 1)); XCTAssertEqual(s, .pairing)
        s = M.next(s, .mirrorRunning(true)); XCTAssertEqual(s, .pairing)
        s = M.next(s, .videoStarted(nals: "")); XCTAssertEqual(s, .streaming)
        // Reset, then the late destroy of the reset connection.
        s = M.next(s, .connectionReset(reason: 1)); XCTAssertEqual(s, .idle)
        s = M.next(s, .connectionClosed(open: 0)); XCTAssertEqual(s, .idle)
    }

    /// Random event sequences: never reaches `stopped`, `stopped` is absorbing, and the
    /// teardown events always land on the documented state.
    func testStateMachineRandomSequencesInvariants() {
        var rng = SystemRandomNumberGenerator()
        let all: [RaopEvent] = [
            .connectionOpened(open: 1), .connectionOpened(open: 3), .connectionClosed(open: 0), .connectionClosed(open: 2),
            .clientRequest(name: "n", model: "m", deviceID: "d"), .mirrorRunning(true), .mirrorRunning(false),
            .connectionReset(reason: 0), .videoStarted(nals: ""), .videoDecryptFailed,
        ]
        for _ in 0..<500 {
            var s = ReceiverState.idle
            for _ in 0..<30 {
                let e = all.randomElement(using: &rng)!
                let n = ReceiverStateMachine.next(s, e)
                XCTAssertNotEqual(n, .stopped)
                switch e {
                case .connectionClosed(let open) where open == 0: XCTAssertEqual(n, .idle)
                case .connectionReset: XCTAssertEqual(n, .idle)
                case .videoStarted: XCTAssertEqual(n, .streaming)
                case .videoDecryptFailed: XCTAssertEqual(n, s)
                default: break
                }
                XCTAssertEqual(ReceiverStateMachine.next(.stopped, e), .stopped)
                s = n
            }
        }
    }
}
