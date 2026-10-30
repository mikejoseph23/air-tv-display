# Hands-on checklist (deferred gates)

Everything automated is done on `main`. Run these from the **Mac Studio's work profile**, with the iMac on ethernet and its Wi-Fi off. Tell the orchestrator the result for each numbered item. Detailed steps per milestone are in `.orchestrator/airplay-receiver-plan/processed/worker-summary-*.md` (Review Materials sections).

## A. Baseline: stock UxPlay (running now)

1. **Latency (M0):** mirror to "Air TV Display@Mikes-iMac", then film a cursor move on both screens with your phone (slow-mo if you can). Note the delay in ms.

## B. Our app

Stop stock UxPlay first, because it shares our deviceid and key: `pkill -9 -f uxplay` (on the iMac; plain `pkill` does not stop it).

Launch: `AIRTV_HUD=1 /Users/michaeljosephwork/git/air-tv-display/dist/AirTVDisplay.app/Contents/MacOS/AirTVDisplay --autostart`

2. **Launch (M2T):** the fullscreen "waiting for AirPlay…" window and the menu-bar item appear. `Esc` quits (relaunch after).
3. **Listed (M1/M2T):** Studio Control Center → Screen Mirroring lists "Air TV Display Dev".
4. **Connect (M3/M4/M4T):** select it. Expected: no PIN, the menu-bar state goes idle → pairing → streaming, and `logs/rtsp.log` shows `GET /info`, `fp-setup` ×2, `SETUP`, `RECORD`, then SPS/PPS/IDR.
5. **Extend (M7/M7T):** the Studio extends onto the iMac (as stock did). Drag windows across; nothing squished; Mirror is also offered.
6. **Video (M5/M5T):** move windows. Motion is smooth enough, the HUD shows ~30 fps and a few ms decode, and there's no visible tearing (vsync is off by default; if it tears, retry with `AIRTV_VSYNC=1`).
7. **Latency (M8):** the same phone test as item 1. It should be no worse than stock.
8. **Audio (M6/M6T):** play a video with speech on the extended screen. Audio comes from the iMac, lips are in sync, there's no drift over 60 s, and the audio stops when the stream stops.
9. **Reconnect (M8T):** put the Studio to sleep, wake it, and re-select the iMac. It reconnects without restarting the app (within ~15 s). Stop mirroring, and the app returns to "waiting…". Do ~10 connect/disconnect cycles.

## C. Afterward

Restart stock UxPlay if you want it back: `cd /Users/michaeljosephwork/git/air-tv-display && nohup docs/run-uxplay-spike.sh >/dev/null 2>&1 & disown`
