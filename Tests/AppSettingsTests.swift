// SPDX-License-Identifier: MIT
import XCTest

final class AppSettingsTests: XCTestCase {
    private func make(env: [String: String] = [:], args: [String] = []) -> AppSettings {
        let suite = "net.iadev.airtv.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: d, environment: env, arguments: args)
    }

    func testDefaults() {
        let s = make()
        XCTAssertEqual(s.deviceName, "Air TV Display")
        XCTAssertTrue(s.playAudio)
        XCTAssertFalse(s.showHUDAtLaunch)
        XCTAssertFalse(s.escQuits)
        XCTAssertFalse(s.launchAtLogin)
    }

    func testStoredValuesRoundTrip() {
        let s = make()
        s.storedName = "Living Room"
        s.storedPlayAudio = false
        s.showHUDAtLaunchStored = true
        s.escQuits = true
        XCTAssertEqual(s.deviceName, "Living Room")
        XCTAssertFalse(s.playAudio)
        XCTAssertTrue(s.showHUDAtLaunch)
        XCTAssertTrue(s.escQuits)
    }

    func testEnvNameOverridesStored() {
        let s = make(env: ["AIRTV_NAME": "Bedroom"])
        s.storedName = "Living Room"
        XCTAssertEqual(s.deviceName, "Bedroom")
    }

    func testEmptyOrWhitespaceNameFallsBack() {
        let s = make()
        s.storedName = "   "
        XCTAssertEqual(s.deviceName, "Air TV Display")
        XCTAssertEqual(AppSettings.resolveName(stored: "Den", env: ["AIRTV_NAME": "  "]), "Den")
        XCTAssertEqual(AppSettings.resolveName(stored: "", env: ["AIRTV_NAME": ""]), "Air TV Display")
    }

    func testMuteEnvForcesAudioOff() {
        let s = make(env: ["AIRTV_MUTE": "1"])
        s.storedPlayAudio = true
        XCTAssertFalse(s.playAudio)
        XCTAssertTrue(make(env: ["AIRTV_MUTE": "0"]).playAudio)
    }

    func testHUDFlagAndEnvForceOn() {
        XCTAssertTrue(make(args: ["--hud"]).showHUDAtLaunch)
        XCTAssertTrue(make(env: ["AIRTV_HUD": "1"]).showHUDAtLaunch)
        let s = make(env: ["AIRTV_HUD": "0"])
        s.showHUDAtLaunchStored = true
        XCTAssertTrue(s.showHUDAtLaunch)
        XCTAssertFalse(make(env: ["AIRTV_HUD": "0"]).showHUDAtLaunch)
    }
}
