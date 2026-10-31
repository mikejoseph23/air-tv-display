# Licenses

**Air TV Display as distributed is licensed under the GNU General Public License v3** (`LICENSE` at the repo root, also shipped in the app's `Contents/Resources`). It has to be: the app statically links GPLv3 code (UxPlay and its playfair FairPlay module). Corresponding source: https://github.com/mikejoseph23/air-tv-display.

Our own source files (`AirTVDisplay/`, `Tests/`, `scripts/`, `tools/`, `deploy/`) carry `SPDX-License-Identifier: MIT` headers so they can be reused on their own under MIT. That does not change the license of the combined app, which is GPLv3. Nothing under `thirdparty/` carries our header; each component keeps its own license, listed below.

Decision recorded 2026-10-30 (M9): ship under GPLv3 with source on GitHub, rather than replacing the GPL components.

## Components in the shipped app

| Component | License | How it's used |
|---|---|---|
| UxPlay 1.74 (`thirdparty/UxPlay`, submodule) | GPL-3.0 | `lib/` built as the static library `uxplaylib` |
| playfair (`UxPlay/lib/playfair`) | GPL-3.0 | inside `uxplaylib` |
| RPiPlay / shairplay-derived files in `UxPlay/lib` (raop, dnssd, ...) | LGPL-2.1-or-later (per-file headers) | inside `uxplaylib` |
| llhttp (`UxPlay/lib/llhttp`) | MIT (Fedor Indutny, 2018) | inside `uxplaylib` |
| Sparkle 2 | MIT | `Contents/Frameworks/Sparkle.framework` (auto-update) |
| OpenSSL 3 (conda-forge build) | Apache-2.0 | `Contents/Frameworks/libcrypto.3.dylib` |
| libplist 2.8.0 | LGPL-2.1-or-later | linked statically |

## Details

- **UxPlay:** https://github.com/FDH2/UxPlay, pinned to `534e2cc0e558d6c94bcc66964f8fc13ad73a6cdc` (the M0-tested commit). Top-level `LICENSE` is GPLv3, `lib/playfair/LICENSE.md` is GPLv3, `lib/llhttp/LICENSE-MIT` is MIT (all verified in the submodule). Only `lib/` is built; the GStreamer renderers are not.
- **Sparkle:** https://github.com/sparkle-project/Sparkle, via Swift Package Manager (`project.yml` `packages:`).
- **OpenSSL and libplist** come from `AIRTV_DEPS_PREFIX`, built by `scripts/setup-deps.sh` (OpenSSL from conda-forge, libplist 2.8.0 from the libimobiledevice release tarball, both lipo'd universal). libcrypto is a separate dylib in the bundle and can be replaced; libplist is LGPL and linked statically, which is fine under the GPLv3 terms of the whole app because the complete source and build scripts are published.
