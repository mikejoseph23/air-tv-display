import Foundation

/// Trivial proof that the bridged C library compiles, links and runs.
enum UxPlayBridge {
    static func selfCheck() -> String {
        // dnssd_init allocates and builds TXT records without touching the network.
        var err: Int32 = 0
        let name = "BridgeCheck"
        let hw: [CChar] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
        guard let d = dnssd_init(name, Int32(name.utf8.count), hw, 6, 0, &err) else {
            return "dnssd_init failed err=\(err)"
        }
        var len: Int32 = 0
        let nm = dnssd_get_name(d, &len).map { String(cString: $0) } ?? "?"
        let feat = dnssd_get_airplay_features(d)
        dnssd_destroy(d)

        // raop_init requires audio/video callbacks; supply no-ops.
        var cbs = raop_callbacks_t()
        cbs.audio_process = { _, _, _ in }
        cbs.video_process = { _, _, _ in }
        let r = raop_init(&cbs)
        let ok = r != nil
        // raop_destroy() asserts if the httpd was never started (httpd_stop), so a bare
        // init/destroy is not valid; the one-off allocation is intentionally left alone.
        _ = r
        return "dnssd name=\(nm) features=0x\(String(feat, radix: 16)) raop_init=\(ok ? "ok" : "nil")"
    }
}
