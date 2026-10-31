// SPDX-License-Identifier: MIT
import Foundation
import QuartzCore

enum RaopError: Error, CustomStringConvertible {
    case badDeviceID(String)
    case dnssdInit(Int32)
    case raopInit
    case raopInit2
    case httpdStart(Int32, UInt16)
    case register(service: String, code: Int32)

    var description: String {
        switch self {
        case .badDeviceID(let s): return "bad deviceid \(s)"
        case .dnssdInit(let e): return "dnssd_init failed (\(e))"
        case .raopInit: return "raop_init failed"
        case .raopInit2: return "raop_init2 failed"
        case .httpdStart(let r, let p): return "raop_start_httpd failed (\(r)) on port \(p)"
        case .register(let s, let c): return "DNS-SD register \(s) failed (\(c))"
        }
    }
}

/// Events surfaced from UxPlay's threads; delivered on the main queue.
enum RaopEvent {
    case connectionOpened(open: Int)
    case connectionClosed(open: Int)
    case clientRequest(name: String, model: String, deviceID: String)
    case mirrorRunning(Bool)
    /// UxPlay's conn_reset (1 = network error, 2 = unsupported HLS) or one of ours
    /// (`RaopServer.resetReasonFeedbackTimeout`); the server restarts its listener after it.
    case connectionReset(reason: Int32)
    /// First decrypted video buffer of a mirror session (summary of its NAL units).
    case videoStarted(nals: String)
    /// First buffer of a session that UxPlay flagged as failed decrypt / bad NAL lengths.
    case videoDecryptFailed
}

/// Owns one UxPlay RAOP/AirPlay server plus its DNS-SD advertisement, set up the same way
/// stock `uxplay` does it (uxplay.cpp: start_dnssd -> start_raop_server -> register_dnssd),
/// so the TXT records, the `pk` (Ed25519 key derived from the deviceid) and the advertised
/// port all come from the live raop instance. Each `start()` builds fresh instances, and
/// `stop()` tears them down in reverse; both are safe to call repeatedly.
final class RaopServer {
    /// Stock uxplay defaults: no HLS, no h265, no legacy pairing, no pin.
    static let stockFeatures: UInt64 = 0x527F_FEE6

    private(set) var port: UInt16 = 0
    private(set) var isRunning = false
    private(set) var publicKeyHex = ""

    var onEvent: ((RaopEvent) -> Void)?
    /// M5: decrypted mirror video goes here (decode + present). Called on the mirror thread.
    weak var videoSink: VideoSink? { didSet { videoSink?.attach(avSync: avSync) } }
    /// M8: video-presents-first A/V sync shared by the video sink and `audio`.
    let avSync = AVSync()

    /// Reason passed with `.connectionReset` when the sender went silent (stock: `-reset n`).
    static let resetReasonFeedbackTimeout: Int32 = 100
    /// Reason for an explicit `resetConnections()` (tests, menu).
    static let resetReasonManual: Int32 = 101
    /// Seconds without any sign of life (feedback, RTSP, audio/video data) on an open connection
    /// before the listener is reset, as stock uxplay's `-reset n` (default 15; 0 = never).
    /// Env `AIRTV_RESET_SECONDS`.
    var feedbackLimit: TimeInterval = ProcessInfo.processInfo.environment["AIRTV_RESET_SECONDS"].flatMap(Double.init) ?? 15
    /// Second sender while one is connected: false (stock default) answers 409 Conflict and keeps
    /// the current one; true (`AIRTV_NOHOLD=1`, stock `-nohold`) drops it for the newcomer.
    var noHold = ProcessInfo.processInfo.environment["AIRTV_NOHOLD"] == "1"
    /// Buffers larger than this are not passed to the decoder (a 1080p IDR is ~0.1 to 1 MB).
    static let maxVideoBufferBytes = 16 << 20
    /// Listener resets done (feedback timeout, conn_reset, manual). Main thread.
    private(set) var listenerResets = 0

