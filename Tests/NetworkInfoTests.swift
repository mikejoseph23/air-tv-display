import XCTest


final class NetworkInfoTests: XCTestCase {
    private func ifconfigEn0MAC() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        p.arguments = ["en0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let line = out.split(separator: "\n").first { $0.contains("ether ") }
        return try XCTUnwrap(line?.split(separator: " ").last.map(String.init), "en0 has no ether line")
    }

    func testDeviceIDMatchesEn0MAC() throws {
        let mac = try XCTUnwrap(NetworkInfo.en0MAC())
        XCTAssertEqual(mac, try ifconfigEn0MAC().lowercased())
        XCTAssertNotNil(mac.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression))
    }

    func testDeviceIDStableAcrossCalls() throws {
        let first = try XCTUnwrap(NetworkInfo.en0MAC())
        for _ in 0..<20 { XCTAssertEqual(NetworkInfo.en0MAC(), first) }
    }
}
