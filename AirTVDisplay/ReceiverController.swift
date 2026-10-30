import Foundation

enum ReceiverState: String { case stopped, idle, pairing, streaming }

/// Owns the receiver lifecycle: "start" brings up UxPlay's RAOP server on a fixed port and
/// advertises it with UxPlay's own DNS-SD registration (stock TXT, real pk); "stop" tears
/// both down. Start/stop/restart are safe in any order.
final class ReceiverController {
    /// Dev name, distinct from stock UxPlay's "Air TV Display@Mikes-iMac".
    var serviceName = "Air TV Display Dev"
    /// Fixed RTSP port, advertised in both TXT services. Override with AIRTV_PORT.
    var port: UInt16 = UInt16(ProcessInfo.processInfo.environment["AIRTV_PORT"] ?? "") ?? 7100

    private(set) var state: ReceiverState = .stopped { didSet { if state != oldValue { onStateChange?(state) } } }
    var onStateChange: ((ReceiverState) -> Void)?

    private var server: RaopServer?
    private(set) var deviceID = ""
    var publicKeyHex: String { server?.publicKeyHex ?? "" }

    var isRunning: Bool { state != .stopped }
    var ipAddress: String { NetworkInfo.primaryIPv4() ?? "unknown" }

    func start() {
        guard server == nil else { return }
        deviceID = NetworkInfo.en0MAC() ?? "02:00:00:00:00:01"
        let s = RaopServer()
        s.onEvent = { [weak self] e in self?.handle(e) }
        do {
            try s.start(name: serviceName, port: port, deviceID: deviceID)
            server = s
            state = .idle
            print("[raop] listening name=\"\(serviceName)\" deviceid=\(deviceID) port=\(s.port) pk=\(s.publicKeyHex) log=\(RtspLog.shared.fileURL.path)")
        } catch {
            print("[raop] start failed: \(error)")
            state = .stopped
        }
    }

    func stop() {
        server?.stop()
        server = nil
        state = .stopped
        RtspLog.shared.flush()
    }

    private func handle(_ e: RaopEvent) {
        guard server != nil else { return }
        switch e {
        case .connectionOpened, .clientRequest:
            if state == .idle { state = .pairing }
        case .mirrorRunning(let on):
            state = on ? .streaming : .pairing
        case .connectionClosed(let open):
            if open == 0 { state = .idle }
        case .connectionReset:
            state = .idle
        }
    }
}
