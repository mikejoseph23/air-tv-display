# Air TV Display

Turns a Mac into an AirPlay screen-mirroring receiver. Pick it in Control Center → Screen Mirroring on another Mac or an iPhone, and that device mirrors (or extends) onto this Mac's screen, with audio.

It's built on the protocol library from [UxPlay](https://github.com/FDH2/UxPlay), with native VideoToolbox decoding and Metal rendering.

## Install

1. Download the latest `AirTVDisplay-v<version>.dmg` from https://iadev.net/air-tv-display/.
2. Open it and drag **Air TV Display** to Applications.
3. Launch it. Allow local network access when macOS asks.

It runs fullscreen, waiting for a sender, with a menu-bar item for settings. Updates arrive through Sparkle ("Check for Updates…" in the menu-bar or right-click menu). Requires macOS 13 or later, Apple silicon or Intel.

## Build from source

Needs Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone --recurse-submodules https://github.com/mikejoseph23/air-tv-display.git
cd air-tv-display
scripts/setup-deps.sh     # OpenSSL + libplist, universal, under ~/.cache/airtv-deps (no sudo)
xcodegen
xcodebuild -project AirTVDisplay.xcodeproj -scheme AirTVDisplay -derivedDataPath build build
open build/Build/Products/Debug/AirTVDisplay.app
```

`scripts/make-dmg.sh` builds a universal Release DMG (ad-hoc signed unless `SIGN_ID` is set). Release steps are in `CLAUDE.md`. The download page at https://iadev.net/air-tv-display/ lives in `website/` (`index.html`, `screenshot.png`); `scripts/stage-release.sh` stages it with the DMG and appcast.

## License

GNU General Public License v3 (`LICENSE`), because the app includes GPLv3 UxPlay code. Our own source files are also available under MIT (see their SPDX headers). Third-party components and their licenses: `thirdparty/LICENSES.md`.
