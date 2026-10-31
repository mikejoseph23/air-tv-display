# Air TV Display — Resume Prompt

## Project Overview

Air TV Display is a native macOS AppKit/Swift AirPlay mirroring receiver that turns a spare Mac into a wireless second display. It wraps UxPlay's protocol library (`thirdparty/UxPlay/lib`, a git submodule) and renders with VideoToolbox + Metal for video and CoreAudio for audio. It ships like `~/git/mac-resource-monitor`: a notarized universal DMG, a Sparkle 2 appcast, and a landing page, published through LymeDeploy to `https://iadev.net/air-tv-display/`. The app is GPLv3 because it links UxPlay; our own files carry MIT SPDX headers.

## Current Status

**Everything is built, tested and pushed. Only the signed 1.0.0 release is left, and it has to run on the Mac Studio.**

- M0 through M9 and the landing page are done. 88/88 tests pass, and an ad-hoc universal DMG ran on both Macs.
- The LymeDeploy project `air-tv-display-downloads` (id 27) exists, the IIS folder `/air-tv-display` exists on iadev-2025, and the CloudflareToken variable is set.
- Unverified: the notary keychain profile name `mrm-notary` (borrowed from mac-resource-monitor).

## What's Next

Run these in a **logged-in Terminal on the Studio, not over SSH**. The login keychain is locked in SSH sessions. Click "Always Allow" on keychain prompts.

1. `cd ~/git/air-tv-display && git pull && git submodule update --init && scripts/setup-deps.sh && xcodegen`
2. Put the release notes (e.g. "First release.") in the `<description>` in `deploy/updates/appcast.xml`. The version is already 1.0.0, build 1, in `AirTVDisplay/Info.plist`.
3. `SIGN_ID="Developer ID Application: INTERAPP DEVELOPMENT, INC. (UU626VCLYW)" NOTARIZE_PROFILE="mrm-notary" scripts/make-dmg.sh`. If the profile name is wrong, create one with `xcrun notarytool store-credentials`.
4. Run `scripts/stage-release.sh` to stage `dist/upload/`.
5. Check `which lymedeploy` on the Studio, then run `deploy/pack-for-lymedeploy.sh`.
6. Create and deploy a release of `air-tv-display-downloads` to Production (`lymedeploy create-release --help`, `lymedeploy deploy --help`). Check that `https://iadev.net/air-tv-display/` and `/appcast.xml` load.
7. Commit the rewritten appcast as "Release 1.0.0". Push once Mike approves.
8. Then mark the release done in `airplay-receiver-plan.md` (M9 notes and the progress log).

## Planning Docs

- `airplay-receiver-plan.md`: milestone tracker and progress log. All milestones through M9 are ✅; M9 notes "first release pending".
- `hands-on-checklist.md`: still untested: audio/lip sync, 10-cycle reconnect, latency vs stock UxPlay.
- `BACKLOG.md`: landing page screenshot; Windows sender option A (test AirParrot) and option B (own-protocol sender with an IddCx driver, signed with the Azure Trusted Signing cert).

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
4dfdcfa Backlog: Windows sender options (AirParrot test, own-protocol sender)
7c19491 deploy.yaml: record where the Cloudflare token lives
c0124ae deploy.yaml: explain the shared Production machine mappings
3b8e104 Backlog: landing page screenshot
6f7f980 Landing page: drop the screenshot slot
8711979 Add the iadev.net download landing page and stage it with each release
64123fe Plan: M9 done, release steps pending
```

## Any Other Notes

- Releases don't use Xcode. The scripts sign with the Developer ID directly, so ignore Xcode signing errors.
- `stage-release.sh` refuses an ad-hoc DMG unless `ALLOW_UNSIGNED=1`. Don't use that for a real release.
- The production machine mappings are shared with other projects. PMO-PROD-VM is deliberately offline, so a FAIL for it in `lymedeploy doctor` is expected.
- The deployment mode is Promoted with AllowDirectDeploy false. Production is the only rung, so deploying straight to it is fine.
- Keep the repo public and the LICENSE files in the bundle (GPLv3).
