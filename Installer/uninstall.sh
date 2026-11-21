#!/bin/bash
# Uninstall Symphony Maestro
#
# Removes all installed components and restores the original Apogee HAL plugin.
# Usage: sudo /Applications/Maestro.app/Contents/Resources/uninstall.sh
#    or: sudo ./uninstall.sh
#
# This script is also bundled inside Maestro.app/Contents/Resources/ for convenience.

set -euo pipefail

# >>> apogee-kext-check
# Which of Apogee's kernel drivers are loaded now. Installer/uninstall.sh
# carries this block too, byte for byte (it has to work as a single downloaded
# file); Tools/test-installer-tools.sh fails when the two differ.
#
# Same pair as `pciKernelExtensions` in MaestroCore/OriginalApogeeDrivers.swift.
APOGEE_PCIE_KEXT_IDS=("com.apogeedigital.driver.Symphony64ThunderBridge" "com.apogeedigital.driver.Symphony64")

# The tests replace tools and the root folder through environment variables
# (APOGEE_ROOT, KMUTIL, KEXTSTAT, PLISTBUDDY, OSASCRIPT, SYSTEMEXTENSIONSCTL,
# CONSOLE_USER, PROBE_TIMEOUT). They are honoured only with
# MAESTRO_PREINSTALL_TEST=1, so nothing left in a user's environment can point
# a script running as root at another tool. $1 = variable name, $2 = real value.
test_override() {
    if [ "${MAESTRO_PREINSTALL_TEST:-}" = 1 ] && [ -n "${!1:-}" ]; then
        printf '%s\n' "${!1}"
    else
        printf '%s\n' "$2"
    fi
}

# Runs a probe with a deadline. $1 = seconds, the rest is the command. Prints
# the command's output and returns its status; when it is still running after
# the deadline it is killed, nothing is printed and 124 is returned.
run_with_timeout() {
    local seconds="$1" out pid ticks=0 status=0
    shift
    out="$(mktemp "${TMPDIR:-/tmp}/maestro-probe.XXXXXX" 2>/dev/null)" || return 125
    "$@" > "$out" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((seconds * 10)) ]; then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            rm -f "$out"
            return 124
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid" 2>/dev/null || status=$?
    cat "$out"
    rm -f "$out"
    return "$status"
}

# The loaded kernel extensions, as kmutil lists them, or kextstat when kmutil
# fails. Returns non-zero when neither answered within a few seconds: that is
# "could not check", never "none loaded".
loaded_kernel_extensions() {
    local seconds
    seconds="$(test_override PROBE_TIMEOUT 5)"
    run_with_timeout "$seconds" "$(test_override KMUTIL /usr/bin/kmutil)" showloaded --list-only \
        || run_with_timeout "$seconds" "$(test_override KEXTSTAT /usr/sbin/kextstat)"
}

# Which of the bundle identifiers given appear in a listing. $1 = the listing,
# the rest are identifiers. Whole identifiers only (-w): "...Symphony64" must
# not match "...Symphony64ThunderBridge". The listing goes to grep as a
# here-string: `printf | grep -q` under pipefail reports a match as a failure
# when grep leaves before printf has written everything (a listing over 64 KB).
kexts_listed() {
    local listing="$1" id
    shift
    for id in "$@"; do
        if grep -Fqw -- "$id" <<< "$listing"; then echo "$id"; fi
    done
    return 0
}

# Apogee's kernel drivers for the ThunderBridge or PCIe card that are loaded
# now, one identifier per line. Returns non-zero when it could not be checked.
loaded_apogee_pcie_kexts() {
    local loaded
    loaded="$(loaded_kernel_extensions)" || return 1
    kexts_listed "$loaded" "${APOGEE_PCIE_KEXT_IDS[@]}"
}
# <<< apogee-kext-check

APP="/Applications/Maestro.app"
DEXT_ID="com.danielraffel.maestro.thunderbridge"
REMOVAL_GUIDE_URL="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/blob/dev/docs/UserManual.md#removing-apogees-original-drivers"

# What macOS lists as system extensions; empty when it cannot be asked.
system_extensions_listed() {
    "$(test_override SYSTEMEXTENSIONSCTL /usr/bin/systemextensionsctl)" list 2>/dev/null || true
}

