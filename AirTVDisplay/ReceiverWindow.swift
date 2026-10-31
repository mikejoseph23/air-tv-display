import AppKit

/// Fullscreen borderless window on the main screen. Esc quits, "h" toggles the perf HUD.
/// Content: the Metal video surface, with the "waiting" label on top whenever no stream is
/// running.
final class ReceiverWindow: NSWindow {
    private let label = NSTextField(labelWithString: "waiting for AirPlay…")
    private let video: VideoPipeline?
    private var hud: VideoHUD?

    init(video: VideoPipeline? = nil, showHUD: Bool = false) {
        self.video = video
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
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
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
        if event.keyCode == 53 { NSApp.terminate(nil) }
        else if event.charactersIgnoringModifiers == "h" { toggleHUD() }
        else { super.keyDown(with: event) }
    }

    func toggleHUD() { hud?.toggle() }

    func present() {
        if let screen = NSScreen.main { setFrame(screen.frame, display: true) }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setState(_ state: ReceiverState) {
        label.isHidden = state == .streaming
        label.stringValue = "waiting for AirPlay…"
        // Sender gone without a mirror teardown (reset / last connection closed): blank the
        // last frame so the waiting view is not drawn over a stale picture.
        if state == .idle || state == .stopped { video?.clearScreen() }
    }

    /// Fixture playback: show the video without a receiver state change.
    func showVideoOnly() { label.isHidden = true }
}
