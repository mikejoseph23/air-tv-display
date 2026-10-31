import AppKit

final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let receiver: ReceiverController
    private let onShowWindow: () -> Void
    private let onToggleHUD: () -> Void
    private let stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let addrLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "", action: #selector(toggleReceiver), keyEquivalent: "")

    init(receiver: ReceiverController, onShowWindow: @escaping () -> Void, onToggleHUD: @escaping () -> Void) {
        self.receiver = receiver
        self.onShowWindow = onShowWindow
        self.onToggleHUD = onToggleHUD
        super.init()
        let menu = NSMenu()
        menu.addItem(stateLine)
        menu.addItem(addrLine)
        menu.addItem(.separator())
        toggle.target = self
        menu.addItem(toggle)
        let reset = NSMenuItem(title: "Reset Connection", action: #selector(resetConnection), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let show = NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        // Same as pressing H in the receiver window.
        let hud = NSMenuItem(title: "Toggle Diagnostics (H)", action: #selector(toggleHUD), keyEquivalent: "")
        hud.target = self
        menu.addItem(hud)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        refresh()
    }

    func refresh() {
        let s = receiver.state
        stateLine.title = "State: \(s == .stopped ? "stopped" : s.rawValue)"
        addrLine.title = "\(receiver.serviceName) \u{2013} \(receiver.ipAddress):\(receiver.port)"
        toggle.title = receiver.isRunning ? "Stop Receiver" : "Start Receiver"
        item.button?.title = receiver.isRunning ? "AirTV \u{25CF}" : "AirTV \u{25CB}"
    }

    @objc private func toggleReceiver() {
        receiver.isRunning ? receiver.stop() : receiver.start()
        refresh()
    }

    @objc private func resetConnection() { receiver.resetConnections(); refresh() }

    @objc private func showWindow() { onShowWindow() }

    @objc private func toggleHUD() { onToggleHUD() }
}
