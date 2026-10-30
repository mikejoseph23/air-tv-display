# Air TV Display — Planning Document

Native macOS app that turns an otherwise‑unsupported Intel iMac (this box: `iMac18,3`, 27" 2017, macOS 15.7.4) into an **AirPlay receiver** a Mac Studio can mirror *or extend* to over the network. No helper software on the Studio — it just appears in Control Center → Screen Mirroring like an Apple TV.

Goal: the iMac app runs fullscreen, presents itself as an Apple‑TV‑class AirPlay mirroring receiver, and decodes the sender's H.264 stream (VideoToolbox) with low latency on the iMac's display.

---

## Summary

**Purpose.** The 2017 iMac can't be a native AirPlay‑to‑Mac receiver (Apple's list requires a 2019+ iMac / 2017 iMac **Pro**) and has no Target Display Mode. We build the receiver in software so any Mac can cast to it. Because it speaks the standard AirPlay protocol, it's reusable for anyone with an older Mac they want to turn into a network display — no proprietary client on the sender.

**Strategy.** Do **not** write a protocol stack. **UxPlay** (maintained successor of RPiPlay, GPLv3) is a complete AirPlay mirroring receiver — discovery, pair‑setup/pair‑verify, FairPlay `fp-setup`, RTSP, H.264 and audio demux — and it builds and runs on macOS. The project is therefore:

1. **M0:** run stock UxPlay on the iMac, mirror from the Studio, and learn what macOS actually does (discovery, pairing, Mirror vs Extend, resolution, latency). This answers every protocol unknown before any code is written.
2. **M1–M8:** build a Swift app that wraps UxPlay's C library (`lib/` — raop, pairing, fairplay, mDNS) and replaces its GStreamer renderer with VideoToolbox + Metal and CoreAudio.

**Key objectives.**
- Advertise `_airplay._tcp` and `_raop._tcp` via Bonjour with an **Apple‑TV‑style TXT record** (the one UxPlay uses), so macOS senders list the iMac in Screen Mirroring.
- Complete the handshake an unmodified Sequoia sender requires: `pair-setup` / `pair-verify` (Ed25519 + Curve25519) then FairPlay `fp-setup`, all via UxPlay's library.
- Receive, decrypt and decode the H.264 video stream in realtime via VideoToolbox; draw it fullscreen in a Metal layer.
- Play the session's audio (AAC‑ELD / ALAC, carried inside the mirroring session) via CoreAudio, in sync.
- Support **Extend** (second display) as well as Mirror. Expected to be a sender‑side choice once we look like an Apple TV — M0 confirms.
- Low enough latency over **gigabit ethernet** to be usable as a reference/secondary screen.

**Expectations to set now (not surprises for later).**
- **Resolution is 1080p.** Macs mirror/extend to Apple‑TV‑class receivers at 1920×1080, not the iMac's native 5K. Text on the 27" panel will look soft. Acceptable for a reference display; not a Retina monitor. If M0 shows otherwise, update this.
- **Latency floor is set by the sender.** The Studio's capture, encode and buffering add delay that no receiver work removes. M8 trims our share only. Expect "usable for watching/reference," not "snappy for dragging windows."
- **Extend mode is probably free.** macOS offers "Use As Separate Display" for Apple TV receivers and streams a virtual framebuffer; the receiver doesn't know the difference. M7 is a verification milestone unless M0 proves otherwise.

**Critical success factors.**
1. **M0:** stock UxPlay on the iMac is discovered by, pairs with, and receives video from the Studio (the go/no‑go gate).
2. The Swift wrapper reproduces M0's behaviour with VideoToolbox decode + Metal present, realtime on the i7‑7700K (QuickSync via VideoToolbox).
3. macOS offers Extend, and it behaves as a real second display.

**Known risks.**
- **Sequoia sender compatibility.** Newer macOS/iOS senders have periodically broken UxPlay (TXT `pk`/features changes). Mitigation: M0 tests this first with zero code investment; if stock UxPlay fails, stop and reassess.
- **Wrapping UxPlay's C library** from Swift (callback plumbing, build integration, OpenSSL/libplist deps). Moderate, not boilerplate.
- **Licensing.** UxPlay/RPiPlay are **GPLv3**; its FairPlay code (playfair) is GPL as well. *(Earlier draft had this backwards — shairport‑sync is largely MIT, but it is no longer needed.)* Linking the library into the app makes the app GPLv3 if distributed. Fine for personal use; decide before shipping (keep the receiver core as a separate GPL process over IPC, or accept GPL for the whole app). **Verify LICENSE files when vendoring.**

