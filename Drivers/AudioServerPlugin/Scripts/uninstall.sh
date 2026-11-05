#!/bin/bash
# Uninstall the Apogee Symphony IO AudioServerPlugin + MaestroVolumeProxy.
#
# Removes all installed components and re-enables the legacy Apogee HAL plugin
# (if it was disabled by install.sh), restoring the system to pre-ASP state.
#
# Components removed:
#   - /Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver  (AudioServerPlugin)
#   - /usr/local/bin/MaestroVolumeProxy                (XPC→socket proxy)
#   - /Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist
#
# WARNING: Restarting coreaudiod will kill all running audio.
# Usage: sudo ./uninstall.sh
set -euo pipefail

DRIVER_NAME="ApogeeSymIO.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
PROXY_PLIST="com.danielraffel.Maestro.volumeproxy"
PROXY_PLIST_DST="/Library/LaunchDaemons/${PROXY_PLIST}.plist"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ASP] ERROR: Must run as root (sudo ./uninstall.sh)"
    exit 1
fi

# ── 1. Stop and remove MaestroVolumeProxy ────────────────────────────────────

echo "[ASP] Stopping MaestroVolumeProxy..."
pkill -x MaestroVolumeProxy 2>/dev/null || true
sleep 1
launchctl bootout system/$PROXY_PLIST 2>/dev/null || true

if [ -f "$PROXY_PLIST_DST" ]; then
    rm -f "$PROXY_PLIST_DST"
    echo "[ASP] Removed $PROXY_PLIST_DST"
fi

if [ -f /usr/local/bin/MaestroVolumeProxy ]; then
    rm -f /usr/local/bin/MaestroVolumeProxy
    echo "[ASP] Removed /usr/local/bin/MaestroVolumeProxy"
fi

# ── 2. Remove AudioServerPlugin driver bundle ────────────────────────────────

if [ -d "$INSTALL_DIR/$DRIVER_NAME" ]; then
    echo "[ASP] Removing $INSTALL_DIR/$DRIVER_NAME..."
    rm -rf "$INSTALL_DIR/$DRIVER_NAME"
else
    echo "[ASP] $DRIVER_NAME was not installed."
fi

# ── 3. Re-enable legacy Apogee HAL plugin ────────────────────────────────────
# install.sh disables the plugin by renaming Info.plist → Info.plist.disabled-asp
# (the bundle directory itself is preserved for the daemon binary).

LEGACY_BUNDLE="/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyIOUSBPlugIn.bundle"
LEGACY_PLIST_DISABLED="$LEGACY_BUNDLE/Contents/Info.plist.disabled-asp"
LEGACY_PLIST="$LEGACY_BUNDLE/Contents/Info.plist"

if [ -f "$LEGACY_PLIST_DISABLED" ]; then
    echo "[ASP] Re-enabling legacy Apogee HAL plugin (restoring Info.plist)..."
    mv "$LEGACY_PLIST_DISABLED" "$LEGACY_PLIST"
    echo "[ASP] Legacy plugin restored"
elif [ -f "$LEGACY_PLIST" ]; then
    echo "[ASP] Legacy plugin already enabled."
else
    echo "[ASP] No legacy plugin Info.plist found."
fi

# ── 4. Restart coreaudiod ────────────────────────────────────────────────────

echo "[ASP] Restarting coreaudiod (this will interrupt all audio)..."
killall coreaudiod 2>/dev/null || true
sleep 3

echo "[ASP] Uninstall complete. System restored to pre-ASP state."
