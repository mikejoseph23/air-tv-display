import AppKit

/// Fullscreen borderless window on the main screen. Esc quits (only if enabled in Settings), "h" toggles the perf HUD.
/// It covers the menu bar, so ⌘, (Settings), ⌘Q and a right-click menu are handled here.
/// Content: the Metal video surface, with the "waiting" label on top whenever no stream is
/// running.
final class ReceiverWindow: NSWindow {
    private let label = NSTextField(labelWithString: "Waiting for AirPlay…")
    private let hint = NSTextField(labelWithString: "Right-click or \u{2318}, for Settings")
    private let video: VideoPipeline?
    private var hud: VideoHUD?
    private let onShowSettings: () -> Void

    init(video: VideoPipeline? = nil, showHUD: Bool = false, onShowSettings: @escaping () -> Void = {}) {
        self.video = video
        self.onShowSettings = onShowSettings
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .mainMenu + 1
        backgroundColor = .black
        isOpaque = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: frame)
        content.wantsLayer = true
        if let layer = video?.renderer?.layer {
            content.addSubview(VideoView(frame: content.bounds, layer: layer))
        }
        label.font = .systemFont(ofSize: 40, weight: .light)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        hint.font = .systemFont(ofSize: 16, weight: .regular)
        hint.textColor = .gray
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
        ])
        if let video {
            let h = VideoHUD(stats: video.stats)
            content.addSubview(h.view)
            NSLayoutConstraint.activate([
                h.view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                h.view.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            ])
            hud = h
        }
        contentView = content
        if showHUD { hud?.setVisible(true) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { if AppSettings.shared.escQuits { NSApp.terminate(nil) } }
        else if event.charactersIgnoringModifiers == "h" { toggleHUD() }
        else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case ",": onShowSettings(); return true
        case "q": NSApp.terminate(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Toggle Diagnostics (H)", action: #selector(menuToggleHUD), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: contentView ?? NSView())
    }

    @objc private func menuSettings() { onShowSettings() }
    @objc private func menuToggleHUD() { toggleHUD() }

    func toggleHUD() { hud?.toggle() }

    func present() {
        if let screen = NSScreen.main { setFrame(screen.frame, display: true) }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setState(_ state: ReceiverState) {
        label.isHidden = state == .streaming
        hint.isHidden = label.isHidden
        label.stringValue = "Waiting for AirPlay…"
        // Sender gone without a mirror teardown (reset / last connection closed): blank the
        // last frame so the waiting view is not drawn over a stale picture.
        if state == .idle || state == .stopped { video?.clearScreen() }
    }

    /// Fixture playback: show the video without a receiver state change.
    func showVideoOnly() { label.isHidden = true }
}
