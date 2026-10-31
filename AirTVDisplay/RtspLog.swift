// SPDX-License-Identifier: MIT
import Foundation
import os

/// Sink for UxPlay's internal logger (raop/httpd/rtp/pairing) and our callback traces.
/// Every line goes to os_log (subsystem net.iadev.AirTVDisplay, category "rtsp") and is
/// appended to `rtsp.log` in `logDirectory`. Thread-safe: UxPlay logs from its httpd and
/// RTP threads.
final class RtspLog {
    static let shared = RtspLog()

    /// UxPlay logger levels (lib/logger.h).
    enum Level: Int32 { case err = 3, warning = 4, notice = 5, info = 6, debug = 7, debugData = 8 }

    let fileURL: URL
    private let osLog = Logger(subsystem: "net.iadev.AirTVDisplay", category: "rtsp")
    private let queue = DispatchQueue(label: "net.iadev.AirTVDisplay.rtsplog")
    private var handle: FileHandle?
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = Self.logDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("rtsp.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    /// `$AIRTV_LOG_DIR`, else `<repo>/logs` when running from a build inside the repo
    /// (found by walking up from the bundle to the directory holding project.yml),
    /// else `~/Library/Logs/AirTVDisplay`.
    static func logDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["AIRTV_LOG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.yml").path) {
                return dir.appendingPathComponent("logs", isDirectory: true)
            }
            dir = dir.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AirTVDisplay", isDirectory: true)
    }

    func log(_ level: Level, _ msg: String) {
        switch level {
        case .err: osLog.error("\(msg, privacy: .public)")
        case .warning: osLog.warning("\(msg, privacy: .public)")
        case .notice, .info: osLog.info("\(msg, privacy: .public)")
        case .debug, .debugData: osLog.debug("\(msg, privacy: .public)")
        }
        let tag: String
        switch level {
        case .err: tag = "E"
        case .warning: tag = "W"
        case .notice, .info: tag = "I"
        case .debug, .debugData: tag = "D"
        }
        let now = Date()
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            let line = "\(self.stamp.string(from: now)) \(tag) \(msg)\n"
            h.write(Data(line.utf8))
        }
    }

    func log(rawLevel: Int32, _ msg: String) {
        log(Level(rawValue: rawLevel) ?? (rawLevel < 3 ? .err : .debug), msg)
    }

    /// Blocks until queued lines are written (call before exit).
    func flush() { queue.sync { try? handle?.synchronize() } }
}
