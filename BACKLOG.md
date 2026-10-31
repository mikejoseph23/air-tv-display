# Backlog

- **Landing page screenshot.** Add a hero image to `website/index.html` (removed 2026-10-31 while it was a placeholder). Best: a photo of the two Macs side by side with the iMac extended. Steps: save it as `website/screenshot.png` (about 16:9, shows up to 820 px wide), restore the `<figure class="shot">` block, its `.shot` CSS and the `og:image` meta (see commit history for "Landing page: drop the screenshot slot"), and add `screenshot.png` back to `scripts/stage-release.sh` and the required list in `deploy/pack-for-lymedeploy.sh`.
