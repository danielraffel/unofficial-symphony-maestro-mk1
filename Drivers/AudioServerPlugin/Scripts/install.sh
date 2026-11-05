#!/bin/bash
# Install the Apogee Symphony IO AudioServerPlugin + MaestroVolumeProxy daemon.
#
# The AudioServerPlugin runs in a sandboxed helper that cannot open UNIX sockets.
# MaestroVolumeProxy is a LaunchDaemon that bridges XPC (allowed by the sandbox)
# to the Apogee daemon UNIX socket, forwarding volume/mute commands to hardware.
#
# Both must be installed together:
#   - ApogeeSymIO.driver → /Library/Audio/Plug-Ins/HAL/
#   - MaestroVolumeProxy → /usr/local/bin/
#   - com.danielraffel.Maestro.volumeproxy.plist → /Library/LaunchDaemons/
#
# WARNING: Restarting coreaudiod will kill all running audio.
# Usage: sudo ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ASP_DIR/build"
PROXY_DIR="$(cd "$ASP_DIR/../VolumeProxy" && pwd)"
DRIVER_NAME="ApogeeSymIO.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
PROXY_PLIST="com.danielraffel.Maestro.volumeproxy.plist"
DAEMON_PLIST_SRC="$PROXY_DIR/$PROXY_PLIST"
DAEMON_PLIST_DST="/Library/LaunchDaemons/$PROXY_PLIST"

# Check we're running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ASP] ERROR: Must run as root (sudo ./install.sh)"
    exit 1
fi

# ── 0. Disable legacy Apogee HAL plugin (conflicts with ASP) ─────────────────
# The legacy SymphonyIOUSBPlugIn.bundle uses the deprecated AudioDriverPlugIn API
# and registers with the Apogee daemon on the same socket. When both plugins are
# loaded simultaneously, property change notifications create a feedback loop
# causing coreaudiod to spin at 100%+ CPU.
#
# IMPORTANT: We disable ONLY the plugin portion (by renaming Info.plist), not the
# entire bundle. The Apogee daemon (symphonyIOUSBDaemon) binary lives inside this
# bundle, and the LaunchDaemon plist references it by full path. Renaming the
# bundle would break the daemon, which we need for hardware volume/mute control.

LEGACY_BUNDLE="/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyIOUSBPlugIn.bundle"
LEGACY_PLIST="$LEGACY_BUNDLE/Contents/Info.plist"
LEGACY_PLIST_DISABLED="$LEGACY_BUNDLE/Contents/Info.plist.disabled-asp"

if [ -f "$LEGACY_PLIST" ]; then
    echo "[ASP] Disabling legacy Apogee HAL plugin (renaming Info.plist)..."
    mv "$LEGACY_PLIST" "$LEGACY_PLIST_DISABLED"
    echo "[ASP] Plugin disabled: coreaudiod will skip bundle (no Info.plist)"
    echo "[ASP] Daemon binary preserved at original path"
    echo "[ASP] (Use uninstall.sh to re-enable if needed)"
elif [ -f "$LEGACY_PLIST_DISABLED" ]; then
    echo "[ASP] Legacy plugin already disabled (Info.plist.disabled-asp exists)"
elif [ ! -d "$LEGACY_BUNDLE" ]; then
    # Bundle was previously renamed entirely — restore it and disable properly
    # Check for common rename patterns from previous install attempts
    for suffix in ".disabled-asp" ".disabled" ".bak-"*; do
        CANDIDATE="$LEGACY_BUNDLE$suffix"
        if [ -d "$CANDIDATE" ]; then
            echo "[ASP] Restoring bundle from $CANDIDATE..."
            mv "$CANDIDATE" "$LEGACY_BUNDLE"
            if [ -f "$LEGACY_PLIST" ]; then
                mv "$LEGACY_PLIST" "$LEGACY_PLIST_DISABLED"
                echo "[ASP] Plugin disabled surgically (Info.plist renamed)"
            fi
            break
        fi
    done
fi

# Ensure the Apogee daemon is running (it lives inside the legacy bundle)
APOGEE_DAEMON_LABEL="com.apogee.symphonyIOUSBDaemon"
if ! launchctl list "$APOGEE_DAEMON_LABEL" &>/dev/null; then
    echo "[ASP] Starting Apogee daemon ($APOGEE_DAEMON_LABEL)..."
    if [ -f "/Library/LaunchDaemons/${APOGEE_DAEMON_LABEL}.plist" ]; then
        launchctl bootstrap system "/Library/LaunchDaemons/${APOGEE_DAEMON_LABEL}.plist" 2>/dev/null || \
            launchctl kickstart system/"$APOGEE_DAEMON_LABEL" 2>/dev/null || true
    fi
fi

# ── 1. Build MaestroVolumeProxy if not already built ─────────────────────────

PROXY_BIN="$PROXY_DIR/build/MaestroVolumeProxy"
if [ ! -f "$PROXY_BIN" ]; then
    echo "[ASP] Building MaestroVolumeProxy..."
    # Run as the current sudo user to avoid root-owned build artifacts
    sudo -u "${SUDO_USER:-$(logname 2>/dev/null || echo root)}" \
        bash "$PROXY_DIR/build.sh"
fi

if [ ! -f "$PROXY_BIN" ]; then
    echo "[ASP] ERROR: MaestroVolumeProxy not found at $PROXY_BIN"
    echo "[ASP] Run: cd Drivers/VolumeProxy && ./build.sh"
    exit 1
fi

