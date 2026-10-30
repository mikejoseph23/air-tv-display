import Foundation

/// Debug hook: writes the first N seconds of each mirror session's decrypted Annex-B video
/// to `stream.h264` in the log directory, for M5 fixtures and ffprobe checks. Off by default.
/// Enable with `AIRTV_DUMP_SECONDS=<n>` or `defaults write net.iadev.AirTVDisplay
/// DumpStreamSeconds -int <n>` (the env var wins; 0 disables). Each new session overwrites
/// the file. Called from UxPlay's mirror thread only.
final class StreamDump {
    static let defaultsKey = "DumpStreamSeconds"

    let seconds: Double
    let fileURL: URL
    private var handle: FileHandle?
    private var startedAt: Date?
    private(set) var bytesWritten = 0
    private(set) var finished = false

    init?(seconds: Double, fileURL: URL) {
        guard seconds > 0 else { return nil }
        self.seconds = seconds
        self.fileURL = fileURL
    }

    /// The configured dump, or nil when disabled.
    static func fromEnvironment(directory: URL = RtspLog.logDirectory()) -> StreamDump? {
        let env = ProcessInfo.processInfo.environment["AIRTV_DUMP_SECONDS"].flatMap(Double.init)
        let secs = env ?? UserDefaults.standard.double(forKey: defaultsKey)
        return StreamDump(seconds: secs, fileURL: directory.appendingPathComponent("stream.h264"))
    }

    /// Starts a fresh dump (truncates the file).
    func beginSession() {
        close()
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        startedAt = nil
        bytesWritten = 0
        finished = handle == nil
    }

    /// Appends one decrypted access unit. Returns true when this call ended the dump.
    @discardableResult
    func append(_ p: UnsafePointer<UInt8>, _ len: Int, now: Date = Date()) -> Bool {
        guard let h = handle, !finished, len > 0 else { return false }
        if startedAt == nil { startedAt = now }
        if let s = startedAt, now.timeIntervalSince(s) >= seconds {
            close()
            finished = true
            return true
        }
        h.write(Data(bytes: p, count: len))
        bytesWritten += len
        return false
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}
