import Foundation
import ServiceManagement

/// User settings, UserDefaults-backed. Launch flags / environment variables win over the stored
/// value (resolved by the pure `resolve*` functions, which the tests cover).
final class AppSettings {
    static let defaultName = "Air TV Display"
    static let shared = AppSettings()

    enum Key {
        static let deviceName = "deviceName"
        static let playAudio = "playAudio"
        static let showHUDAtLaunch = "showHUDAtLaunch"
        static let escQuits = "escQuits"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults
    private let environment: [String: String]
    private let arguments: [String]

    init(defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         arguments: [String] = CommandLine.arguments) {
        self.defaults = defaults
        self.environment = environment
        self.arguments = arguments
    }

    // MARK: stored values

    /// The name as typed (empty allowed); `deviceName` is what gets advertised.
    var storedName: String {
        get { defaults.string(forKey: Key.deviceName) ?? "" }
        set { defaults.set(newValue, forKey: Key.deviceName) }
    }
    var storedPlayAudio: Bool {
        get { defaults.object(forKey: Key.playAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playAudio) }
    }
    var showHUDAtLaunchStored: Bool {
        get { defaults.bool(forKey: Key.showHUDAtLaunch) }
        set { defaults.set(newValue, forKey: Key.showHUDAtLaunch) }
    }
    var escQuits: Bool {
        get { defaults.bool(forKey: Key.escQuits) }
        set { defaults.set(newValue, forKey: Key.escQuits) }
    }
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    // MARK: effective values (environment / flags applied)

    var deviceName: String { Self.resolveName(stored: storedName, env: environment) }
    var playAudio: Bool { Self.resolvePlayAudio(stored: storedPlayAudio, env: environment) }
    var showHUDAtLaunch: Bool {
        Self.resolveShowHUD(stored: showHUDAtLaunchStored, env: environment, args: arguments)
    }

    static func resolveName(stored: String, env: [String: String]) -> String {
        for candidate in [env["AIRTV_NAME"], stored] {
            let t = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { return t }
        }
        return defaultName
    }

    /// `AIRTV_MUTE=1` forces audio off.
    static func resolvePlayAudio(stored: Bool, env: [String: String]) -> Bool {
        env["AIRTV_MUTE"] == "1" ? false : stored
    }

    /// `--hud` / `AIRTV_HUD=1` force the HUD on.
    static func resolveShowHUD(stored: Bool, env: [String: String], args: [String]) -> Bool {
        args.contains("--hud") || env["AIRTV_HUD"] == "1" ? true : stored
    }
}

/// Launch at login via `SMAppService.mainApp`.
enum LoginItem {
    /// Registers or unregisters; returns a message for the window when it fails or needs approval.
    static func apply(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            return "Launch at login: \(error.localizedDescription)"
        }
        return statusMessage()
    }

    static func statusMessage() -> String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval: return "Launch at login needs approval in System Settings → General → Login Items."
        case .notFound: return "Launch at login is unavailable (app not found by the system)."
        default: return nil
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
}
