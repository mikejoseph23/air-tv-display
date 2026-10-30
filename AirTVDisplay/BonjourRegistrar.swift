import Foundation
import dnssd

enum BonjourError: Error { case register(service: String, code: Int32) }

/// SUPERSEDED in M3: the app now advertises through UxPlay's own dnssd_register_* (RaopServer),
/// so the TXT and pk come from the live raop instance. Kept only for reference/tests.
///
/// Registers `_airplay._tcp` and `_raop._tcp` with the TXT records captured from stock
/// UxPlay in M0 (docs/discovery-findings.md), via the system mDNSResponder (DNSServiceRegister).
final class BonjourRegistrar {
    let name: String
    let port: UInt16
    let deviceID: String        // "aa:bb:cc:dd:ee:ff"
    let publicKeyHex: String

    private var airplayRef: DNSServiceRef?
    private var raopRef: DNSServiceRef?

    /// pk is the receiver's Ed25519 public key. Until the real RAOP pairing key is wired
    /// (dnssd_set_pk), use a stable random 32-byte value persisted in UserDefaults.
    init(name: String, port: UInt16, deviceID: String) {
        self.name = name
        self.port = port
        self.deviceID = deviceID
        let key = "BonjourPlaceholderPK"
        if let s = UserDefaults.standard.string(forKey: key) {
            publicKeyHex = s
        } else {
            let s = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            UserDefaults.standard.set(s, forKey: key)
            publicKeyHex = s
        }
    }

    var airplayTXT: [String: String] {
        ["deviceid": deviceID, "features": "0x527FFEE6,0x0", "pw": "false", "flags": "0x4",
         "model": "AppleTV3,2", "pk": publicKeyHex, "pi": Self.persistentUUID(),
         "srcvers": "220.68", "vv": "2"]
    }

    var raopTXT: [String: String] {
        ["ch": "2", "cn": "0,1,2,3", "da": "true", "et": "0,3,5", "vv": "2", "ft": "0x527FFEE6,0x0",
         "am": "AppleTV3,2", "md": "0,1,2", "rhd": "5.6.0.0", "pw": "false", "sf": "0x4",
         "sr": "44100", "ss": "16", "sv": "false", "tp": "UDP", "txtvers": "1", "vs": "220.68",
         "vn": "65537", "pk": publicKeyHex]
    }

    func register() throws {
        let macNoColons = deviceID.replacingOccurrences(of: ":", with: "").uppercased()
        try registerOne(&airplayRef, type: "_airplay._tcp", instance: name, txt: airplayTXT)
        try registerOne(&raopRef, type: "_raop._tcp", instance: "\(macNoColons)@\(name)", txt: raopTXT)
    }

    func unregister() {
        if let r = airplayRef { DNSServiceRefDeallocate(r); airplayRef = nil }
        if let r = raopRef { DNSServiceRefDeallocate(r); raopRef = nil }
    }

    private func registerOne(_ ref: inout DNSServiceRef?, type: String, instance: String, txt: [String: String]) throws {
        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        defer { TXTRecordDeallocate(&record) }
        for (k, v) in txt {
            let bytes = Array(v.utf8)
            TXTRecordSetValue(&record, k, UInt8(bytes.count), bytes)
        }
        let err = DNSServiceRegister(&ref, 0, 0, instance, type, nil, nil, port.bigEndian,
                                     TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record), nil, nil)
        if err != kDNSServiceErr_NoError { throw BonjourError.register(service: type, code: err) }
    }

    private static func persistentUUID() -> String {
        let key = "BonjourPlaceholderPI"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let s = UUID().uuidString.lowercased()
        UserDefaults.standard.set(s, forKey: key)
        return s
    }
}