    private var dnssd: UnsafeMutablePointer<dnssd_t>?
    private var raop: OpaquePointer?
    private var dnssdSources: [DispatchSourceRead] = []

    fileprivate let lock = NSLock()
    fileprivate var openConnections = 0
    fileprivate var videoPackets = 0
    fileprivate var audioPackets = 0
    /// Per mirror session (reset by mirror_video_running(true)); guarded by `lock`.
    fileprivate var session = VideoSession()
    fileprivate var dump: StreamDump?
    /// Last sign of life from a sender (CACurrentMediaTime); guarded by `lock`.
    fileprivate var lastActivity: CFTimeInterval = 0
    private var watchdog: DispatchSourceTimer?
    /// Listener restart failed; retried on each watchdog tick.
    private var listenerDown = false
    fileprivate var resetPending = false
    /// Audio decode + CoreAudio playback (M6). Read its timeline properties from the video path.
    let audio = AudioRenderer { level, msg in RtspLog.shared.log(level, "[audio] " + msg) }

    struct VideoSession {
        var packets = 0
        var valid = 0
        var invalid = 0
        var oversized = 0
        var bytes = 0
        var seenTypes = Set<UInt8>()
    }
    /// How many leading video buffers per session get a full NAL summary in the log.
    static let loggedPacketsPerSession = 5

    init() { audio.avSync = avSync }

    /// The `cls` UxPlay passes to every callback (unretained self).
    var callbackContext: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    deinit { stop() }

    // MARK: lifecycle

    /// `advertise: false` skips the DNS-SD registration (tests): the server still listens
    /// and derives the same pk.
    func start(name: String, port requested: UInt16, deviceID: String, advertise: Bool = true) throws {
        guard !isRunning else { return }
        let hw = deviceID.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard hw.count == 6 else { throw RaopError.badDeviceID(deviceID) }
        do {
            try startDnssd(name: name, hw: hw)
            try startRaop(port: requested, deviceID: deviceID)
            if advertise { try register() }
            startWatchdog()
            dump = StreamDump.fromEnvironment()
            if let dump { log(.info, "stream dump on: first \(dump.seconds)s of each session -> \(dump.fileURL.path)") }
            isRunning = true
            log(.info, "server up name=\"\(name)\" deviceid=\(deviceID) port=\(port) "
                + "features=0x\(String(Self.features(of: dnssd!), radix: 16, uppercase: true)) pk=\(publicKeyHex)")
        } catch {
            log(.err, "start failed: \(error)")
            stop()
            throw error
        }
    }

    func stop() {
        watchdog?.cancel(); watchdog = nil
        listenerDown = false
        for s in dnssdSources { s.cancel() }
        dnssdSources.removeAll()
        if let d = dnssd {
            dnssd_unregister_raop(d)
            dnssd_unregister_airplay(d)
        }
        if let r = raop {
            // raop_destroy -> raop_stop_httpd asserts on a NULL httpd, which is only set by
            // raop_init2; `raop` is only stored once raop_init2 has succeeded.
            raop_destroy(r)
            raop = nil
        }
        if let d = dnssd {
            dnssd_destroy(d)
            dnssd = nil
        }
        if isRunning { log(.info, "server stopped") }
        isRunning = false
        port = 0
        lock.lock()
        openConnections = 0; videoPackets = 0; audioPackets = 0; session = VideoSession(); resetPending = false
        dump?.close(); dump = nil
        lock.unlock()
        audio.stop()
    }

    // MARK: setup steps (mirror uxplay.cpp)

    private func startDnssd(name: String, hw: [UInt8]) throws {
        var err: Int32 = 0
        let hwC = hw.map { CChar(bitPattern: $0) }
        guard let d = dnssd_init(name, Int32(name.utf8.count), hwC, Int32(hwC.count), 0, &err), err == 0 else {
            throw RaopError.dnssdInit(err)
        }
        dnssd = d
        Self.applyStockFeatures(d)
    }

