import AppKit

final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let receiver: ReceiverController
    private let onShowWindow: () -> Void
    private let stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let addrLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "", action: #selector(toggleReceiver), keyEquivalent: "")

    init(receiver: ReceiverController, onShowWindow: @escaping () -> Void) {
        self.receiver = receiver
        self.onShowWindow = onShowWindow
        super.init()
        let menu = NSMenu()
        menu.addItem(stateLine)
        menu.addItem(addrLine)
        menu.addItem(.separator())
        toggle.target = self
        menu.addItem(toggle)
        let show = NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
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

    @objc private func showWindow() { onShowWindow() }
}
