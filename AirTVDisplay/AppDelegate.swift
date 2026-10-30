import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: ReceiverWindow?
    private var statusController: StatusItemController?
    private let receiver = ReceiverController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let selfTest = args.contains("--selftest")

        // Prove the bridged C library links and runs.
        print("[bridge] \(UxPlayBridge.selfCheck())")

        if !selfTest { showWindow() }
        statusController = StatusItemController(receiver: receiver, onShowWindow: { [weak self] in self?.showWindow() })

        receiver.onStateChange = { [weak self] state in
            print("[state] \(state.rawValue)")
            self?.statusController?.refresh()
            self?.window?.setState(state)
        }
        if args.contains("--autostart") { receiver.start() }

        if selfTest {
            // Exercise start -> stop -> start (restart safety), then hold the server up for
            // `--selftest-seconds N` (default 6) so it can be probed from the shell.
            let hold = args.firstIndex(of: "--selftest-seconds").flatMap { i in
                i + 1 < args.count ? Double(args[i + 1]) : nil } ?? 6
            receiver.start()
            receiver.stop()
            receiver.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                print("[selftest] state=\(self.receiver.state) name=\(self.receiver.serviceName) port=\(self.receiver.port) ip=\(self.receiver.ipAddress) pk=\(self.receiver.publicKeyHex)")
                self.receiver.stop()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { receiver.stop() }

    private func showWindow() {
        if window == nil { window = ReceiverWindow() }
        window?.present()
    }
}