    /// The exact dnssd_set_airplay_features sequence from uxplay.cpp start_dnssd() with
    /// default options. The bare dnssdint.h default is 0x5A7FFEE6; stock clears bit 27
    /// (legacy pairing, off unless -pin/-reg/-pw) and so advertises 0x527FFEE6.
    static func applyStockFeatures(_ d: UnsafeMutablePointer<dnssd_t>,
                                   hls: Bool = false, h265: Bool = false, legacyPairing: Bool = false) {
        let bits: [Int32] = [0, 1, 1, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
                             1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0]
        for (bit, val) in bits.enumerated() { dnssd_set_airplay_features(d, Int32(bit), val) }
        dnssd_set_airplay_features(d, 0, hls ? 1 : 0)
        dnssd_set_airplay_features(d, 4, hls ? 1 : 0)
        dnssd_set_airplay_features(d, 42, h265 ? 1 : 0)
        dnssd_set_airplay_features(d, 27, legacyPairing ? 1 : 0)
    }

    static func features(of d: UnsafeMutablePointer<dnssd_t>) -> UInt64 { dnssd_get_airplay_features(d) }

    private func startRaop(port requested: UInt16, deviceID: String) throws {
        var cbs = Self.makeCallbacks()
        cbs.cls = Unmanaged.passUnretained(self).toOpaque()
        guard let r = raop_init(&cbs) else { throw RaopError.raopInit }
        raop_set_log_callback(r, { _, level, msg in
            guard let msg else { return }
            RtspLog.shared.log(rawLevel: level, String(cString: msg))
        }, nil)
        raop_set_log_level(r, Self.logLevel)
        // nohold=0 (stock default); keyfile "" -> Ed25519 key derived from deviceid, as stock.
        // nohold: stock default 0 (a second sender gets 409); AIRTV_NOHOLD=1 lets it take over.
        if raop_init2(r, noHold ? 1 : 0, deviceID, "") != 0 {
            free(UnsafeMutableRawPointer(r))   // what uxplay does; raop_destroy would assert
            throw RaopError.raopInit2
        }
        raop = r

        // uxplay sets these explicitly (1920x1080 default for h264).
        raop_set_plist(r, "width", 1920)
        raop_set_plist(r, "height", 1080)

        // tcp[0] = mirror data port (dynamic), tcp[1] = RTSP port (fixed); udp all dynamic.
        var tcp: [UInt16] = [0, requested, 0]
        var udp: [UInt16] = [0, 0, 0]
        raop_set_tcp_ports(r, &tcp)
        raop_set_udp_ports(r, &udp)

        var p = raop_get_port(r)
        let rc = raop_start_httpd(r, &p)
        guard rc > 0 else { throw RaopError.httpdStart(rc, requested) }
        raop_set_port(r, p)
        port = p

        guard let d = dnssd else { throw RaopError.raopInit }
        raop_set_dnssd(r, d)   // copies raop's pk_str into dnssd->pk, used by both TXTs
        publicKeyHex = d.pointee.pk.map { String(cString: $0) } ?? ""
    }

    private func register() throws {
        guard let d = dnssd else { return }
        // uxplay: airplay_port = raop_port, so both services advertise the RTSP port.
        var e = dnssd_register_raop(d, port)
        if e != 0 { throw RaopError.register(service: "_raop._tcp", code: e) }
        e = dnssd_register_airplay(d, port)
        if e != 0 { throw RaopError.register(service: "_airplay._tcp", code: e) }

        // The Bonjour client socket must be serviced (DNSServiceProcessResult), as uxplay
        // does with a GLib watch.
        for service in [Int32(DNSSD_SERVICE_RAOP), Int32(DNSSD_SERVICE_AIRPLAY)] {
            let fd = dnssd_get_service_fd(d, service)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            src.setEventHandler { [weak self] in
                guard let self, let d = self.dnssd else { return }
                if dnssd_process_service(d, service) != 0 {
                    self.log(.warning, "dnssd_process_service(\(service)) failed")
                    src.cancel()
                }
            }
            src.resume()
            dnssdSources.append(src)
        }
    }

