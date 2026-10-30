import AppKit

/// Fullscreen borderless window on the main screen. Esc quits. The content view is a
/// placeholder; the render surface is wired in M5.
final class ReceiverWindow: NSWindow {
    private let label = NSTextField(labelWithString: "waiting for AirPlay…")

    init() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .mainMenu + 1
        backgroundColor = .black
        isOpaque = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: frame)
        label.font = .systemFont(ofSize: 40, weight: .light)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { NSApp.terminate(nil) } else { super.keyDown(with: event) }
    }

    func present() {
        if let screen = NSScreen.main { setFrame(screen.frame, display: true) }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setState(_ state: ReceiverState) {
        label.stringValue = state == .streaming ? "streaming" : "waiting for AirPlay…"
    }
}
