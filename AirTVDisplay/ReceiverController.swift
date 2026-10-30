import Foundation

enum ReceiverState: String { case stopped, idle, pairing, streaming }

/// Owns the receiver lifecycle. In M2 "start" only advertises over Bonjour; the RAOP
/// server (raop_start_httpd etc.) is wired in a later milestone.
final class ReceiverController {
    /// Dev defaults: distinct name and port so we never collide with stock UxPlay (57380).
    var serviceName = "Air TV Display Dev"
    var port: UInt16 = 57391

    private(set) var state: ReceiverState = .stopped { didSet { onStateChange?(state) } }
    var onStateChange: ((ReceiverState) -> Void)?

    private var registrar: BonjourRegistrar?

    var isRunning: Bool { state != .stopped }
    var ipAddress: String { NetworkInfo.primaryIPv4() ?? "unknown" }

    func start() {
        guard registrar == nil else { return }
        let reg = BonjourRegistrar(name: serviceName, port: port, deviceID: NetworkInfo.en0MAC() ?? "02:00:00:00:00:01")
        do {
            try reg.register()
            registrar = reg
            state = .idle
            print("[bonjour] registered \(serviceName) deviceid=\(reg.deviceID) port=\(port)")
        } catch {
            print("[bonjour] registration failed: \(error)")
            reg.unregister()
            state = .stopped
        }
    }

    func stop() {
        registrar?.unregister()
        registrar = nil
        if state != .stopped { state = .stopped }
    }
}
