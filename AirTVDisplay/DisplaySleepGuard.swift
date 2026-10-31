// SPDX-License-Identifier: MIT
import Foundation
import IOKit.pwr_mgt

/// Keeps the iMac's display awake while a sender is streaming, and lets it sleep again after.
///
/// Holds an `IOPMAssertion` of type `PreventUserIdleDisplaySleep` (shows in `pmset -g
/// assertions` under this process with `name`), plus a `ProcessInfo` activity so App Nap does
/// not throttle the receiver. `hold(_:)` is idempotent: call it on every state change.
final class DisplaySleepGuard {
    let name: String
    private var assertion: IOPMAssertionID = IOPMAssertionID(0)
    private var activity: NSObjectProtocol?
    private(set) var isHeld = false

    init(name: String = "Air TV Display: AirPlay stream on screen") { self.name = name }

    deinit { hold(false) }

    /// Whether a receiver state should keep the display awake.
    static func shouldHold(_ state: ReceiverState) -> Bool { state == .streaming }

    @discardableResult
    func hold(_ on: Bool) -> Bool {
        if on == isHeld { return true }
        if on {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
            guard rc == kIOReturnSuccess else {
                RtspLog.shared.log(.err, "[power] IOPMAssertionCreateWithName failed (\(rc))")
                return false
            }
            assertion = id
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical], reason: name)
            isHeld = true
            RtspLog.shared.log(.info, "[power] display sleep blocked while streaming (assertion \(id))")
        } else {
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(0)
            if let a = activity { ProcessInfo.processInfo.endActivity(a) }
            activity = nil
            isHeld = false
            RtspLog.shared.log(.info, "[power] display sleep allowed again")
        }
        return true
    }
}
