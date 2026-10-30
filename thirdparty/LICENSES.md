# Third-party licenses

## UxPlay (`thirdparty/UxPlay`, git submodule)

- Source: https://github.com/FDH2/UxPlay, pinned to `534e2cc0e558d6c94bcc66964f8fc13ad73a6cdc` (the M0-tested commit).
- Top-level `LICENSE`: **GNU GPL v3** (verified in the submodule).
- `lib/playfair/LICENSE.md`: **GNU GPL v3** (verified). The playfair FairPlay code is GPLv3.
- `lib/llhttp/LICENSE-MIT`: **MIT**, Fedor Indutny 2018 (verified).
- Much of `lib/` (raop, dnssd, etc., derived from RPiPlay/shairplay) carries per-file **LGPL v2.1+** headers (e.g. `lib/raop.c`, `lib/dnssd.h`); the combined work as built here is governed by GPLv3 because of playfair and UxPlay itself.
- Only `lib/` is built (static library `uxplaylib`). The GStreamer renderers are not built.

**Decision deferred:** because this app statically links GPLv3 code, distributing a binary would require releasing the app's corresponding source under GPLv3 (or replacing/relicensing those components). The licensing decision is deferred to shipping time. The spike is for internal use only.

## OpenSSL and libplist (build-time dependencies)

- OpenSSL 3 (Apache-2.0): `libcrypto.3.dylib` is embedded in `Contents/Frameworks` for the spike.
- libplist 2.8.0 (LGPL-2.1): linked statically from the micromamba env.
- Both come from `AIRTV_DEPS_PREFIX` (see `project.yml`).

## M8 packaging note (2026-10-30)

M8 produces the first `.app` (`scripts/package-app.sh`, ad-hoc signed, `dist/` is gitignored). Nothing changes in the GPL picture above: the bundle statically links GPLv3 UxPlay/playfair code, so it stays an internal build on Mike's own machines. If it is ever given to anyone else (or notarized for distribution), the deferred decision has to be made first: ship the app's source under GPLv3, or replace the GPL components. No decision needed now. `NSHumanReadableCopyright` in the bundle points at this file.
