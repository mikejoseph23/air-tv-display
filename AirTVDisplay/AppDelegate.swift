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
            self?.statusController?.refresh()
            self?.window?.setState(state)
        }
        if args.contains("--autostart") || selfTest { receiver.start() }

        if selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                print("[selftest] state=\(self.receiver.state) name=\(self.receiver.serviceName) port=\(self.receiver.port) ip=\(self.receiver.ipAddress)")
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
