import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: ReceiverWindow?
    private var statusController: StatusItemController?
    private let receiver = ReceiverController()
    private lazy var video = VideoPipeline(requireHardware: !CommandLine.arguments.contains("--software-decode"))
    private var fixturePlayer: VideoFixturePlayer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let selfTest = args.contains("--selftest")

        // Prove the bridged C library links and runs.
        print("[bridge] \(UxPlayBridge.selfCheck())")

        if let i = args.firstIndex(of: "--play-fixture"), i + 1 < args.count {
            playFixture(args[i + 1], args: args)
            return
        }
        receiver.videoSink = video
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

    /// `--play-fixture <file> [--fixture-fps N] [--fixture-loops N] [--software-decode]`:
    /// decode + present an Annex-B file fullscreen at a fixed rate, print the figures, exit
    /// (status 1 if any frame failed to decode or the decoder was not hardware).
    private func playFixture(_ path: String, args: [String]) {
        func opt(_ name: String) -> Double? {
            args.firstIndex(of: name).flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil }
        }
        var o = VideoFixturePlayer.Options()
        o.fps = opt("--fixture-fps") ?? 30
        o.loops = Int(opt("--fixture-loops") ?? 1)
        do {
            let player = try VideoFixturePlayer(file: URL(fileURLWithPath: path), pipeline: video, options: o)
            fixturePlayer = player
            showWindow()
            window?.showVideoOnly()
            print("[fixture] \(path): \(player.units.count) access units x \(o.loops) at \(o.fps) fps")
            // Give the window a moment to come up so the first frames have a drawable.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                player.play { [weak self] snap, fed in
                    print(VideoFixturePlayer.report(snap, fed: fed, units: player.units.count, options: o,
                                                    gpu: self?.video.renderer?.deviceName ?? "none"))
                    let wantHW = !args.contains("--software-decode")
                    let ok = snap.decoded == player.units.count * o.loops && snap.decodeErrors == 0
                        && (!wantHW || snap.hardware == true)
                    self?.video.videoSessionEnded()
                    RtspLog.shared.flush()
                    exit(ok ? 0 : 1)
                }
            }
        } catch {
            print("[fixture] cannot read \(path): \(error)")
            exit(2)
        }
    }

    private func showWindow() {
        if window == nil {
            window = ReceiverWindow(video: video, showHUD: CommandLine.arguments.contains("--hud")
                                    || ProcessInfo.processInfo.environment["AIRTV_HUD"] == "1")
        }
        window?.present()
    }
}
