import XCTest


final class BonjourTXTTests: XCTestCase {
    // Key sets from the M0 stock UxPlay capture (docs/discovery-findings.md).
    static let airplayKeys: Set<String> = ["deviceid", "features", "pw", "flags", "model", "pk", "pi", "srcvers", "vv"]
    static let raopKeys: Set<String> = ["ch", "cn", "da", "et", "vv", "ft", "am", "md", "rhd", "pw", "sf",
                                        "sr", "ss", "sv", "tp", "txtvers", "vs", "vn", "pk"]
    let mac = "68:fe:f7:12:96:16"

    func testAirplayTXTMatchesM0() {
        let r = BonjourRegistrar(name: "T", port: 1234, deviceID: mac)
        XCTAssertEqual(Set(r.airplayTXT.keys), Self.airplayKeys)
        XCTAssertEqual(r.airplayTXT["deviceid"], mac)
        XCTAssertEqual(r.airplayTXT["features"], "0x527FFEE6,0x0")
        XCTAssertEqual(r.airplayTXT["model"], "AppleTV3,2")
        XCTAssertEqual(r.airplayTXT["pw"], "false")
        XCTAssertEqual(r.airplayTXT["flags"], "0x4")
    }

    func testRaopTXTMatchesM0() {
        let r = BonjourRegistrar(name: "T", port: 1234, deviceID: mac)
        XCTAssertEqual(Set(r.raopTXT.keys), Self.raopKeys)
        XCTAssertEqual(r.raopTXT["ft"], r.airplayTXT["features"])
        XCTAssertEqual(r.raopTXT["am"], r.airplayTXT["model"])
        XCTAssertEqual(r.raopTXT["pk"], r.airplayTXT["pk"])
    }

    func testPublicKeyIsHex32BytesAndStable() {
        let a = BonjourRegistrar(name: "T", port: 1, deviceID: mac)
        let b = BonjourRegistrar(name: "T", port: 2, deviceID: mac)
        XCTAssertNotNil(a.publicKeyHex.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertEqual(a.publicKeyHex, b.publicKeyHex)
        XCTAssertEqual(a.airplayTXT["pi"], b.airplayTXT["pi"])
    }
}

final class UxPlayBridgeTests: XCTestCase {
    /// Calls into the vendored C static library (dnssd_init / raop_init).
    func testBridgeCallsIntoVendoredLib() {
        let s = UxPlayBridge.selfCheck()
        XCTAssertTrue(s.contains("dnssd name=BridgeCheck"), s)
        XCTAssertTrue(s.contains("raop_init=ok"), s)
    }
}
