# M0 Discovery Findings: stock UxPlay on the iMac

Date: 2026-10-30. Status: **GATE PASSED (17:05).** The Studio streams to stock UxPlay with no PIN, and macOS extends to it by default. Latency is the only number still open.

## Environment
- Receiver: iMac18,3, macOS 15.7.4, Intel. Firewall: disabled (`socketfilterfw --getglobalstate`). Hostname `Mikes-iMac`. Ethernet interface is "interface 7" in dns-sd, loopback is "1".
- Sender: Mac Studio (Mac15,14), instance "Mac Studio", seen from the iMac.
- **UxPlay 1.74 (Experimental)**, FDH2/UxPlay commit `534e2cc0e558d6c94bcc66964f8fc13ad73a6cdc` (2026-10-28), built from source in `thirdparty/UxPlay-spike/` (not committed). It uses Apple Bonjour (default) and GStreamer 1.28 from conda-forge. Videosink chosen: `glimagesink`. Decoder pipeline: `h264parse ! decodebin ! videoconvert ! videoscale ! autovideosink`.
- **Install deviation:** there is no `uxplay` Homebrew formula, and `brew install` fails because `/usr/local/Cellar` etc. belong to user `michaeljosephwork` (group admin) and the current user `michaeljoseph` is not in admin and has no sudo. The official GStreamer pkg needs root as well. Workaround, with no root: micromamba env (`~/.cache/m0-mamba/root/envs/ux`) providing gstreamer + plugins (base/good/bad/libav), openssl, cmake; libplist 2.8.0 built from source into that env; UxPlay built with cmake against it. The binary was relinked with `install_name_tool` so glib/gettext resolve to the env, not /usr/local (to avoid two glibs in one process). **For M2 (vendored library build) note that libplist and openssl are the dependencies of the UxPlay protocol library; GStreamer is needed only by UxPlay's renderers, which we replace.**

## How to reproduce
```
# build (once)
# micromamba env 'ux' must include zlib (cmake fails without it; found on the work-profile rebuild)
P=$HOME/.cache/m0-mamba/root/envs/ux; export PATH=$P/bin:$PATH PKG_CONFIG_PATH=$P/lib/pkgconfig
cd thirdparty/UxPlay-spike && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=$P && make -j8
# then install_name_tool -change /usr/local/opt/glib/lib/libgobject-2.0.0.dylib @rpath/libgobject-2.0.0.dylib uxplay  (same for libglib-2.0.0, libintl.8), codesign -f -s - uxplay
# run (logs appended to docs/m0-uxplay-session.log)
docs/run-uxplay-spike.sh        # = uxplay -n "Air TV Display" -fs -d, with GST_PLUGIN_PATH set
# observe on either Mac
dns-sd -B _airplay._tcp local.
dns-sd -L "Air TV Display@Mikes-iMac" _airplay._tcp local.
dns-sd -L "68FEF7129616@Air TV Display@Mikes-iMac" _raop._tcp local.
```
UxPlay's registered instance name is **"Air TV Display@Mikes-iMac"** (it appends `@hostname`), and the RAOP instance is `68FEF7129616@Air TV Display@Mikes-iMac`. Port **49333** (random per run, set with `-p` for a fixed one). deviceid 68:fe:f7:12:96:16 comes from the system MAC.

## TXT records registered by UxPlay (verbatim, this is the M1 template)
`_airplay._tcp`:
```
Air\032TV\032Display@Mikes-iMac._airplay._tcp.local. can be reached at Mikes-iMac.local.:49333 (interface 1) Flags: 1
 deviceid=68:fe:f7:12:96:16 features=0x527FFEE6,0x0 pw=false flags=0x4 model=AppleTV3,2 pk=f780220b2b360ffd7a7660d6c90dfa42ac6f1c4348bb2601578e781cd6233dbb pi=2e388006-13ba-4041-9a67-25dd4a43d536 srcvers=220.68 vv=2
```
`_raop._tcp`:
```
68FEF7129616@Air\032TV\032Display@Mikes-iMac._raop._tcp.local. can be reached at Mikes-iMac.local.:49333 (interface 1) Flags: 1
 ch=2 cn=0,1,2,3 da=true et=0,3,5 vv=2 ft=0x527FFEE6,0x0 am=AppleTV3,2 md=0,1,2 rhd=5.6.0.0 pw=false sf=0x4 sr=44100 ss=16 sv=false tp=UDP txtvers=1 vs=220.68 vn=65537 pk=f780220b2b360ffd7a7660d6c90dfa42ac6f1c4348bb2601578e781cd6233dbb
```
Raw full dns-sd output (with timestamps) is in the "Raw captures" section below.