**Reference implementation (vendored, not authored here):**
- `UxPlay` — https://github.com/FDH2/UxPlay — the protocol backbone. Its `lib/` directory is what we wrap. RPiPlay is its unmaintained ancestor; do not vendor RPiPlay.
- The **Mac Studio's own live TXT record** (captured 2026‑10‑30, `dns-sd -L "Mac Studio" _airplay._tcp local.`: `model=Mac15,14 features=0x4A7FCFD5,0x38174FDE flags=0x204 protovers=1.1 deviceid=… pk=… port 7000`) is kept **for reference only**. It describes an AirPlay‑to‑Mac (AirPlay 2 / HomeKit‑pairing) receiver — exactly the path we avoid. **Do not derive our TXT from it**; start from UxPlay's Apple‑TV‑style record.

---

## Milestone Progress Tracker

| Milestone | Model | Status | Duration (min) | Notes |
|-----------|-------|--------|----------------|-------|
| M0 — Stock UxPlay spike | Sonnet | ✅ Done (latency # pending) | 21 + 6 rebuild | **Gate passed.** Studio streams to stock UxPlay, no PIN; macOS extends by default; 1920×1080 h264 @ ~30 fps over ethernet. |
| M1 — Discovery in our own process | Sonnet | ✅ Done (hands‑on deferred) | 2 | C CLI `tools/discovery-cli/`; Studio `dns-sd` resolves it. Control Center check deferred to end. |
| M2 — App scaffold + vendored lib build | Sonnet | ✅ Done | 7 | Xcode Swift app, window, signing, UxPlay `lib/` compiling as a static lib. |
| M2T — Testing: scaffold | Sonnet | ✅ Done (hands‑on deferred) | 5 | Build/launch/unit. |
| M3 — RTSP + session via library | Opus | ✅ Done (live Studio session deferred) | 22 | Wire `raop_start`/callbacks; sender reaches "connecting". |
| M4 — Pairing / FairPlay via library | Opus | ✅ Done (live Studio session deferred) | 10 | pair‑setup/verify + fp‑setup through UxPlay code; encrypted video bytes arrive. |
| M4T — Testing: session + auth | Opus | ⬜ Not Started | — | Mixed: unit + hands‑on pair. |
| M5 — Video: H.264 decode + present | Opus | ⬜ Not Started | — | VideoToolbox → Metal fullscreen from library NAL callbacks. |
| M5T — Testing: video path | Sonnet | ⬜ Not Started | — | Unit for assembly; hands‑on for realtime/latency. |
| M6 — Audio (AAC‑ELD / ALAC) | Sonnet | ⬜ Not Started | — | Library audio callbacks → CoreAudio, synced. |
| M6T — Testing: audio sync | Sonnet | ⬜ Not Started | — | Hands‑on A/V lip‑sync. |
| M7 — Extend‑mode verification | Sonnet | ⬜ Not Started | — | Confirm Extend offered & works; tune TXT only if M0 showed it isn't. |
| M7T — Testing: mirror vs extend | Sonnet | ⬜ Not Started | — | Hands‑on with Studio picker. |
| M8 — Latency & robustness hardening | Opus | ⬜ Not Started | — | End‑to‑end polish, reconnect, drop handling. |
| M8T — Testing: end‑to‑end | Opus | ⬜ Not Started | — | Full hands‑on workflow over ethernet. |

> **Model Assignment Guidelines** — *Haiku*: mechanical/boilerplate. *Sonnet*: most feature work, standard well‑defined tasks. *Opus*: complex architecture, ambiguous/undocumented protocol work, realtime systems, and any user‑facing interface design. Wrapping C protocol code and realtime decode qualify for Opus even though there's little "UI."

---

## Table of Contents

- [Summary](#summary)
- [Milestone Progress Tracker](#milestone-progress-tracker)
- [Milestone 0 — Stock UxPlay spike](#milestone-0--stock-uxplay-spike)
- [Milestone 1 — Discovery in our own process](#milestone-1--discovery-in-our-own-process)
- [Milestone 2 — App scaffold & vendored library build](#milestone-2--app-scaffold--vendored-library-build)
- [Milestone 2T — Testing: scaffold](#milestone-2t--testing-scaffold)
- [Milestone 3 — RTSP & session via library](#milestone-3--rtsp--session-via-library)
- [Milestone 4 — Pairing & FairPlay via library](#milestone-4--pairing--fairplay-via-library)
- [Milestone 4T — Testing: session & auth](#milestone-4t--testing-session--auth)
- [Milestone 5 — Video decode & present](#milestone-5--video-decode--present)
- [Milestone 5T — Testing: video path](#milestone-5t--testing-video-path)
- [Milestone 6 — Audio (AAC‑ELD / ALAC)](#milestone-6--audio-aac-eld--alac)
- [Milestone 6T — Testing: audio sync](#milestone-6t--testing-audio-sync)
- [Milestone 7 — Extend‑mode verification](#milestone-7--extend-mode-verification)
- [Milestone 7T — Testing: mirror vs extend](#milestone-7t--testing-mirror-vs-extend)
- [Milestone 8 — Latency & robustness hardening](#milestone-8--latency--robustness-hardening)
- [Milestone 8T — Testing: end‑to‑end](#milestone-8t--testing-end-to-end)
- [Parallel Development Recommendations](#parallel-development-recommendations)
- [Gap‑Filling Prompt Requirements](#gap-filling-prompt-requirements)
- [Progress Log / Notes](#progress-log--notes)

---

## Milestone 0 — Stock UxPlay spike

**Model: Sonnet** · **Gate: this is the project's go/no‑go. Zero project code is written here.**

Run an existing, working AirPlay receiver on the iMac and point the Studio at it. Everything downstream depends on what this shows.

**Worker task list:**
- [x] Install UxPlay on the iMac: `brew install uxplay` if the formula is current, otherwise clone https://github.com/FDH2/UxPlay and build per its macOS instructions (`brew install openssl libplist gstreamer` + CMake). Record the version/commit.
- [x] Run `uxplay -n "Air TV Display" -fs` (fullscreen) with verbose logging (`-d`). Capture the TXT record it registers: `dns-sd -L "Air TV Display" _airplay._tcp local.` — **this is our template**, not the Studio's.
- [x] On the **Mac Studio** (SSH `michaeljosephwork@Mac-Studio.local`): `dns-sd -B _airplay._tcp local.` shows the instance. Then (Mike) Control Center → Screen Mirroring: is it listed?
- [x] Select it. Record exactly what happens: pairing prompt? PIN? instant stream? error text? Capture UxPlay's log of the RTSP exchange to `docs/m0-uxplay-session.log`.
- [x] If video flows: in System Settings → Displays, is **"Use As Separate Display"** offered? Select it and confirm the iMac becomes an independent desktop.
- [ ] Record the **stream resolution and frame rate** UxPlay reports (expect 1920×1080) and a rough **latency** estimate (phone video of a cursor move, or clap test) over gigabit ethernet.
- [x] Note any flags UxPlay needed for Sequoia (`-pk`, `-pin`, `-reg`, feature overrides) — these must carry into M1.
- [x] Write `docs/discovery-findings.md`: TXT record, handshake sequence observed, Mirror/Extend availability, resolution, latency, flags. **Update the Summary's expectations if reality differs.**

**Definition of done:** Studio streams video to stock UxPlay on the iMac, and we know whether Extend is offered. **Definition of a finding:** UxPlay is not listed or cannot pair → investigate (Bonjour on the VLAN, firewall, UxPlay version, Sequoia changes) and **stop for a planning check‑in** before M1. If UxPlay itself can't make Sequoia stream, no amount of wrapper code will.

> **Worker Completion Requirement:** complete ALL items. If one is truly blocked, note it in the summary for the orchestrator rather than skipping.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 1 — Discovery in our own process

**Model: Sonnet**

Reproduce M0's discovery from code we control, before the app exists. A partial `dns-sd -R` spike already ran this session.

**Worker task list:**
- [x] Register `_airplay._tcp` and `_raop._tcp` via `DNSServiceRegister` (small C or Swift CLI) with the **TXT record captured from UxPlay in M0**, byte‑for‑byte, substituting our own `deviceid` (derived from en0 MAC, stable across launches) and name. Same port UxPlay used.
- [x] On the Studio: `dns-sd -B _airplay._tcp local.` and `dns-sd -L` show the instance with the intended TXT. Capture output.
- [ ] Control Center → Screen Mirroring lists it (Mike confirms). Selecting it will fail (no RTSP yet) — record how it fails; it's a baseline for M3.
- [x] Append the working registration recipe to `docs/discovery-findings.md`.

**Definition of done:** Studio lists our own process in Screen Mirroring with the M0 TXT.

> **Worker Completion Requirement:** complete ALL items; note deferrals in the summary.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 2 — App scaffold & vendored library build

**Model: Sonnet** (integrating a vendored C/C++ build with OpenSSL + libplist is not boilerplate).

Stand up the Xcode Swift app the rest of the milestones plug into, with UxPlay's `lib/` compiling inside it.

**Worker task list:**
- [x] Create the app target (Swift, macOS, AppKit or SwiftUI for the host window). Working dir: `~/git/air-tv-display`.
- [x] Fullscreen borderless `NSWindow` on the main screen; quits on `Esc`; placeholder "waiting for AirPlay…" view. (UI is trivial by design — the deliverable is the render surface wired in M5.)
- [x] Menu‑bar extra (status item): start/stop receiver, show current state (idle / pairing / streaming), show port + IP.
- [x] Bonjour registration from M1 moved into the app (`DNSServiceRegister`, `_airplay._tcp` + `_raop._tcp`), stable `deviceid` from en0 MAC.
- [x] Entitlements & Info.plist: `NSBonjourServices`, `NSLocalNetworkUsageDescription`, network server entitlement; App Sandbox off for the spike (note the choice).
- [x] Vendor **UxPlay** under `thirdparty/UxPlay` (submodule, pinned to the commit tested in M0). Build only `lib/` (raop, pairing, fairplay/playfair, dnssd shim, llhttp, plist usage) as a static library target; **do not** build the GStreamer renderer. Dependencies: OpenSSL + libplist via Homebrew or vendored.
- [x] Bridging header / module map exposing `raop_init`, `raop_start`, `raop_callbacks_t`, `dnssd_*` to Swift.
- [x] `thirdparty/LICENSES.md`: record UxPlay's GPLv3 and the licensing decision deferred to shipping time (see Summary → Risks).

> **Worker Completion Requirement:** complete ALL items; note deferrals in the summary.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 2T — Testing: scaffold

**Model: Sonnet** · **Mode: unit/integration + hands‑on launch.**

- [x] Unit: `deviceid` derivation is stable across restarts and matches en0's MAC.
- [x] Integration: launch app → `dns-sd -B _airplay._tcp local.` (on iMac *and* on Studio over SSH) shows the registered service with the M0 TXT. Assert TXT round‑trips.
- [ ] Hands‑on (Mike, brief): launch the app, confirm the fullscreen window + menu‑bar item appear, `Esc` quits, and the Studio lists the device.
- [x] Build runs clean on this Intel toolchain (Xcode 26.3 / Swift / clang 17); the vendored `lib/` static library links and a trivial call into it succeeds.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 3 — RTSP & session via library

**Model: Opus** (C callback plumbing into a Swift/AppKit lifecycle; failure modes are protocol‑level).

Bring up UxPlay's RTSP server (`raop_start`) inside the app and connect its callbacks to Swift. UxPlay already implements `OPTIONS`, `GET /info`, `SETUP`, `RECORD`, `SET_PARAMETER`, `TEARDOWN`, `FLUSH`, the event and timing channels, and SDP parsing — **we do not reimplement any of it.**

**Worker task list:**
- [x] Start the raop server on the advertised port when the receiver is enabled; stop on disable. Ensure the port in the TXT and the server agree.
- [x] Implement `raop_callbacks_t` in Swift (via `@convention(c)` thunks): `conn_init`, `conn_destroy`, `audio_init/process/destroy`, `video_process`, `audio_set_volume`, etc. Initially log‑only.
- [x] Route UxPlay's internal logger into `os_log` and `logs/rtsp.log` so M4/M5 debugging is tractable.
- [ ] Confirm the Studio's "connecting" progresses past discovery into an RTSP exchange identical to the M0 log (compare request sequence).

> **Worker Completion Requirement:** complete ALL items; if the exchange diverges from M0's, capture both logs and flag it for M4.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 4 — Pairing & FairPlay via library

**Model: Opus**

Make the Studio complete the session so it actually streams. The handshake modern senders require is **`POST /pair-setup` + `POST /pair-verify` (Ed25519 identity, Curve25519 ECDH, ChaCha20‑Poly1305 verify) followed by `POST /fp-setup` (FairPlay SAP, the m1→m4 exchange)**, then `SETUP` delivers the encrypted AES‑128‑CBC session key (`ekey`/`eiv`) FairPlay unwraps. All of this exists in UxPlay's `lib/` (pairing.c, fairplay_playfair.c, crypto/). This milestone makes sure it runs correctly in our process.

**Worker task list:**
- [x] Generate and **persist** the receiver's Ed25519 keypair (UxPlay derives it from the hardware address; keep that or store in Application Support) so the Studio doesn't see a "new" device every launch.
- [ ] Verify `pair-setup` / `pair-verify` / `fp-setup` complete in our process (log shows the same sequence as M0). If any step fails that succeeded in M0, diff the environment (OpenSSL version, endianness assumptions, missing `pk` in TXT).
- [x] Confirm `video_process` begins receiving **decrypted** H.264 data (UxPlay's raop_rtp_mirror decrypts before the callback). Log the first NAL types and Annex‑B start codes.
- [x] Debug hook: optional dump of the first N seconds of NALs to `logs/stream.h264` for M5 fixtures (and a quick `ffprobe` sanity check).
- [ ] Success condition: the **Mac Studio** goes from "connecting" to streaming decrypted video bytes into our callback.

> **Contingency:** if M3/M4 fail where M0 succeeded, the bug is ours, not the protocol's — bisect against stock UxPlay. If M0 itself failed, this milestone does not start; see M0's finding path.

> **Worker Completion Requirement:** complete ALL items. Do not stop at "partially paired."

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 4T — Testing: session & auth

**Model: Opus** (nuanced assertions over a live protocol). · **Mode: unit for glue + hands‑on for the real pair.**

- [ ] Unit: Swift callback thunks survive out‑of‑order and repeated `conn_init`/`conn_destroy` (sender reconnects) without leaks or crashes.
- [ ] Unit: the NAL dump from M4 parses as valid Annex‑B H.264 (SPS/PPS present, no garbage between start codes).
- [ ] Hands‑on (Mike + Studio): initiate Screen Mirroring from the Studio, watch the app go `idle → pairing → streaming`; confirm decrypted video bytes arrive (log shows H.264 start codes). If it stalls, capture `logs/rtsp.log` tail and report — **do not fabricate success.**

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 5 — Video decode & present

**Model: Opus** (realtime decode + low‑latency present on Intel).

Turn the decrypted H.264 from the `video_process` callback into frames on screen.

**Worker task list:**
- [ ] Convert Annex‑B NALs to AVCC and build `CMFormatDescription` from the SPS/PPS the callback delivers (UxPlay passes parameter sets on stream start and change).
- [ ] `VTDecompressionSession` (VideoToolbox, hardware via QuickSync), async output, `kVTDecodeFrame_EnableAsynchronousDecompression`, frame reordering off where the stream allows.
- [ ] Present decoded `CVPixelBuffer`s in a Metal layer filling the fullscreen window (M2). Keep the queue depth at 1–2 frames; drop late frames rather than queue.
- [ ] Handle resolution/parameter‑set changes mid‑stream and sender disconnect (return to "waiting…" view).
- [ ] Simple perf HUD (toggleable): fps, decode ms/frame, dropped frames, queue depth.

> **Worker Completion Requirement:** complete ALL items. Realtime on the i7‑7700K is the bar — a slide‑show frame rate is a finding, not a pass.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 5T — Testing: video path

**Model: Sonnet** · **Mode: unit for assembly + hands‑on for realtime/latency.**

- [ ] Unit: Annex‑B → AVCC conversion and format‑description builder against the M4 stream fixture (asserts correct NAL lengths and parameter sets).
- [ ] Unit: decoder survives a mid‑stream parameter‑set change without crash (synthetic buffer).
- [ ] Hands‑on (Mike, Studio over **gigabit ethernet**): mirror the Studio to the iMac, move windows; judge motion as smooth‑enough for a reference display. Confirm perf HUD reports reasonable fps/decode‑ms. Compare subjective latency with M0's stock UxPlay — we should be no worse. **Skip‑and‑report beats manufacture** if a state can't be reached.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 6 — Audio (AAC‑ELD / ALAC)

**Model: Sonnet**

Mirroring sessions carry audio inside the same session; UxPlay's `audio_process` callback delivers decrypted frames (AAC‑ELD for mirroring, ALAC for audio‑only RAOP). No shairport‑sync needed.

**Worker task list:**
- [ ] Decode AAC‑ELD / ALAC via `AudioConverter` / AudioToolbox to PCM.
- [ ] Play via CoreAudio (`AudioQueue` or `AVAudioEngine`), time‑aligned to video using the RTP timestamps UxPlay provides.
- [ ] Respect `audio_set_volume` / mute; handle start/stop/flush cleanly.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 6T — Testing: audio sync

**Model: Sonnet** · **Mode: hands‑on (A/V sync can't be asserted by unit tests reliably).**

- [ ] Unit: AAC‑ELD/ALAC decode of a fixture produces expected PCM length/format.
- [ ] Hands‑on (Mike): play a video with speech on the Studio mirrored to the iMac; lips and audio in sync (no drift over 60s); audio stops when the stream stops. State the expected result for each.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 7 — Extend‑mode verification

**Model: Sonnet** (escalate to Opus only if M0 showed Extend is *not* offered and TXT tuning is required).

Make sure macOS offers **Extend**, not just Mirror, against our app — expected to already work because the sender decides this for Apple‑TV‑class receivers.

**Worker task list:**
- [ ] With the app streaming, on the Studio open System Settings → Displays and confirm **"Use As Separate Display"** is offered for the iMac; select it.
- [ ] Confirm the extended display behaves (drag windows onto it, resolution reported by the Studio matches what we receive, nothing squished).
- [ ] If Extend is *not* offered (and was in M0): diff our TXT/`GET /info` plist against stock UxPlay's — it's a divergence we introduced.
- [ ] If Extend was not offered in M0 either: iterate `features`/`flags`/`width`/`height` in the TXT and `/info` against the Studio's picker; record what changed it. This is the only case where this milestone is real work.
- [ ] Record the final recipe in `docs/discovery-findings.md`.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 7T — Testing: mirror vs extend

**Model: Sonnet** · **Mode: hands‑on (behavioral, picker‑driven).**

- [ ] Hands‑on (Mike + Studio): both **Mirror** and **Use As Separate Display** are available; selecting Extend shows the desktop spread across Studio + iMac as an independent display; drag windows between them. Expected result per behavior; capture which modes appear.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 8 — Latency & robustness hardening

**Model: Opus** (system tuning + nuanced failure handling).

**Worker task list:**
- [ ] Measure end‑to‑end latency (phone high‑speed capture of click‑to‑movement) and the receiver's own share (RTP arrival → present, from the HUD). Tune queue depth, decode flags and present path; record baseline vs after. **The sender's share is a fixed floor — don't chase it.**
- [ ] Reconnect handling: sender sleeps/wakes, drops, re‑selects the device without restarting the app.
- [ ] Graceful handling of a second sender, wrong‑size frames, and WiFi fallback (graceful degradation, not crash).
- [ ] Idle/sleep: prevent iMac display sleep while streaming; restore after.
- [ ] Package a first `.app` (bundle, icon, sign — notarize later via the `macos-dmg-notarize` skill if shipping). Revisit the GPL decision here if the app will leave this machine.

[Return to Top](#air-tv-display--planning-document)

---

## Milestone 8T — Testing: end‑to‑end

**Model: Opus** · **Mode: hands‑on full workflow + reconnect soak.**

- [ ] Hands‑on (Mike, **gigabit ethernet**): cold launch app → Studio extends to iMac → work for a few minutes (move/resize windows, open apps) → put Studio to sleep → wake → confirm it re‑connects → stop mirroring → app returns to "waiting…". Walk each step; note latency and any dropouts.
- [ ] Latency measured and recorded in `docs/discovery-findings.md`, alongside the M0 stock‑UxPlay number for comparison.
- [ ] App is stable across ≥10 connect/disconnect cycles.

[Return to Top](#air-tv-display--planning-document)

---

## Parallel Development Recommendations

The backbone is **strictly sequential** — you can't decode what you can't decrypt, or decrypt what you can't pair. Real parallelism is limited but real:

**Sequential blockers (must complete before dependents):**
- **M0 (stock UxPlay)** gates the entire project. If it fails, stop and reassess before anything else.
- **M1 → M2 → M3 → M4 → M5** is a hard chain. Nothing skips ahead.
- **M7 (extend)** depends on M5's working stream.

**Parallel Groups (once their blocker is done):**
- **Group A (after M0):** M1 discovery CLI and the M2 app shell / vendored‑lib build can proceed together (different files).
- **Group B (after M4):** M5 video chain and M6 audio chain are independent once callbacks deliver decrypted data — a second agent can build audio while video lands.
- **Group C (after M5):** M7 verification and M8 packaging/hardening prep can overlap, but fold the final M8 latency pass after M7 so latency is measured on the extended display, not mirror.

**Orchestrator context management:** if dispatching several workers fills the orchestrator context, prompt Mike to run `/compact` while workers run; resume coordination by reading `.orchestrator/state.json`.

---

## Gap‑Filling Prompt Requirements

When a milestone returns incomplete, follow‑up prompts must:
- Mirror the original milestone's prompt structure (header, mission statement, planning‑doc reference to the exact milestone section, task list).
- State what was already completed and list files the prior attempt modified (`git show`/`git diff` of the attempt).
- List other active workers and their working directories to avoid conflicts.
- Label clearly: **"Worker Context: [Milestone Name] — Gap Fill."**
- Close with the standard completion protocol: (1) commit changes, (2) write summary to `.orchestrator/worker-summary-<milestone-slug>-gap.md`, (3) prompt Mike to close/clear the context.

---

## Progress Log / Notes

Reverse‑chronological. Newest first.

**2026-10-30 18:10 — M4 done, live session deferred (Opus, 10 min, commit e249268).** Ed25519 key kept on UxPlay's deterministic scheme (seeded from the en0 deviceid), equal to stock's M0 `pk`, so no key file is needed; tests prove it's stable across start/stop. **Replayed M0's `fp-setup` and FairPlay key decrypt against our process: byte-for-byte match with stock.** `RaopServer.handleVideo` validates Annex-B, flags UxPlay's failed-decrypt marker, logs the first NALs and SPS/PPS/IDR. `AnnexB.swift` parser; `AIRTV_DUMP_SECONDS=N` dumps to `logs/stream.h264` (`scripts/ffprobe-stream.sh`). `ReceiverState.swift` drives idle → pairing → streaming (streaming = first decrypted frame). Synthetic fixtures `Tests/Fixtures/synthetic-1080p.h264` and `synthetic-res-change.h264` for M5. Orchestrator re-ran 14/14 tests. Pair-setup/verify checkbox stays open: fp-setup is verified by replay, but the full live sequence needs the Studio.

**2026-10-30 17:55 — M3 done, live session deferred (Opus, 22 min, merged as 8156ab3 + test fix).** New `RaopServer.swift` mirrors stock `uxplay.cpp` startup: UxPlay's own `dnssd_register_*` (the Swift `BonjourRegistrar` is now superseded), stock features `0x527FFEE6` (bit 27 legacy-pairing cleared; that was the M2 mismatch), Ed25519 `pk` derived from the en0 deviceid, fixed RTSP **port 7100**. All `raop_callbacks_t` slots are log-only thunks; logger goes to `logs/rtsp.log` + os_log. Start/stop/restart safe even with open connections and a busy port. `GET /info` from the iMac and from the Studio matches stock except the name. No way found to make the Studio start mirroring without a person, so the RTSP-sequence comparison is deferred. **The app shares deviceid/pk with stock UxPlay: stop stock UxPlay before any live test of the app.** Orchestrator: merged, re-generated project, added RaopServer/RtspLog to the unhosted test target; build OK, 6/6 unit tests, integration-bonjour 6/6.

**2026-10-30 17:45 — M2T done, hands-on deferred (Sonnet, ~5 min, merged as 8c7c392).** Unhosted XCTest target `AirTVDisplayTests` (6 tests: deviceid = en0 MAC and stable, TXT keys match the M0 capture, call into vendored `lib/`). Run with `xcodebuild test -project AirTVDisplay.xcodeproj -scheme AirTVDisplayTests -derivedDataPath build` (orchestrator re-ran in main: 6/6 pass). `scripts/integration-bonjour.sh` checks TXT round-trip on the iMac and the Studio (6/6). The test target is unhosted because hosting broke the libcrypto embed/codesign step; it compiles `NetworkInfo`/`BonjourRegistrar`/`UxPlayBridge` directly, so update its `sources:` if M3 moves them. Window/menu-bar/Esc check deferred to end.

**2026-10-30 17:30 — M2 done (Sonnet, 7 min, worker commit ea38e58, merged to main).** xcodegen `project.yml` + checked-in project; AppKit shell (borderless fullscreen window, Esc quits, status item with state/IP:port); own `BonjourRegistrar` (en0 deviceid); UxPlay submodule at `thirdparty/UxPlay` pinned to 534e2cc, `lib/` as a static target, libplist static; micromamba has no static libcrypto, so `libcrypto.3.dylib` is embedded in `Contents/Frameworks` and re-signed (fixed a launch crash Mike saw at 17:07). Orchestrator re-built in the main tree: BUILD SUCCEEDED, `--selftest` exit 0. **Flags for M3/M4:** the bridge's `dnssd` reports `features=0x5A7FFEE6` vs stock UxPlay's advertised `0x527FFEE6` (bit 27 differs, so check what uxplay.cpp changes before advertising); `raop_destroy` asserts if httpd was never started; M1's note that `pk` must be the real raop pairing key applies here too.

**2026-10-30 17:20 — M1 done, hands-on deferred (Sonnet, ~2 min, commit 1269ee4).** `tools/discovery-cli/discovery-cli.c` registers `_airplay._tcp` + `_raop._tcp` via `DNSServiceRegister` with UxPlay's TXT, en0-derived deviceid, name/port as args. Studio `dns-sd -B/-L` resolves "Air TV Display M1" (port 7100) alongside stock UxPlay despite the shared deviceid. Generated its own `pk`/`pi` (UxPlay's pk is its Ed25519 public key; **M4 must advertise the real pairing key**). Mike said to skip human gates until the end; the Control Center listing check is on the deferred list. Binary untracked (72edf1d).

**2026-10-30 17:05 — M0 gate PASSED (orchestrator + Mike hands-on).** Rebuilt UxPlay 1.74 in the work profile (Sonnet worker, ~6 min, no commit; recipe needs `zlib` in the micromamba env). iMac now on gigabit ethernet (`en0` 192.168.50.250), Wi-Fi off. From the Studio's work profile: listed in Screen Mirroring, selecting it **streamed instantly with no PIN**, and macOS **extended the desktop by default** (no Displays toggle needed). Log: `GET /info` → `fp-setup` ×2 → `SETUP` → `RECORD` → `/feedback`; no pair-setup/verify for this `pw=false` receiver; stream 1920×1080 h264, maxFPS 30. **M7 stays Sonnet, verification only.** Latency estimate still to come from Mike; the latency checkbox stays open. Next: Group A (M1 + M2 in parallel, Sonnet).

**2026-10-30 16:20 — Repo moving to the work profile.** Mike does development in the `michaeljosephwork` profile; this repo moves from `/Users/michaeljoseph/git/air-tv-display` to `/Users/michaeljosephwork/git/air-tv-display` and gets a GitHub remote (`git@github.com:mikejoseph23/air-tv-display.git`, private). Handoff via `/Users/Shared/air-tv-display-handoff/` (git bundle + `.orchestrator/` + spike source tarball). `thirdparty/UxPlay-spike/` is now gitignored (M2 vendors UxPlay properly under `thirdparty/UxPlay`); `docs/run-uxplay-spike.sh` resolves the repo from its own path. The spike's micromamba toolchain lives in the personal home, so the work profile must rebuild UxPlay before running it there. The M0 hands-on test will run from the Studio's **work** profile.

**2026-10-30 16:05 — M0: Studio-side Bonjour verified (orchestrator).** SSH to the Studio fixed (host key fingerprint verified by Mike on the Studio, iMac key installed via `ssh-copy-id`); workers can now SSH non-interactively. Studio (**macOS 26.6.2**, not Sequoia) `dns-sd -B`/`-L` sees "Air TV Display@Mikes-iMac" at `:49333` with UxPlay's TXT unchanged. **Finding:** the iMac's ethernet (`en0`) is inactive; the spike is running over **Wi-Fi** (`en1`, 192.168.50.249). Pairing/Extend can be judged on Wi-Fi; the latency number must be taken on ethernet. Still pending (Mike, at the Studio GUI): Control Center listing, select/pair result, Use As Separate Display, res/fps, latency.

**2026-10-30 15:55 — M0 partial (worker, Sonnet, 21 min, commit 30662ef).** No Homebrew `uxplay` formula and brew is not writable by this user (no sudo), so **UxPlay 1.74 (commit 534e2cc) was built from source** under `thirdparty/UxPlay-spike/` (uncommitted) using a micromamba toolchain (GStreamer 1.28, OpenSSL) and a hand‑built libplist 2.8.0. It is **running in the background** (`docs/run-uxplay-spike.sh`, log `docs/m0-uxplay-session.log`), advertised as **"Air TV Display@Mikes‑iMac"** (UxPlay appends the hostname) on random port 49333, `model=AppleTV3,2 features=0x527FFEE6,0x0`. Both `_airplay._tcp` and `_raop._tcp` TXT records captured verbatim in `docs/discovery-findings.md`. iMac‑side Bonjour works; firewall off. **Blocked:** SSH to the Studio failed on an unknown host key (worker correctly did not auto‑accept), so Studio‑side `dns-sd` is unchecked. **Pending hands‑on (Mike):** Control Center listing, pairing behaviour, "Use As Separate Display", resolution/fps, latency. Flags: `-fs` is ineffective on macOS; README recommends `-vsync no`; `-pin`/`-reg` only if pairing demands. No Sequoia‑specific caveats found. **Open question for M7:** UxPlay's feature bits are far narrower than the Studio's own, so Extend is not assured. Gate not yet passed. Session paused by request; resuming in an Opus orchestrator.

**2026-10-30 (plan review)** — Plan revised after review. **Added M0: run stock UxPlay first** as the go/no‑go gate so every protocol unknown is answered before code exists. Switched the backbone from RPiPlay (unmaintained) to **UxPlay** and reframed M3–M6 as *wrapping its `lib/`* rather than porting protocol code; dropped shairport‑sync (audio rides inside the mirroring session). Corrected the auth description: modern senders need `pair-setup`/`pair-verify` (Ed25519/Curve25519) then FairPlay `fp-setup`; the earlier "avoid Ed25519" framing was wrong, as was "AES‑127" (it's AES‑128‑CBC). Corrected licensing: UxPlay/RPiPlay are GPLv3, shairport‑sync is largely MIT — verify on vendoring. Demoted the Studio's TXT record to reference‑only (it describes an AirPlay‑2/HomeKit receiver, the path we avoid); our template is UxPlay's Apple‑TV‑style record. Added **expectations** to the Summary: 1080p stream, sender‑bound latency floor, Extend likely a sender‑side choice (M7 demoted to verification). M2 moved Haiku → Sonnet (C/C++ build integration isn't boilerplate). Noted alternative: if the goal is only a second monitor for the Studio, Luna Display / Duet give higher resolution and lower latency off the shelf.

**2026-10-30 15:08** — Planning document created via `/make-planning-document`. Captured the **Mac Studio's live `_airplay._tcp` TXT record** (port 7000, `model=Mac15,14 features=0x4A7FCFD5,0x38174FDE flags=0x204 protovers=1.1`) as the receiver template. Decided **Track A** (real AirPlay receiver, reusing RPiPlay + shairport‑sync) over a custom peer app, for sender‑side reuse. Confirmed iMac toolchain: Xcode 26.3, Swift, clang 17, Intel i7‑7700K (QuickSync/VideoToolbox available). Flagged two risks up front: **AirPlay 1 vs AirPlay 2 auth** (M4) and **Extend‑mode feature bits** (M7). Default test modes applied: unit/integration + hands‑on; **no Playwright** (no web UI), **no screenshots** (look isn't the deliverable), **no Schema Review** (no database). Next action: **M1 discovery spike** — the go/no‑go gate.

[Return to Top](#air-tv-display--planning-document)