# ── 2. Install MaestroVolumeProxy binary ─────────────────────────────────────

echo "[ASP] Installing MaestroVolumeProxy to /usr/local/bin/..."
mkdir -p /usr/local/bin

# Stage beside the destination, sign the staged copy, then swap it in with
# rename(2) -- and do all of it BEFORE the running proxy is stopped below.
#
# A plain `cp -f` onto the live path (and equally a `codesign --force` on it)
# truncates and rewrites the SAME inode. The proxy running out of that inode is
# still lazily paging its own text, so the next page it faults in no longer
# matches the code signature it was validated against; the kernel SIGKILLs it
# with CODESIGNING / "Invalid Page" and writes a crash report for what should
# have been a clean restart. rename(2) swaps the directory entry instead, so the
# old process keeps a whole inode until the pkill below ends it on purpose.
PROXY_STAGE="/usr/local/bin/MaestroVolumeProxy.new.$$"
trap 'rm -f "$PROXY_STAGE"' EXIT
cp -f "$PROXY_BIN" "$PROXY_STAGE"
chown root:wheel "$PROXY_STAGE"
chmod 755 "$PROXY_STAGE"

: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY in the private build environment}"
codesign --sign "$SIGNING_IDENTITY" \
    --force "$PROXY_STAGE"
codesign -v "$PROXY_STAGE" && echo "[ASP] Proxy binary signed OK"

mv -f "$PROXY_STAGE" /usr/local/bin/MaestroVolumeProxy
trap - EXIT

# ── 3. Install and load the LaunchDaemon plist ────────────────────────────────

echo "[ASP] Installing LaunchDaemon plist to $DAEMON_PLIST_DST..."
if [ ! -f "$DAEMON_PLIST_SRC" ]; then
    echo "[ASP] ERROR: Proxy plist not found at $DAEMON_PLIST_SRC"
    exit 1
fi
cp -f "$DAEMON_PLIST_SRC" "$DAEMON_PLIST_DST"
chown root:wheel "$DAEMON_PLIST_DST"
chmod 644 "$DAEMON_PLIST_DST"

# Remove from system domain if already registered, then re-bootstrap.
# Use modern launchctl bootstrap/bootout (launchctl load is deprecated on macOS 12+).
# Kill the running process first so the Mach service name is released before bootout.
pkill -x MaestroVolumeProxy 2>/dev/null || true
sleep 1
launchctl bootout system/com.danielraffel.Maestro.volumeproxy 2>/dev/null || true
sleep 1
launchctl bootstrap system "$DAEMON_PLIST_DST" || {
    # Retry once — Mach name cleanup can take a moment after bootout
    sleep 2
    launchctl bootstrap system "$DAEMON_PLIST_DST"
}
echo "[ASP] MaestroVolumeProxy LaunchDaemon bootstrapped"

# ── 4. Check the driver bundle exists ─────────────────────────────────────────

if [ ! -d "$BUILD_DIR/$DRIVER_NAME" ]; then
    echo "[ASP] ERROR: Driver not found at $BUILD_DIR/$DRIVER_NAME"
    echo "[ASP] Run build.sh first."
    exit 1
fi

# ── 5. Install AudioServerPlugin driver bundle ────────────────────────────────

echo "[ASP] Installing $DRIVER_NAME to $INSTALL_DIR/"

if [ -d "$INSTALL_DIR/$DRIVER_NAME" ]; then
    echo "[ASP] Removing old $DRIVER_NAME..."
    rm -rf "$INSTALL_DIR/$DRIVER_NAME"
fi

cp -R "$BUILD_DIR/$DRIVER_NAME" "$INSTALL_DIR/$DRIVER_NAME"
echo "[ASP] Copied to $INSTALL_DIR/$DRIVER_NAME"
chown -R root:wheel "$INSTALL_DIR/$DRIVER_NAME"

# Re-sign after copy to ensure the signature covers the final install path.
# coreaudiod validates the signature against the file on disk at load time.
echo "[ASP] Signing installed bundle..."
codesign --sign "$SIGNING_IDENTITY" \
    --force --deep \
    "$INSTALL_DIR/$DRIVER_NAME"
codesign -v "$INSTALL_DIR/$DRIVER_NAME" && echo "[ASP] Signature OK"

# ── 6. Restart coreaudiod ─────────────────────────────────────────────────────

echo "[ASP] Restarting coreaudiod (this will interrupt all audio)..."
# killall is used instead of `launchctl kickstart -kp` because SIP blocks
# the kickstart -kp flag on system services. launchd auto-restarts coreaudiod
# immediately after the kill signal.
killall coreaudiod 2>/dev/null || true
sleep 3

echo "[ASP] Install complete."
echo ""
echo "[ASP] Installed components:"
echo "  - /Library/Audio/Plug-Ins/HAL/$DRIVER_NAME  (AudioServerPlugin)"
echo "  - /usr/local/bin/MaestroVolumeProxy          (XPC→socket proxy)"
echo "  - $DAEMON_PLIST_DST"
echo ""
echo "[ASP] Next steps:"
echo "  1. Open Audio MIDI Setup — look for 'Apogee Symphony IO' virtual device"
echo "  2. Set it as Default Output"
echo "  3. Press volume up/down — hardware output level should change"
echo ""
echo "[ASP] Logs:"
echo "  Plugin: log stream --predicate 'subsystem == \"com.apogee.audio.symphonyio-asp\"' --level debug"
echo "  Proxy:  tail -f /tmp/MaestroVolumeProxy.log"
