# Air TV Display — Resume Prompt

## Project Overview

Air TV Display is a native macOS AppKit/Swift AirPlay mirroring receiver that turns a spare Mac into a wireless second display. It wraps UxPlay's protocol library (`thirdparty/UxPlay/lib`, a git submodule) and renders with VideoToolbox + Metal for video and CoreAudio for audio. It ships like `~/git/mac-resource-monitor`: a notarized universal DMG, a Sparkle 2 appcast, and a landing page, published through LymeDeploy to `https://iadev.net/air-tv-display/`. The app is GPLv3 because it links UxPlay; our own files carry MIT SPDX headers.

## Current Status

**1.0.0 is released and live (2026-10-31).** Built, signed, notarized and deployed from the Mac Studio; LymeDeploy release 336 on Production. The landing page, appcast and DMG at `https://iadev.net/air-tv-display/` match the staged files.

- M0 through M9 and the landing page are done. 88/88 tests pass.
- The notary profile `mrm-notary` works on the Studio.
- Release scripts were fixed during the release (per-arch `lipo -verify_arch`, `codesign -dvv` captured before grep).

## What's Done

- M0 to M9: receiver, video/audio, Extend mode, hardening, GPLv3 + Sparkle 2 + universal build + LymeDeploy.
- Landing page at `website/index.html`, staged with each release.
- 1.0.0 shipped 2026-10-31.

## What's Next

1. Push `main` once Mike approves (4 commits: 2a715af, 913c3ad and two doc commits).
2. Pick from `BACKLOG.md` or `hands-on-checklist.md`.

## Planning Docs

- `airplay-receiver-plan.md`: milestone tracker and progress log. All milestones are ✅, 1.0.0 logged.
- `hands-on-checklist.md`: still untested: audio/lip sync, 10-cycle reconnect, latency vs stock UxPlay.
- `BACKLOG.md`: Sparkle feed redirect (iadev.net 301s to www), landing page screenshot, Windows sender options A (test AirParrot) and B (own-protocol sender with an IddCx driver).

## Key File Paths

```
CLAUDE.md                     # Build + release runbook, rules
AirTVDisplay/Info.plist       # Version + Sparkle SU* keys (hand-edited, single source of truth)
scripts/setup-deps.sh         # Universal OpenSSL + libplist into ~/.cache/airtv-deps/universal
scripts/make-dmg.sh           # Build, sign, notarize, staple
scripts/stage-release.sh      # EdDSA-sign, rewrite appcast, stage dist/upload/
deploy/pack-for-lymedeploy.sh # Pack + push AirTVDisplay.Downloads <version>
deploy/deploy.yaml            # LymeDeploy project (dry-run first, NEVER --prune)
deploy/updates/appcast.xml    # Sparkle feed (release notes go in <description>)
website/index.html            # Landing page
thirdparty/LICENSES.md        # GPLv3 licensing decision
```

## Recent Git Log

```
d1a12ad Docs: 1.0.0 released; backlog the Sparkle feed redirect
913c3ad Release scripts: check lipo arches one at a time, capture codesign output before grep
2a715af Release 1.0.0
f3735c6 RESUME.md: hand off the 1.0.0 release to the Mac Studio
4dfdcfa Backlog: Windows sender options (AirParrot test, own-protocol sender)
```

## Any Other Notes

- Release on the Studio from a logged-in Terminal, not SSH. `sign_update` raises a keychain prompt; `stage-release.sh` hangs until "Always Allow" is clicked.
- Releases don't use Xcode signing. The scripts sign with the Developer ID directly.
- `stage-release.sh` refuses an ad-hoc DMG unless `ALLOW_UNSIGNED=1`. Don't use that for a real release.
- The production machine mappings are shared with other projects. PMO-PROD-VM is deliberately offline, so a FAIL for it in `lymedeploy doctor` is expected.
- The deployment mode is Promoted with AllowDirectDeploy false. Production is the only rung, so deploying straight to it is fine.
- Keep the repo public and the LICENSE files in the bundle (GPLv3).

## Last Session Summary (2026-10-31)

1. Ran the 1.0.0 release from the Mac Studio: build, Developer ID signing, notarization (9376ce10), stapling, EdDSA appcast, LymeDeploy release 336 to Production. Checked the live landing page, appcast and DMG against the staged files.
2. Fixed two release-script bugs found on the Studio: `lipo -verify_arch` with two arches fails there, and `codesign -dv | grep` missed the Authority lines and could SIGPIPE.
3. Marked the release done in `airplay-receiver-plan.md` and added the feed-redirect item to `BACKLOG.md`.

Decisions: kept the first-release note that was already in the appcast; skipped the LymeDeploy dry run (Mike's call).

Open: push `main` (4 commits ahead, needs Mike's OK); whether to point SUFeedURL at `www.iadev.net`.
