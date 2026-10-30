# M0 Discovery Findings: stock UxPlay on the iMac

Date: 2026-10-30. Status: **PARTIAL.** Discovery and the iMac side are verified. Everything that needs the Mac Studio GUI is **pending hands-on** and is not guessed at below.

## Environment
- Receiver: iMac18,3, macOS 15.7.4, Intel. Firewall: disabled (`socketfilterfw --getglobalstate`). Hostname `Mikes-iMac`. Ethernet interface is "interface 7" in dns-sd, loopback is "1".
- Sender: Mac Studio (Mac15,14), instance "Mac Studio", seen from the iMac.
- **UxPlay 1.74 (Experimental)**, FDH2/UxPlay commit `534e2cc0e558d6c94bcc66964f8fc13ad73a6cdc` (2026-10-28), built from source in `thirdparty/UxPlay-spike/` (not committed). It uses Apple Bonjour (default) and GStreamer 1.28 from conda-forge. Videosink chosen: `glimagesink`. Decoder pipeline: `h264parse ! decodebin ! videoconvert ! videoscale ! autovideosink`.
- **Install deviation:** there is no `uxplay` Homebrew formula, and `brew install` fails because `/usr/local/Cellar` etc. belong to user `michaeljosephwork` (group admin) and the current user `michaeljoseph` is not in admin and has no sudo. The official GStreamer pkg needs root as well. Workaround, with no root: micromamba env (`~/.cache/m0-mamba/root/envs/ux`) providing gstreamer + plugins (base/good/bad/libav), openssl, cmake; libplist 2.8.0 built from source into that env; UxPlay built with cmake against it. The binary was relinked with `install_name_tool` so glib/gettext resolve to the env, not /usr/local (to avoid two glibs in one process). **For M2 (vendored library build) note that libplist and openssl are the dependencies of the UxPlay protocol library; GStreamer is needed only by UxPlay's renderers, which we replace.**

## How to reproduce
```
# build (once)
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
- iMac -> network: `dns-sd -B _airplay._tcp local.` on the iMac lists the Mac Studio and other devices (Master TV, Office TV, Office, Bedroom, an AirPort Express), plus our own "Air TV Display@Mikes-iMac" on both interface 1 (loopback) and 7 (ethernet). `_raop._tcp` is the same. **iMac sees the Studio: VERIFIED.**
- Studio -> iMac: **NOT VERIFIED from this side.** The worker's SSH to `michaeljosephwork@Mac-Studio.local` failed with "Host key verification failed" (the Studio's host key is not in `~/.ssh/known_hosts`; I did not auto-accept an unknown host key). The iMac advertises on the ethernet interface (interface 7) alongside all the other devices, and the firewall is off, so a negative result is unlikely. Mike confirms below.

## Handshake sequence (pairing, PIN, errors)
**PENDING HANDS-ON.** UxPlay is running and logging; no client has connected yet (`docs/m0-uxplay-session.log` has only startup lines). Nothing was observed, so nothing is claimed.

## Mirror / Extend availability, resolution, frame rate, latency
**PENDING HANDS-ON.** UxPlay's requested stream is `-s 1920x1080@60` by default (the client may negotiate differently). Expected values only: 1920x1080, h264. Not measured.

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
