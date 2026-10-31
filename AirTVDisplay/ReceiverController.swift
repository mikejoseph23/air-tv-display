// SPDX-License-Identifier: MIT
import Foundation
import Network

/// Owns the receiver lifecycle: "start" brings up UxPlay's RAOP server on a fixed port and
/// advertises it with UxPlay's own DNS-SD registration (stock TXT, real pk); "stop" tears
/// both down. Start/stop/restart are safe in any order.
final class ReceiverController {
    /// Advertised name (Settings; AIRTV_NAME overrides).
    var serviceName = AppSettings.shared.deviceName
    /// Fixed RTSP port, advertised in both TXT services. Override with AIRTV_PORT.
    var port: UInt16 = UInt16(ProcessInfo.processInfo.environment["AIRTV_PORT"] ?? "") ?? 7100

    private(set) var state: ReceiverState = .stopped {
        didSet {
            guard state != oldValue else { return }
            sleepGuard.hold(DisplaySleepGuard.shouldHold(state))
            onStateChange?(state)
        }
    }
    var onStateChange: ((ReceiverState) -> Void)?
    /// Network path changed (ethernet <-> Wi-Fi); the status item re-reads `ipAddress`.
    var onNetworkChange: (() -> Void)?
    /// M8: display stays awake while streaming.
    let sleepGuard = DisplaySleepGuard()
    private var pathMonitor: NWPathMonitor?
    private(set) var networkSummary = ""

    private var server: RaopServer?
    /// M5: decode + present target for mirror video.
    weak var videoSink: VideoSink?
    private(set) var deviceID = ""
    var publicKeyHex: String { server?.publicKeyHex ?? "" }

    var isRunning: Bool { state != .stopped }
    var ipAddress: String { NetworkInfo.primaryIPv4() ?? "unknown" }

    func start() {
        guard server == nil else { return }
        deviceID = NetworkInfo.en0MAC() ?? "02:00:00:00:00:01"
        let s = RaopServer()
        s.onEvent = { [weak self] e in self?.handle(e) }
        s.videoSink = videoSink
        s.audio.isMuted = !AppSettings.shared.playAudio
        do {
            try s.start(name: serviceName, port: port, deviceID: deviceID)
            server = s
            state = .idle
            startPathMonitor()
            print("[raop] listening name=\"\(serviceName)\" deviceid=\(deviceID) port=\(s.port) pk=\(s.publicKeyHex) log=\(RtspLog.shared.fileURL.path)")
        } catch {
            print("[raop] start failed: \(error)")
            state = .stopped
        }
    }

    /// Applies a changed name: restarts only if running so the new name is advertised.
    func renameFromSettings() {
        serviceName = AppSettings.shared.deviceName
        guard isRunning else { return }
        stop()
        start()
    }

    /// Applies the audio setting to the live server (and to servers started later).
    func applyAudioSetting() { server?.audio.isMuted = !AppSettings.shared.playAudio }

    func stop() {
        pathMonitor?.cancel(); pathMonitor = nil
        server?.stop()
        server = nil
        state = .stopped
        RtspLog.shared.flush()
    }

    /// Drops the current sender and reopens the listener (menu "Reset Connection").
    func resetConnections() { server?.resetConnections(reason: RaopServer.resetReasonManual) }

    /// Ethernet/Wi-Fi changes: UxPlay listens on all interfaces and mDNSResponder re-announces
    /// the services on the new one by itself, so nothing restarts. An active TCP stream on the
    /// old interface dies; the sender's reconnect (or the feedback watchdog) recovers it.
    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ifs = path.availableInterfaces.map { "\($0.name)(\(Self.kind($0.type)))" }.joined(separator: ",")
            let line = "\(path.status == .satisfied ? "up" : "down") via [\(ifs)]"
            DispatchQueue.main.async {
                guard let self, line != self.networkSummary else { return }
                let first = self.networkSummary.isEmpty
                self.networkSummary = line
                RtspLog.shared.log(first ? .info : .warning, "[net] network \(line), ip=\(self.ipAddress)"
                    + (first ? "" : "; a stream on a dropped interface will reconnect"))
                self.onNetworkChange?()
            }
        }
        m.start(queue: DispatchQueue(label: "net.iadev.airtv.path"))
        pathMonitor = m
    }

    static func kind(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wiredEthernet: return "ethernet"
        case .wifi: return "wifi"
        case .loopback: return "loopback"
        default: return "other"
        }
    }

    private func handle(_ e: RaopEvent) {
        guard server != nil else { return }
        state = ReceiverStateMachine.next(state, e)
    }
}
