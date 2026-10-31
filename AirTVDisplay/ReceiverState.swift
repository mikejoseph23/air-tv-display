// SPDX-License-Identifier: MIT
import Foundation

/// What the status item shows. `pairing` covers everything between the first RTSP connection
/// and the first decrypted video frame (GET /info, pair-setup/verify when used, fp-setup,
/// SETUP, RECORD); `streaming` means decrypted H.264 is reaching `video_process`.
enum ReceiverState: String { case stopped, idle, pairing, streaming }

/// Pure transition function from server events to `ReceiverState`, kept separate from
/// `ReceiverController` so the transitions are unit-testable.
enum ReceiverStateMachine {
    static func next(_ s: ReceiverState, _ e: RaopEvent) -> ReceiverState {
        if s == .stopped { return .stopped }   // events after stop() are stale
        switch e {
        case .connectionOpened, .clientRequest:
            return s == .idle ? .pairing : s
        case .mirrorRunning(let on):
            // true = mirror stream set up (SETUP), frames not yet seen.
            if on { return s == .idle ? .pairing : s }
            return s == .streaming ? .pairing : s
        case .videoStarted:
            return .streaming
        case .videoDecryptFailed:
            return s
        case .connectionClosed(let open):
            return open == 0 ? .idle : s
        case .connectionReset:
            return .idle
        }
    }
}