    /// RAOP log level: `AIRTV_RAOP_LOGLEVEL` (3..8), default 7 (LOGGER_DEBUG, like `uxplay -d`).
    static var logLevel: Int32 {
        if let s = ProcessInfo.processInfo.environment["AIRTV_RAOP_LOGLEVEL"], let v = Int32(s) { return v }
        return 7
    }

    // MARK: reconnect (M8)

    /// Number of RTSP connections UxPlay reports open.
    var openConnectionCount: Int { lock.lock(); defer { lock.unlock() }; return openConnections }

    /// Seconds since the last sign of life on an open connection (nil when none is open).
    func silence(now: CFTimeInterval = CACurrentMediaTime()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return openConnections > 0 ? now - lastActivity : nil
    }

    fileprivate func noteActivity() { lastActivity = CACurrentMediaTime() }   // caller holds `lock`

    /// Watchdog decision, pure for tests: reset when a connection is open and silent too long.
    static func shouldReset(silence: TimeInterval?, limit: TimeInterval) -> Bool {
        guard limit > 0, let silence else { return false }
        return silence > limit
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        t.resume()
        watchdog = t
    }

    func watchdogTick(now: CFTimeInterval = CACurrentMediaTime()) {
        guard isRunning else { return }
        if listenerDown { restartListener(); return }
        let quiet = silence(now: now)
        if Self.shouldReset(silence: quiet, limit: feedbackLimit) {
            log(.warning, "no sign of life from the sender for \(Int(quiet ?? 0))s (limit \(Int(feedbackLimit))s); "
                + "client may be asleep or offline, resetting connections")
            resetConnections(reason: Self.resetReasonFeedbackTimeout)
        }
    }

    /// Drops every connection and restarts the RTSP listener on the same port, as stock uxplay
    /// does after conn_reset or a feedback timeout (raop_stop_httpd / raop_start_httpd). The
    /// sender can then reconnect without the app restarting. Main thread only (it joins
    /// UxPlay's threads, so it must never run on one of them).
    func resetConnections(reason: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock(); resetPending = false; lock.unlock()
        guard isRunning, let r = raop else { return }
        listenerResets += 1
        log(.info, "resetting connections (reason \(reason)), open=\(openConnectionCount)")
        raop_stop_httpd(r)   // closes every connection: conn_destroy, mirror teardown
        raop_remove_known_connections(r)
        videoSink?.videoSessionEnded()
        avSync.reset()
        audio.stop()
        lock.lock(); openConnections = 0; session = VideoSession(); lock.unlock()
        restartListener()
        emit(.connectionReset(reason: reason))
    }

    private func restartListener() {
        guard let r = raop else { return }
        var p = port
        let rc = raop_start_httpd(r, &p)
        if rc > 0 {
            raop_set_port(r, p)
            if listenerDown { log(.info, "listener back up on port \(p)") }
            listenerDown = false
        } else {
            if !listenerDown { log(.err, "listener restart on port \(port) failed (\(rc)); retrying every second") }
            listenerDown = true
        }
    }