### Reference: the Mac Studio's own (real macOS) `_airplay._tcp` TXT
```
 act=2 acl=0 deviceid=9E:AF:FB:37:70:DE fex=1c9/St5PFzg2IYxA features=0x4A7FCFD5,0x38174FDE rsf=0x8 flags=0x204 gid=81C49C3F-DE8F-469E-96FD-99EE9DD095B4 igl=0 gcgl=0 model=Mac15,14 at=4 protovers=1.1 pi=00b522ca-2199-4527-ba6f-04c0220622e0 psi=9EAFFB37-70DE-4F91-AC8B-4F71E8ECACBF pk=5ba2ccc0e5f45653a46ab0c0fb90f8d9a5bdf75f271c521943fae8eb4ee349e1 srcvers=960.13.1
```
Key difference for the plan: UxPlay advertises `model=AppleTV3,2`, `features=0x527FFEE6,0x0`, `flags=0x4`, `vv=2`, and `srcvers=220.68`. A real modern macOS receiver advertises far more feature bits (`0x4A7FCFD5,0x38174FDE`), `protovers=1.1`, `fex`, and `at=4`, among others. UxPlay presents itself as a 1080p Apple TV 3 class device (Mirror, no 4K/HEVC unless `-h265`). **Expectation to carry forward:** "Use As Separate Display" (Extend) is a macOS-to-macOS Sidecar-like capability that depends on feature bits and model; do not assume UxPlay's stock advertisement gets it. That is exactly what the pending checks decide.

