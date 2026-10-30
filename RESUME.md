# Air TV Display — Resume Prompt

## Project Overview
A native macOS app that turns a 2017 Intel iMac (`iMac18,3`, macOS 15.7.4, i7-7700K) into an **AirPlay mirroring receiver** that the Mac Studio can mirror or extend to, with nothing installed on the Studio. Approach: wrap **UxPlay**'s C library (`lib/`: RAOP/RTSP, pair-setup/verify, FairPlay, mDNS) in a Swift app, and replace its GStreamer renderer with VideoToolbox + Metal (video) and CoreAudio (audio). UxPlay is GPLv3, so the licensing decision is deferred until shipping. Expect a 1080p stream, latency limited by the sender, and Extend that the sender may or may not offer.

## Current Status
**The repo is moving to the work profile. M0 (the go/no-go gate) is still partial: the Studio sees the receiver over Bonjour, but nobody has tried mirroring to it yet.**
- **Moving.** This personal-profile copy (`/Users/michaeljoseph/git/air-tv-display`) is being retired. The work-profile copy goes to `/Users/michaeljosephwork/git/air-tv-display`, with a private GitHub repo at `git@github.com:mikejoseph23/air-tv-display.git`. The handoff package is in `/Users/Shared/air-tv-display-handoff/` (follow `HANDOFF.md` there).
- **Done in M0.** UxPlay 1.74 (commit 534e2cc) was built from source and advertised correctly. The Studio (**macOS 26.6.2**, not Sequoia) resolved it through `dns-sd -B/-L` at port 49333 with UxPlay's Apple TV-style TXT record.
- **UxPlay is stopped in the personal profile.** Mike will rebuild it in the work profile.
- **Not yet tested (Mike, from the Studio's work profile):** Control Center listing, what happens on select (pairing/PIN/error), whether "Use As Separate Display" is offered, resolution/fps, and latency.
- **The iMac's ethernet (`en0`) was inactive** and the spike ran over Wi-Fi. Plug in ethernet before measuring latency.

## What's Done
- Planning document written and reviewed (UxPlay-based approach, M0 added as the go/no-go gate).
- M0 partial: UxPlay built and running, both TXT records captured verbatim, iMac-side and Studio-side Bonjour verified.
- SSH from the iMac's personal profile to `michaeljosephwork@Mac-Studio.local` works. The host key was verified: ED25519 `SHA256:oK1TQBxEktMrOoeg9cPxdHwBF8yfvAq3NjDhbYw3/yI`.
- Repo prepared for the move: `thirdparty/UxPlay-spike/` is gitignored, the launcher script no longer hard-codes a path, and the bundle and tarballs are in `/Users/Shared`.

## What's Next
1. **In the work profile**, follow `/Users/Shared/air-tv-display-handoff/HANDOFF.md`: clone from the bundle, unpack `orchestrator.tgz`, `gh repo create mikejoseph23/air-tv-display --private --source . --remote origin --push`, then `ssh-copy-id michaeljosephwork@Mac-Studio.local` again.
2. **Rebuild UxPlay** in the work profile: unpack `UxPlay-spike-src.tgz` into `thirdparty/` and follow "How to reproduce" in `docs/discovery-findings.md`. Brew isn't writable and there's no sudo, so the spike used a micromamba env (GStreamer 1.28, OpenSSL) plus a hand-built libplist 2.8.0. Run it with `docs/run-uxplay-spike.sh`. You may need to adjust the env path in the script for the work profile.
3. **Resume the orchestrator**: paste `.orchestrator/airplay-receiver-plan/RESUME-PROMPT.md` into Claude Code. First collect Mike's hands-on M0 results, record them in `docs/discovery-findings.md`, and mark M0 Done or Blocked.
4. **If it streams**, start Group A in parallel, both on Sonnet: **M1** (Bonjour registration in our own process) and **M2** (Xcode app scaffold, with UxPlay vendored as a submodule under `thirdparty/UxPlay` and `lib/` built as a static library). **If it isn't listed or can't pair**, stop for a planning check-in. **If Extend isn't offered**, M7 escalates to Opus.
5. **Clean up** once the work-profile copy is pushed: delete `/Users/Shared/air-tv-display-handoff/` and this personal-profile copy.

## Planning Docs
- `airplay-receiver-plan.md`: milestones M0–M8T with a status tracker and progress log. M0 is 🟡 Partial; everything else is ⬜ Not Started.

## Key File Paths
```
airplay-receiver-plan.md          # Source of truth; only the orchestrator edits it
docs/discovery-findings.md        # M0 findings: TXT records, Bonjour, rebuild recipe, pending hands-on checklist
docs/run-uxplay-spike.sh          # Starts stock UxPlay with -d, logs to docs/m0-uxplay-session.log
docs/m0-uxplay-session.log        # UxPlay log (no connection attempts recorded yet)
thirdparty/UxPlay-spike/          # gitignored spike build (source in the /Users/Shared tarball)
.orchestrator/airplay-receiver-plan/  # gitignored orchestrator state + RESUME-PROMPT.md (in orchestrator.tgz)
```

## Recent Git Log
```
55e43ea Prep move to work profile: ignore UxPlay spike build, portable launcher
fe27263 M0: verify Studio-side Bonjour, note Wi-Fi-only iMac link
867e0ac Orchestrator: record M0 partial result
30662ef M0: UxPlay spike findings, launcher script, session log
93d9cf3 Initial commit: planning document
```

## Any Other Notes
- Both Macs have two profiles: `michaeljoseph` (personal) and `michaeljosephwork` (work). Development happens in the work profile. Screen Mirroring and pairing belong to whichever Studio profile is on screen; Bonjour is system-wide.
- UxPlay advertises as "Air TV Display@Mikes-iMac" (it appends the hostname): `model=AppleTV3,2 features=0x527FFEE6,0x0`. Its feature bits are much narrower than the Studio's own, which is why Extend is uncertain.
- `-fs` does nothing on macOS. The README recommends `-vsync no` for lower latency. Use `-pin`/`-reg` only if pairing requires them.
- Don't build our TXT record from the Studio's own record (`Mac15,14`, AirPlay 2 / HomeKit pairing). UxPlay's record is the template.
