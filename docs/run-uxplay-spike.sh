#!/bin/bash
# SPDX-License-Identifier: MIT
# Starts stock UxPlay (M0 spike) with verbose logging. See docs/discovery-findings.md.
# Toolchain (no sudo available for brew on this iMac): micromamba env at ~/.cache/m0-mamba/root/envs/ux
P=$HOME/.cache/m0-mamba/root/envs/ux
export GST_PLUGIN_PATH=$P/lib/gstreamer-1.0 GST_PLUGIN_SYSTEM_PATH=$P/lib/gstreamer-1.0
export GST_PLUGIN_SCANNER=$P/libexec/gstreamer-1.0/gst-plugin-scanner
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec "$REPO/thirdparty/UxPlay-spike/build/uxplay" -n "Air TV Display" -fs -d "$@" 2>&1 | tee -a "$REPO/docs/m0-uxplay-session.log"
