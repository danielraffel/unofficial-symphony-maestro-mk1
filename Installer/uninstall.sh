#!/bin/bash
# Uninstall Symphony Maestro
#
# Removes all installed components and restores the original Apogee HAL plugin.
# Usage: sudo /Applications/Maestro.app/Contents/Resources/uninstall.sh
#    or: sudo ./uninstall.sh
#
# This script is also bundled inside Maestro.app/Contents/Resources/ for convenience.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo $0)"
    exit 1
fi

echo ""
echo "=== Symphony Maestro Uninstaller ==="
echo ""
echo "This will remove:"
echo "  - /Applications/Maestro.app"
echo "  - The Symphony ThunderBridge driver extension (if activated)"
echo "  - /Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver"
echo "  - /usr/local/bin/MaestroVolumeProxy"
echo "  - /Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist"
echo ""
echo "And restore the original Apogee HAL plugin (if it was disabled)."
echo ""

# Prompt for confirmation (skip if running non-interactively)
if [ -t 0 ]; then
    read -p "Proceed with uninstall? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""

# ── 1. Kill running app + remove its per-user auto-launch agent ──────────────
echo "[1/8] Stopping Maestro app and removing its auto-launch agent..."
pkill -x MaestroApp 2>/dev/null || true
sleep 1
# The app installs a per-user LaunchAgent that relaunches Maestro whenever a Symphony USB device
# is plugged in. If we don't remove it, after uninstall launchd keeps trying to spawn a deleted
# binary on every plug (throttled failures + an orphaned Login Items entry). We run as root, so
# target the INVOKING user's session, not root's.
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_UID="$(id -u "$REAL_USER" 2>/dev/null || echo "")"
AGENT_LABEL="com.danielraffel.Maestro.autolaunch"
if [ -n "$REAL_UID" ]; then
    launchctl bootout "gui/$REAL_UID/$AGENT_LABEL" 2>/dev/null || true
fi
AGENT_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -z "$AGENT_HOME" ] && AGENT_HOME="/Users/$REAL_USER"
rm -f "$AGENT_HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"

# ── 2. Stop and unload proxy daemon ─────────────────────────────────────────
echo "[2/8] Stopping MaestroVolumeProxy..."
pkill -x MaestroVolumeProxy 2>/dev/null || true
sleep 1
launchctl bootout system/com.danielraffel.Maestro.volumeproxy 2>/dev/null || true

# ── 3. Remove proxy binary ──────────────────────────────────────────────────
echo "[3/8] Removing proxy binary..."
rm -f /usr/local/bin/MaestroVolumeProxy

# ── 4. Remove LaunchDaemon plist ─────────────────────────────────────────────
echo "[4/8] Removing LaunchDaemon plist..."
rm -f /Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist

# ── 5. Remove AudioServerPlugin ─────────────────────────────────────────────
echo "[5/8] Removing AudioServerPlugin..."
rm -rf /Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver

# ── 6. Restore legacy Apogee HAL plugin ─────────────────────────────────────
echo "[6/8] Restoring legacy Apogee HAL plugin..."
RESTORED=0
for BUNDLE_DIR in "/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyIOUSBPlugIn.bundle" \
                   "/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyPlugin.bundle" \
                   "/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/usbApogeePlugin.bundle"; do
    for SUFFIX in ".disabled-maestro" ".disabled-asp"; do
        DISABLED="$BUNDLE_DIR/Contents/Info.plist$SUFFIX"
        ORIGINAL="$BUNDLE_DIR/Contents/Info.plist"
        if [ -f "$DISABLED" ] && [ ! -f "$ORIGINAL" ]; then
            mv "$DISABLED" "$ORIGINAL"
            echo "  Restored: $(basename "$BUNDLE_DIR")"
            RESTORED=$((RESTORED + 1))
        fi
    done
done
if [ "$RESTORED" -eq 0 ]; then
    echo "  No disabled Apogee plugins found (nothing to restore)"
fi

# ── 7. Deactivate the ThunderBridge driver extension ─────────────────────────
# Deleting Maestro.app does NOT remove the activated system extension — it would orphan in
# /Library/SystemExtensions/ and stay registered. Deactivate it while the app still exists.
echo "[7/8] Deactivating ThunderBridge driver extension..."
DEXT_ID="com.danielraffel.maestro.thunderbridge"
DEXT_NEEDS_MANUAL=0
if systemextensionsctl list 2>/dev/null | grep -q "$DEXT_ID"; then
    # `systemextensionsctl uninstall` only works with developer mode on (SIP disabled). On a normal
    # SIP-enabled Mac it fails harmlessly — macOS requires the user to remove driver extensions from
    # System Settings — so we detect that and print instructions.
    TEAM_ID=$(codesign -dvv "$APP/Contents/Library/SystemExtensions/$DEXT_ID.dext" 2>&1 | awk -F= '/TeamIdentifier=/{print $2; exit}')
    [ -n "$TEAM_ID" ] && systemextensionsctl uninstall "$TEAM_ID" "$DEXT_ID" 2>/dev/null || true
    sleep 1
    if systemextensionsctl list 2>/dev/null | grep -q "$DEXT_ID"; then
        DEXT_NEEDS_MANUAL=1
        echo "  Driver extension still registered — macOS requires you to remove it manually:"
        echo "    System Settings > General > Login Items & Extensions > Driver Extensions"
        echo "    → turn off / remove 'Symphony Thunderbridge'."
    else
        echo "  Driver extension deactivated."
    fi
else
    echo "  No ThunderBridge driver extension activated (nothing to deactivate)."
fi

# ── 8. Remove app (only if it's actually OUR app) ───────────────────────────
echo "[8/8] Removing Maestro.app..."
APP="/Applications/Maestro.app"
if [ -d "$APP" ]; then
    APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
    if [ "$APP_ID" = "com.danielraffel.maestro" ]; then
        rm -rf "$APP"
    else
        echo "  Skipped: /Applications/Maestro.app has bundle id '$APP_ID' (not ours) — not removing."
    fi
fi

# ── 8. Restart coreaudiod ───────────────────────────────────────────────────
echo ""
echo "Restarting coreaudiod..."
killall coreaudiod 2>/dev/null || true
sleep 3

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "Symphony Maestro's app, plug-in, and volume service have been removed."
if [ "${DEXT_NEEDS_MANUAL:-0}" -eq 1 ]; then
    echo ""
    echo "ONE MANUAL STEP REMAINS — remove the Thunderbolt driver extension:"
    echo "  System Settings > General > Login Items & Extensions > Driver Extensions"
    echo "  → turn off / remove 'Symphony Thunderbridge'."
    echo "  (macOS does not allow scripts to remove a driver extension while SIP is on.)"
fi
if [ "$RESTORED" -gt 0 ]; then
    echo "The original Apogee HAL plugin has been restored."
    echo "You may need to reinstall Apogee software for full functionality:"
    echo "  https://22712264.fs1.hubspotusercontent-na1.net/hubfs/22712264/Software%20Installers/Symphony%20IO/SymphonyIO_Release_5.5.dmg"
fi
echo ""
echo "Log: /tmp/maestro-installer.log"