## Bonjour reachability
- iMac -> network: `dns-sd -B _airplay._tcp local.` on the iMac lists the Mac Studio and other devices (Master TV, Office TV, Office, Bedroom, an AirPort Express), plus our own "Air TV Display@Mikes-iMac" on both interface 1 (loopback) and 7 (`en1`, **Wi-Fi**; ethernet `en0` is index 6 and was inactive on 2026-10-30, so the spike ran over Wi-Fi). `_raop._tcp` is the same. **iMac sees the Studio: VERIFIED.**
- Studio -> iMac: **VERIFIED 2026-10-30 16:03** (orchestrator over SSH after Mike installed the iMac's key). The Studio runs **macOS 26.6.2** (not Sequoia). `dns-sd -B _airplay._tcp local.` on the Studio lists "Air TV Display@Mikes-iMac" on interfaces 23 and 26; `dns-sd -L` resolves it to `Mikes-iMac.local.:49333` with the identical TXT (`model=AppleTV3,2 features=0x527FFEE6,0x0 flags=0x4 pw=false vv=2 srcvers=220.68 pk=f780…3dbb`). Raw capture under "Raw captures".
- SSH for workers: `ssh michaeljosephwork@Mac-Studio.local` now works non-interactively (host key ED25519 `SHA256:oK1TQBxEktMrOoeg9cPxdHwBF8yfvAq3NjDhbYw3/yI`, verified by Mike on the Studio; iMac `id_ed25519` installed in the Studio's authorized_keys).

## Handshake sequence (pairing, PIN, errors)
**OBSERVED 2026-10-30 17:00** (Studio work profile, macOS 26.6.2; iMac on gigabit ethernet `en0`, Wi-Fi off; UxPlay rebuilt in the work profile, port 57380).
- Listed in Control Center → Screen Mirroring as "Air TV Display@Mikes-iMac".
- Selecting it streamed straight away. **No PIN, no pairing prompt, no error.** No UxPlay flags were needed beyond `-n -fs -d`.
- RTSP request sequence from `docs/m0-uxplay-session.log`: `GET /info` → `POST /fp-setup` ×2 → `SETUP` (rtsp://<fe80 link-local>/…) → `GET /info` → `SETUP` → `RECORD`, then `POST /feedback` heartbeats. The sender connected over the **IPv6 link-local address on en0**. No `pair-setup`/`pair-verify` appeared in the request list, so the sender skipped them for a `pw=false` AppleTV3,2 receiver.

## Mirror / Extend availability, resolution, frame rate, latency
- **Extend: YES, by default.** macOS extended the Studio's desktop onto the iMac as a separate display. Nobody had to pick it under Displays. M7 is a verification milestone only (stays Sonnet).
- **Resolution:** 1920×1080 h264 (`raop_rtp_mirror width_source = 1920 height_source = 1080`; `/info` advertises 1920×1080, `maxFPS` 30).
- **Frame rate:** about 30 fps (video packets every ~33 ms in the log, matching the advertised `maxFPS` 30).
- **Latency:** PENDING (Mike's phone-video estimate).

## Flags and Sequoia notes (from the UxPlay 1.74 README; unverified against a Sequoia sender until Mike tries)
- Used: `-n "Air TV Display" -fs -d`. **`-fs` does not work on macOS**: README says fullscreen only works with X11, Wayland, vaapi, kms and D3D11. On macOS the window comes up as a normal glimagesink window and must be zoomed manually (the app we build will own the window, so this is a non-issue for the product but affects M0 viewing).
- `-nc` is on by default on macOS (workaround for window-close problems). Fine.
- README recommends **`-vsync no`** on macOS for mirroring-only (timestamp sync drops frames on macOS). Use this for the latency test. It also lowers latency.
- `-pin [nnnn]` / `-reg` / `-pw` only matter if pairing demands it; UxPlay's default (no pin) advertises `pw=false`, `flags=0x4`. Try with no flags first. If the Studio refuses with an auth error, restart with `-pin` (shows a PIN on screen) and record that. Nothing in the 1.74 README mentions macOS 15 sender caveats specifically; README claims macOS clients can use UxPlay as an emulated second display ("UxPlay can emulate a second display for macOS clients"), which is the Extend claim to confirm.
- `-h265` enables 4K/HEVC (ScreenMultiCodec bit 42) for M1+ clients and changes the default to 3840x2160. Not used in this baseline.
- `-p` pins the port (49333 was random).

## Pending hands-on checks for Mike (at the Mac Studio GUI)
UxPlay is already running on the iMac (see summary for PID). Keep the iMac awake and logged in.
1. **Studio sees it via Bonjour.** In Terminal on the Studio: `dns-sd -B _airplay._tcp local.` (Ctrl-C after 5 s). Expect: "Air TV Display@Mikes-iMac". If missing: record that, it is a key finding; check the VLAN/mDNS path and `socketfilterfw --getglobalstate` (currently disabled on the iMac).
2. **Listed in Screen Mirroring.** Control Center -> Screen Mirroring. Expect "Air TV Display@Mikes-iMac" in the list. Note exactly what name shows.
3. **Select it.** Record: instant stream, PIN prompt (the iMac log will show it only if started with `-pin`), or an error dialog (copy the text). Then read `docs/m0-uxplay-session.log` for the RTSP exchange and save it (it is already being appended).
4. **If video flows:** System Settings -> Displays (or the Control Center Screen Mirroring list while connected). Is **"Use As Separate Display"** offered next to the mirror choice? Click it if so; confirm the iMac shows an independent desktop (move a window off the Studio's screen). Expect: unknown, this is the experiment.
5. **Resolution and frame rate.** Search the log: `grep -iE "width|height|fps|resolution|framerate" docs/m0-uxplay-session.log` and copy the lines.
6. **Latency.** Restart with `-vsync no` first (`pkill uxplay; docs/run-uxplay-spike.sh -vsync no &`). Then film both screens with a phone at 60 fps (slow-mo is better), move the cursor or run a stopwatch on the Studio, count frames between the Studio change and the same change on the iMac. Expect on gigabit: roughly 100-250 ms.
7. Add what you saw to the sections above, or tell the orchestrator.

## Raw captures
```
Lookup Air TV Display@Mikes-iMac._airplay._tcp.local.
DATE: ---Fri 30 Oct 2026---
15:38:09.114  ...STARTING...
15:38:09.115  Air\032TV\032Display@Mikes-iMac._airplay._tcp.local. can be reached at Mikes-iMac.local.:49333 (interface 1) Flags: 1
 deviceid=68:fe:f7:12:96:16 features=0x527FFEE6,0x0 pw=false flags=0x4 model=AppleTV3,2 pk=f780220b2b360ffd7a7660d6c90dfa42ac6f1c4348bb2601578e781cd6233dbb pi=2e388006-13ba-4041-9a67-25dd4a43d536 srcvers=220.68 vv=2
15:38:09.115  Air\032TV\032Display@Mikes-iMac._airplay._tcp.local. can be reached at Mikes-iMac.local.:49333 (interface 7)
 deviceid=68:fe:f7:12:96:16 features=0x527FFEE6,0x0 pw=false flags=0x4 model=AppleTV3,2 pk=f780220b2b360ffd7a7660d6c90dfa42ac6f1c4348bb2601578e781cd6233dbb pi=2e388006-13ba-4041-9a67-25dd4a43d536 srcvers=220.68 vv=2

Lookup 68FEF7129616@Air TV Display@Mikes-iMac._raop._tcp.local.
DATE: ---Fri 30 Oct 2026---
15:38:15.228  ...STARTING...
15:38:15.228  68FEF7129616@Air\032TV\032Display@Mikes-iMac._raop._tcp.local. can be reached at Mikes-iMac.local.:49333 (interface 1) Flags: 1
 ch=2 cn=0,1,2,3 da=true et=0,3,5 vv=2 ft=0x527FFEE6,0x0 am=AppleTV3,2 md=0,1,2 rhd=5.6.0.0 pw=false sf=0x4 sr=44100 ss=16 sv=false tp=UDP txtvers=1 vs=220.68 vn=65537 pk=f780220b2b360ffd7a7660d6c90dfa42ac6f1c4348bb2601578e781cd6233dbb
15:38:15.228  68FEF7129616@Air\032TV\032Display@Mikes-iMac._raop._tcp.local. can be reached at Mikes-iMac.local.:49333 (interface 7)
 ch=2 cn=0,1,2,3 da=true et=0,3,5 vv=2 ft=0x527FFEE6,0x0 am=AppleTV3,2 md=0,1,2 rhd=5.6.0.0 pw=false sf=0x4 sr=44100 ss=16 sv=false tp=UDP txtvers=1 vs=220.68 vn=65537 pk=f780220b2b360ffd7a7660d6c90dfa42ac6f1c4348bb2601578e781cd6233dbb
```
`dns-sd -B` (iMac, _airplay._tcp, 15:37):
```
Mac Studio / Master TV / Office TV / Office / Michael's AirPort Express / Office (2) / Bedroom / Air TV Display@Mikes-iMac (if 1 and if 7)
```

`dns-sd -B _airplay._tcp local.` (Studio, macOS 26.6.2, 16:03:34):
```
Mac Studio / Master TV / Bedroom / Air TV Display@Mikes-iMac (if 26 and if 23) / Michael's AirPort Express / Office / Office TV / Office (2)
```

## M1: registration from our own process
Date: 2026-10-30. Code: `tools/discovery-cli/discovery-cli.c` (plain C, `DNSServiceRegister` from libSystem, no dependencies).

**Build / run**
```
cc -Wall -o tools/discovery-cli/discovery-cli tools/discovery-cli/discovery-cli.c
tools/discovery-cli/discovery-cli 7100 "Air TV Display M1"     # <port> [name]; Ctrl-C to stop
```
**Recipe**
- Two registrations on the same port: `_airplay._tcp` with instance `<name>`, and `_raop._tcp` with instance `<DEVICEID12>@<name>` (deviceid as 12 uppercase hex digits, no colons). Default host and domain (`NULL`), all interfaces (`0`). Port passed as `htons(port)`.
- TXT built with `TXTRecordCreate`/`TXTRecordSetValue`, same key order as UxPlay. Values are UxPlay's byte for byte, except these substitutions: `deviceid` (and the RAOP name prefix) from en0's MAC (`getifaddrs`, `AF_LINK`; stable), the instance name, and `pk`/`pi`.
- `_airplay._tcp`: `deviceid features=0x527FFEE6,0x0 pw=false flags=0x4 model=AppleTV3,2 pk pi srcvers=220.68 vv=2`
- `_raop._tcp`: `ch=2 cn=0,1,2,3 da=true et=0,3,5 vv=2 ft=0x527FFEE6,0x0 am=AppleTV3,2 md=0,1,2 rhd=5.6.0.0 pw=false sf=0x4 sr=44100 ss=16 sv=false tp=UDP txtvers=1 vs=220.68 vn=65537 pk`
- **`pk`/`pi`: generated our own, not copied.** `pk` is UxPlay's Ed25519 public key and is only meaningful with its private key (used in pair-setup/pair-verify); copying it would advertise a key we cannot sign with, and make us indistinguishable from the running UxPlay. For M1 (no RTSP) `pk` is 32 random bytes (hex) and `pi` a random UUID, persisted in `~/.air-tv-display-m1.ids` so they stay stable. **M4 must replace `pk` with the real pairing public key** from the library (and keep `pi` stable).

**Studio verification (macOS 26.6.2, over SSH, 17:05)**
- `dns-sd -B _airplay._tcp local.` lists `Air TV Display M1` (if 26 and if 23), and `dns-sd -B _raop._tcp local.` lists `68FEF7129616@Air TV Display M1`.
- `dns-sd -L "Air TV Display M1" _airplay._tcp local.` ->
```
Air\032TV\032Display\032M1._airplay._tcp.local. can be reached at Mikes-iMac.local.:7100
 deviceid=68:fe:f7:12:96:16 features=0x527FFEE6,0x0 pw=false flags=0x4 model=AppleTV3,2 pk=335047d97b66329dfee39d1103b61808ee6a597de2d5c15fe667a5b2416cc6fc pi=556ea270-f25a-411c-9316-7ca30f321823 srcvers=220.68 vv=2
```
- `dns-sd -L "68FEF7129616@Air TV Display M1" _raop._tcp local.` ->
```
68FEF7129616@Air\032TV\032Display\032M1._raop._tcp.local. can be reached at Mikes-iMac.local.:7100
 ch=2 cn=0,1,2,3 da=true et=0,3,5 vv=2 ft=0x527FFEE6,0x0 am=AppleTV3,2 md=0,1,2 rhd=5.6.0.0 pw=false sf=0x4 sr=44100 ss=16 sv=false tp=UDP txtvers=1 vs=220.68 vn=65537 pk=335047d9...cc6fc
```
- **Shared deviceid with the live stock UxPlay (same en0 MAC): both instances appear** in `-B` for both service types (different instance names, different ports 57380 vs 7100). The shared deviceid did not hide either at the Bonjour level. Whether Screen Mirroring de-duplicates by deviceid is a GUI question, see the pending check below.
- Stock UxPlay (PID 29841) was left running and untouched.

**Pending hands-on (Mike, Studio GUI):** Control Center -> Screen Mirroring lists "Air TV Display M1"; selecting it is expected to fail (no RTSP listener on 7100), record the exact error as the M3 baseline; also note whether the stock "Air TV Display@Mikes-iMac" is still listed alongside it.

## M8: receiver-side latency (fixture feeder, offline)

Measured with `--play-fixture Tests/Fixtures/synthetic-1080p.h264` (1080p H.264, 4 loops at 30 fps, or 6 loops at 60 fps) on the iMac (i7-7700K, Radeon Pro 580, 5K panel at 60 Hz). "Arrival" is the moment a decrypted buffer reaches the video sink; "on screen" is `MTLDrawable.presentedTime` (on-glass, reported by the compositor for 99% of frames). The sender's share (capture, encode, network) is not included and is a fixed floor.

| Config | fps | arrival -> decoded p50 | arrival -> on screen p50 / p95 |
|---|---|---|---|
| M5 baseline: `_1xRealTimePlayback`, vsync on, 2 drawables (3 runs) | 30 | 2.0 ms | 28.4 to 33.9 / 30.1 to 35.7 ms |
| vsync on, 2 drawables | 60 | 2.0 ms | 50.3 / 51.6 ms |
| async without the 1x hint, vsync on (2 runs) | 30 | 1.9 ms | 22.7 to 31.1 ms (no real change; vsync phase dominates) |
| sync decode, vsync on | 30 | 1.8 ms | 23.9 ms |
| vsync on, 3 drawables | 30 | 1.9 ms | 26.1 ms |
| vsync off (2 runs) | 30 | 2.0 ms | 7.4 to 7.5 / 8.7 to 8.8 ms |
| vsync off | 60 | 1.9 ms | 6.5 / 7.5 ms |
| **M8 default, Release build** (async, vsync off, 2 drawables) | 30 | 1.6 ms | **6.8 / 8.1 ms** |
| **M8 default, Release build** | 60 | 1.6 ms | **5.7 / 7.0 ms** |

Result: decode is ~2 ms in every mode; the present path was the receiver's whole latency. Turning vsync off removes 20 to 45 ms. The first frame of a session takes ~180 to 200 ms (VideoToolbox session creation), once. Tearing with vsync off still needs a visual check on a live stream (`AIRTV_VSYNC=1` restores vsync). End-to-end (click to motion) with a phone camera is still pending, and should be recorded here next to the M0 stock-UxPlay figure.