    /// conn_reset arrives on UxPlay's mirror thread: hop to main, once per burst.
    fileprivate func scheduleReset(reason: Int32) {
        lock.lock(); let already = resetPending; resetPending = true; lock.unlock()
        guard !already else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let still = self.resetPending; self.lock.unlock()
            if still { self.resetConnections(reason: reason) }
        }
    }

    // MARK: callbacks (log-only for M3; video/audio sinks land in M5/M6)

    fileprivate func log(_ level: RtspLog.Level, _ msg: String) { RtspLog.shared.log(level, "[raop-cb] " + msg) }

    // MARK: video inspection

    /// New mirror session: reset per-session stats and restart the optional dump.
    fileprivate func beginVideoSession() {
        lock.lock(); session = VideoSession(); dump?.beginSession(); noteActivity(); lock.unlock()
        avSync.reset()
        videoSink?.videoSessionBegan()
    }

    fileprivate func endVideoSession() {
        videoSink?.videoSessionEnded()
        lock.lock(); let v = session; lock.unlock()
        guard v.packets > 0 else { return }
        let types = v.seenTypes.sorted().map { AnnexB.typeName($0) }.joined(separator: ",")
        log(.info, "video session end: packets=\(v.packets) decrypted=\(v.valid) failed=\(v.invalid) oversized=\(v.oversized) bytes=\(v.bytes) nalTypes=[\(types)]")
        log(.info, "A/V sync: " + avSync.report().line)
    }

    /// Inspects one `video_process` buffer. UxPlay's mirror thread has already AES-CTR
    /// decrypted it and replaced the 4-byte AVCC lengths with Annex-B start codes; it sets
    /// byte 0 to 0x01 when that failed. Internal (not private) so tests can feed fixtures.
    func handleVideo(_ p: UnsafePointer<UInt8>, _ len: Int, nalCount: Int, h265: Bool, ntpLocal: UInt64 = 0) {
        guard len > 0 else { return }
        let tooBig = len > Self.maxVideoBufferBytes
        let ok = !h265 && !tooBig && AnnexB.looksDecrypted(p, len)
        lock.lock()
        noteActivity()
        session.packets += 1
        session.bytes += len
        if ok { session.valid += 1 } else { session.invalid += 1 }
        if tooBig {
            session.oversized += 1
            if session.oversized <= 3 { log(.warning, "video: \(len)-byte buffer exceeds \(Self.maxVideoBufferBytes); dropped") }
        }
        let n = session.packets, firstValid = ok && session.valid == 1, firstInvalid = !ok && session.invalid == 1
        var nals: [AnnexB.NAL] = []
        if ok && (n <= Self.loggedPacketsPerSession || firstValid || !session.seenTypes.isSuperset(of: [5, 7, 8])) {
            nals = AnnexB.split(UnsafeRawBufferPointer(start: p, count: len)).nals
            let before = session.seenTypes
            session.seenTypes.formUnion(nals.map(\.type))
            if session.seenTypes.isSuperset(of: [5, 7, 8]), !before.isSuperset(of: [5, 7, 8]) {
                log(.info, "video: SPS+PPS+IDR seen by packet #\(n)")
            }
        }
        if ok, let d = dump, d.append(p, len) {
            log(.info, "stream dump done: \(d.bytesWritten) bytes -> \(d.fileURL.path)")
        }
        lock.unlock()
        if ok { videoSink?.videoAccessUnit(p, len, ntpLocal: ntpLocal) }

        if n <= Self.loggedPacketsPerSession {
            let head = (0..<min(8, len)).map { String(format: "%02x", p[$0]) }.joined(separator: " ")
            log(.info, "video #\(n) len=\(len) nals=\(nalCount) h265=\(h265) "
                + (ok ? "decrypted [\(head)] \(AnnexB.summary(nals))" : "NOT decrypted/invalid [\(head)]"))
        }
        if firstValid { emit(.videoStarted(nals: AnnexB.summary(nals))) }
        if firstInvalid && !tooBig { emit(.videoDecryptFailed) }
    }

    fileprivate func emit(_ e: RaopEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    /// Every slot UxPlay can call is filled: many call sites in lib/ invoke the pointer
    /// without a NULL check (see raop_handlers.h, raop_rtp_mirror.c).
    /// Internal so tests can drive the real thunks (`c.conn_reset!(server.callbackContext, 1)`).
    static func makeCallbacks() -> raop_callbacks_t {
        var c = raop_callbacks_t()

        c.conn_init = { cls in
            guard let s = me(cls) else { return }
            s.lock.lock(); s.openConnections += 1; s.noteActivity(); let n = s.openConnections; s.lock.unlock()
            s.log(.info, "conn_init open=\(n)")
            s.emit(.connectionOpened(open: n))
        }
        c.conn_destroy = { cls in
            guard let s = me(cls) else { return }
            s.lock.lock(); s.openConnections = max(0, s.openConnections - 1); let n = s.openConnections; s.lock.unlock()
            if n == 0 { s.audio.stop() }
            s.log(.info, "conn_destroy open=\(n)")
            s.emit(.connectionClosed(open: n))
        }
        c.conn_reset = { cls, reason in
            guard let s = me(cls) else { return }
            s.log(.info, "conn_reset reason=\(reason) (\(reason == 1 ? "lost connection with client" : "unsupported stream"))")
            s.audio.stop()
            s.scheduleReset(reason: reason)   // stock: reset_httpd, so a re-select works
        }
        c.conn_feedback = { cls in
            guard let s = me(cls) else { return }
            s.lock.lock(); s.noteActivity(); s.lock.unlock()
            s.log(.debug, "conn_feedback")
        }

        c.audio_process = { cls, _, data in
            guard let s = me(cls), let d = data?.pointee else { return }
            s.lock.lock(); s.audioPackets += 1; s.noteActivity(); let n = s.audioPackets; s.lock.unlock()
            if n == 1 || n % 500 == 0 {
                s.log(.debug, "audio_process #\(n) ct=\(d.ct) len=\(d.data_len) seq=\(d.seqnum) sync=\(d.sync_status)")
            }
            if let p = d.data { s.audio.process(p, count: Int(d.data_len), ntpLocal: d.ntp_time_local) }
        }
        c.video_process = { cls, _, data in
            guard let s = me(cls), let d = data?.pointee, let p = d.data, d.data_len > 0 else { return }
            s.lock.lock(); s.videoPackets += 1; let n = s.videoPackets; s.lock.unlock()
            if n % 300 == 0 {
                s.log(.debug, "video_process #\(n) h265=\(d.is_h265) nals=\(d.nal_count) len=\(d.data_len)")
            }
            s.handleVideo(p, Int(d.data_len), nalCount: Int(d.nal_count), h265: d.is_h265, ntpLocal: d.ntp_time_local)
        }
        c.video_pause = { cls in me(cls)?.log(.info, "video_pause") }
        c.video_resume = { cls in me(cls)?.log(.info, "video_resume") }
        c.video_reset = { cls, type in
            guard let s = me(cls) else { return }
            s.log(.info, "video_reset type=\(type.rawValue)")
            // nohold takeover: the old sender's connections are being dropped for a new one.
            if type == RESET_TYPE_NOHOLD {
                s.log(.info, "second sender took over (nohold); ending the current session")
                s.endVideoSession()
                s.audio.stop()
                s.emit(.mirrorRunning(false))
            }
        }
        c.video_set_codec_and_size = { cls, codec, ws, hs, xo, yo, w, h in
            me(cls)?.log(.info, "video_set_codec_and_size codec=\(codec.rawValue) source=\(ws)x\(hs) offset=\(xo),\(yo) size=\(w)x\(h)")
            return 0
        }
        c.mirror_video_running = { cls, running in
            me(cls)?.log(.info, "mirror_video_running \(running)")
            if running { me(cls)?.beginVideoSession() } else { me(cls)?.endVideoSession() }
            me(cls)?.emit(.mirrorRunning(running))
        }

        c.audio_flush = { cls in
            me(cls)?.log(.debug, "audio_flush")
            me(cls)?.audio.flush()
        }
        c.video_flush = { cls in me(cls)?.log(.debug, "video_flush") }
        c.audio_set_client_volume = { cls in
            let v = me(cls)?.audio.currentVolumeDB ?? 0
            me(cls)?.log(.debug, "audio_set_client_volume -> \(v)")
            return Double(v)   // uxplay: last volume set (initially 0.0 dB)
        }
        c.audio_set_volume = { cls, v in
            me(cls)?.log(.info, "audio_set_volume \(v)")
            me(cls)?.audio.setVolume(db: v)
        }
        c.audio_set_metadata = { cls, _, len in me(cls)?.log(.debug, "audio_set_metadata len=\(len)") }
        c.audio_set_coverart = { cls, _, len in me(cls)?.log(.debug, "audio_set_coverart len=\(len)") }
        c.audio_stop_coverart_rendering = { cls in me(cls)?.log(.debug, "audio_stop_coverart_rendering") }
        c.audio_remote_control_id = { cls, dacp, ar in
            me(cls)?.log(.debug, "audio_remote_control_id dacp=\(str(dacp)) active_remote=\(str(ar))")
        }
        c.audio_set_progress = { cls, start, curr, end in
            me(cls)?.log(.debug, "audio_set_progress \(start?.pointee ?? 0)/\(curr?.pointee ?? 0)/\(end?.pointee ?? 0)")
        }
        c.audio_get_format = { cls, ct, spf, usingScreen, isMedia, fmt in
            me(cls)?.log(.info, "audio_get_format ct=\(ct?.pointee ?? 0) spf=\(spf?.pointee ?? 0) "
                + "usingScreen=\(usingScreen?.pointee ?? false) isMedia=\(isMedia?.pointee ?? false) "
                + "format=0x\(String(fmt?.pointee ?? 0, radix: 16))")
            if let ct = ct?.pointee { me(cls)?.audio.start(ct: ct) }
        }

        c.report_client_request = { cls, deviceid, model, name, admit in
            let n = str(name), m = str(model), d = str(deviceid)
            me(cls)?.log(.info, "connection request from \(n) (\(m)) deviceID=\(d) -> admit")
            admit?.pointee = true   // no allow/deny list (stock default)
            me(cls)?.emit(.clientRequest(name: n, model: m, deviceID: d))
        }
        c.display_pin = { cls, pin in me(cls)?.log(.info, "display_pin \(str(pin))") }
        c.register_client = { cls, dev, _, name in
            me(cls)?.log(.info, "register_client \(str(name)) deviceID=\(str(dev))")
        }
        c.check_register = { cls, _ in
            me(cls)?.log(.debug, "check_register -> true")
            return true   // stock: no registration list kept
        }
        c.passwd = { cls, len in
            me(cls)?.log(.info, "passwd requested (none set)")
            len?.pointee = 0
            return nil
        }
        c.export_dacp = { cls, ar, dacp in
            me(cls)?.log(.debug, "export_dacp active_remote=\(str(ar)) dacp=\(str(dacp))")
        }

        // HLS player hooks: HLS is not advertised (features bits 0/4 off); log only.
        c.on_video_play = { cls, loc, pos in me(cls)?.log(.info, "on_video_play \(str(loc)) at \(pos)") }
        c.on_video_scrub = { cls, pos in me(cls)?.log(.info, "on_video_scrub \(pos)") }
        c.on_video_rate = { cls, rate in me(cls)?.log(.info, "on_video_rate \(rate)") }
        c.on_video_stop = { cls in me(cls)?.log(.info, "on_video_stop") }
        c.on_video_acquire_playback_info = { cls, info in
            me(cls)?.log(.debug, "on_video_acquire_playback_info")
            if let info {
                info.pointee.duration = -1.0
                info.pointee.position = -1.0
            }
        }
        c.on_video_playlist_remove = { cls in
            me(cls)?.log(.info, "on_video_playlist_remove")
            return 0
        }
        c.get_custom_profile = { cls, profile in
            me(cls)?.log(.debug, "get_custom_profile")
            profile?.pointee = nil
        }
        return c
    }
}

// Free functions so the @convention(c) closures above capture no context.
private func me(_ cls: UnsafeMutableRawPointer?) -> RaopServer? {
    cls.map { Unmanaged<RaopServer>.fromOpaque($0).takeUnretainedValue() }
}
private func str(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "nil" }
private func str(_ p: UnsafeMutablePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "nil" }