# True when Maestro's driver extension is registered with macOS and activated.
# A copy macOS has already terminated and is waiting to uninstall
# ("[terminated waiting to uninstall on reboot]") does not count: it is not on
# the card, and the app leaves it out too (`isUninstalling`). The list is
# captured, then matched in one process: `systemextensionsctl list | grep -q`
# under pipefail can report a match as a failure.
maestro_dext_registered() {
    local listed
    listed="$(system_extensions_listed)"
    awk -v id="$DEXT_ID" 'index($0, id) && /\[activated/ && !/uninstall/ { found = 1 } END { exit !found }' <<< "$listed"
}

# The team identifier that step 7 needs to remove the driver extension, or nothing: from
# the driver inside Maestro.app, or, when the app is already gone, from the
# teamID column of macOS's own list. Never fails: under `set -e` and pipefail a
# codesign that finds no app would otherwise end the script without a word.
maestro_dext_team_id() {
    local team listed
    team="$("$(test_override CODESIGN /usr/bin/codesign)" -dvv "$APP/Contents/Library/SystemExtensions/$DEXT_ID.dext" 2>&1 \
        | awk -F= '/^TeamIdentifier=/ { print $2; exit }' || true)"
    if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        listed="$(system_extensions_listed)"
        team="$(awk -v id="$DEXT_ID" '{ for (i = 2; i <= NF; i++) if ($i == id) { print $(i - 1); exit } }' <<< "$listed" || true)"
        [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || team=""
    fi
    printf '%s\n' "$team"
}

# Why this script can refuse to run (the full account is in AGENTS.md,
# "Apogee's original drivers: what we do and why"): removing Maestro stops its
# driver extension, and with Apogee's kernel driver for the same card loaded,
# macOS's kernel crashes when either driver lets go of the card's interrupt.
# That Stop is the crash, so the uninstall does not start in that state; it
# says to shut down and disconnect the card first, as the user guide does.
# This script never removes or unloads anything of Apogee's (it only puts back
# a plug-in our own installer set aside), and must not start to: owner's
# decision. Returns 0, with the explanation printed, when the uninstall must
# not go ahead. A check that could not be made is not a reason to refuse.
uninstall_blocked_by_apogee_driver() {
    local loaded
    loaded="$(loaded_apogee_pcie_kexts)" || return 1
    [ -n "$loaded" ] || return 1
    maestro_dext_registered || return 1
    cat <<EOF
Symphony Maestro was not removed, and nothing was changed.

Apogee's original Symphony driver is loaded, and so is Maestro's driver.
Removing Maestro stops its driver, and with both drivers on the ThunderBridge
or PCIe card that can crash your Mac and make it restart repeatedly.

Do this first:
  1. Shut down your Mac and disconnect the ThunderBridge or PCIe chassis,
     then start up again.
  2. Run this script again.

Or remove Apogee's original drivers first, as described under
"Removing Apogee's original drivers" in the Maestro user guide:
  $REMOVAL_GUIDE_URL
EOF
    return 0
}

# Sourced by Tools/test-installer-tools.sh for the functions above; run otherwise.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo $0)"
    exit 1
fi

# Before anything is asked or touched.
if uninstall_blocked_by_apogee_driver; then
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
DEXT_NEEDS_MANUAL=0
if maestro_dext_registered; then
    # `systemextensionsctl uninstall` only works with developer mode on (SIP disabled). On a normal
    # SIP-enabled Mac it fails harmlessly — macOS requires the user to remove driver extensions from
    # System Settings — so we detect that and print instructions.
    TEAM_ID="$(maestro_dext_team_id)"
    if [ -n "$TEAM_ID" ]; then
        systemextensionsctl uninstall "$TEAM_ID" "$DEXT_ID" 2>/dev/null || true
    fi
    sleep 1
    if maestro_dext_registered; then
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
    echo "  https://knowledge.apogeedigital.com/hubfs/Software%20Installers/Symphony%20IO/SymphonyIO_Release_5.5.dmg"
fi
echo ""
echo "Log: /tmp/maestro-installer.log"
