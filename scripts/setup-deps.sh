#!/bin/bash
# SPDX-License-Identifier: MIT
# Builds the third-party dependency prefix the Xcode project links against (AIRTV_DEPS_PREFIX):
# universal (arm64 + x86_64) OpenSSL libcrypto.3.dylib and static libplist 2.8.0, plus headers.
# No sudo, no Homebrew: everything lands under $AIRTV_DEPS_ROOT (default ~/.cache/airtv-deps).
# Works on Intel and Apple silicon; re-running skips finished steps (FORCE=1 rebuilds).
#
#   scripts/setup-deps.sh            # -> ~/.cache/airtv-deps/universal
#
# Layout:
#   mamba/           micromamba package cache        env-<arch>/  conda-forge openssl per arch
#   src/             libplist source tarball          plist-<arch>/ libplist static build per arch
#   universal/       include/ + lib/ (lipo'd), what project.yml points at
set -euo pipefail

ROOT="${AIRTV_DEPS_ROOT:-$HOME/.cache/airtv-deps}"
OPENSSL_VERSION="3.6.5"
PLIST_VERSION="2.8.0"
PLIST_URL="https://github.com/libimobiledevice/libplist/releases/download/$PLIST_VERSION/libplist-$PLIST_VERSION.tar.bz2"
PLIST_SHA256="b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a"
MIN_MACOS="13.0"
ARCHS=(arm64 x86_64)
FORCE="${FORCE:-0}"

mkdir -p "$ROOT/src"
[ "$FORCE" = 1 ] && rm -rf "$ROOT"/env-* "$ROOT"/plist-* "$ROOT/universal"

platform_for() { [ "$1" = arm64 ] && echo osx-arm64 || echo osx-64; }
host_for() { [ "$1" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin; }

# ── micromamba ───────────────────────────────────────────────────────────────
# Any existing micromamba works (MAMBA=..., PATH, or the M0 one); otherwise fetch it for this host.
MAMBA="${MAMBA:-$(command -v micromamba || true)}"
[ -z "$MAMBA" ] && [ -x "$HOME/.cache/m0-mamba/bin/micromamba" ] && MAMBA="$HOME/.cache/m0-mamba/bin/micromamba"
if [ -z "$MAMBA" ]; then
    MAMBA="$ROOT/bin/micromamba"
    if [ ! -x "$MAMBA" ]; then
        host="$( [ "$(uname -m)" = arm64 ] && echo osx-arm64 || echo osx-64 )"
        echo "==> Downloading micromamba ($host)"
        mkdir -p "$ROOT/bin"
        curl -fsSL "https://micro.mamba.pm/api/micromamba/$host/latest" | tar -xj -C "$ROOT" bin/micromamba
    fi
fi
echo "==> micromamba: $MAMBA ($("$MAMBA" --version))"

# ── OpenSSL per arch (conda-forge has no static libcrypto, so the dylib is embedded) ─────────
for arch in "${ARCHS[@]}"; do
    env="$ROOT/env-$arch"
    if [ -f "$env/lib/libcrypto.3.dylib" ] && ls "$env/conda-meta/openssl-$OPENSSL_VERSION-"*.json >/dev/null 2>&1; then
        echo "ok   openssl $OPENSSL_VERSION ($arch)"
        continue
    fi
    echo "==> openssl $OPENSSL_VERSION for $arch"
    rm -rf "$env"
    "$MAMBA" create -y -q -r "$ROOT/mamba" -p "$env" --platform "$(platform_for "$arch")" \
        -c conda-forge "openssl=$OPENSSL_VERSION" >/dev/null
done

# ── libplist static per arch ─────────────────────────────────────────────────
tarball="$ROOT/src/libplist-$PLIST_VERSION.tar.bz2"
if [ ! -f "$tarball" ]; then
    echo "==> Downloading libplist $PLIST_VERSION"
    curl -fsSL -o "$tarball.part" "$PLIST_URL"
    mv "$tarball.part" "$tarball"
fi
echo "$PLIST_SHA256  $tarball" | shasum -a 256 -c --quiet - || { echo "!! libplist tarball checksum mismatch: $tarball" >&2; exit 1; }

for arch in "${ARCHS[@]}"; do
    out="$ROOT/plist-$arch"
    if [ -f "$out/lib/libplist-2.0.a" ]; then echo "ok   libplist $PLIST_VERSION ($arch)"; continue; fi
    echo "==> libplist $PLIST_VERSION for $arch"
    work="$ROOT/src/build-plist-$arch"
    rm -rf "$work" "$out"; mkdir -p "$work"
    tar -xjf "$tarball" -C "$work" --strip-components 1
    # Cross builds (arm64 on Intel and vice versa) just need -arch and a matching --host.
    (cd "$work" && ./configure -q --host="$(host_for "$arch")" --prefix="$out" \
        --enable-static --disable-shared --without-cython --without-tests \
        CC="clang -arch $arch" CXX="clang++ -arch $arch" \
        CFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS" CXXFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS" \
        && make -s -j"$(sysctl -n hw.ncpu)" && make -s install) >"$work.log" 2>&1 \
        || { echo "!! libplist build failed for $arch, see $work.log" >&2; exit 1; }
done

# ── universal prefix ─────────────────────────────────────────────────────────
U="$ROOT/universal"
echo "==> Assembling $U"
rm -rf "$U"; mkdir -p "$U/include" "$U/lib"
# OpenSSL's headers are generated per platform; both are LP64 Darwin, so they must be identical.
if ! diff -rq "$ROOT/env-arm64/include/openssl" "$ROOT/env-x86_64/include/openssl" >/dev/null; then
    echo "!! openssl headers differ between arm64 and x86_64; a single include dir is not safe" >&2
    diff -rq "$ROOT/env-arm64/include/openssl" "$ROOT/env-x86_64/include/openssl" >&2 || true
    exit 1
fi
cp -R "$ROOT/env-x86_64/include/openssl" "$U/include/"
cp -R "$ROOT/plist-x86_64/include/plist" "$U/include/"
lipo -create "$ROOT/env-arm64/lib/libcrypto.3.dylib" "$ROOT/env-x86_64/lib/libcrypto.3.dylib" \
    -output "$U/lib/libcrypto.3.dylib"
ln -s libcrypto.3.dylib "$U/lib/libcrypto.dylib"
install_name_tool -id "@rpath/libcrypto.3.dylib" "$U/lib/libcrypto.3.dylib" 2>/dev/null
codesign --force --sign - "$U/lib/libcrypto.3.dylib"
lipo -create "$ROOT/plist-arm64/lib/libplist-2.0.a" "$ROOT/plist-x86_64/lib/libplist-2.0.a" \
    -output "$U/lib/libplist-2.0.a"

lipo -info "$U/lib/libcrypto.3.dylib" "$U/lib/libplist-2.0.a"
echo "==> Done. project.yml's AIRTV_DEPS_PREFIX default is \$(HOME)/.cache/airtv-deps/universal;"
echo "    for another location pass AIRTV_DEPS_PREFIX=$U to xcodebuild."
