#!/bin/bash
# capture-dext-evidence.sh — produce the diagnostic transcript for Apple.
#
# The bug is an ABSENCE of output: a dext signed with an entitlement its embedded
# provisioning profile does not grant never launches, and logs nothing anywhere.
# You cannot attach nothing, so attach a transcript proving nothing is there.
#
# Run this TWICE, with the ThunderBridge connected:
#
#   1. with the FAILING build installed (entitlement present, profile omits it)
#        ./Tools/capture-dext-evidence.sh failing
#   2. with the WORKING build installed (entitlement absent)
#        ./Tools/capture-dext-evidence.sh working
#
# Then attach both files. Side by side they are the report.
set -uo pipefail

LABEL="${1:?usage: capture-dext-evidence.sh <failing|working>}"
DEXT_ID="com.danielraffel.maestro.thunderbridge"
OUT="/tmp/dext-evidence-${LABEL}.txt"

exec > >(tee "$OUT") 2>&1

echo "==============================================================="
echo " DriverKit extension evidence capture — build: $LABEL"
echo " Team 95CX6P84C4"
echo "==============================================================="
echo
echo "--- Environment"
sw_vers
echo "Hardware: $(sysctl -n hw.model)"
echo "SIP: $(csrutil status)"
echo "Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
echo

echo "--- 1. The system reports the extension as activated and enabled"
echo "\$ systemextensionsctl list"
systemextensionsctl list 2>&1 | grep -iE "thunderbridge|bundleID|extension\(s\)" || echo "(no matching extension)"
echo

echo "--- 2. Entitlements actually signed into the installed dext"
INSTALLED=$(ls -d /Library/SystemExtensions/*/${DEXT_ID}.dext 2>/dev/null | head -1)
echo "installed at: ${INSTALLED:-<none found>}"
if [ -n "${INSTALLED:-}" ]; then
    echo "\$ codesign -d --entitlements :- <dext>"
    codesign -d --entitlements :- "$INSTALLED" 2>/dev/null | plutil -p -
    echo
    echo "CFBundleVersion: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Info.plist" 2>/dev/null)"
fi
echo

echo "--- 3. Entitlements GRANTED by the embedded provisioning profile"
if [ -n "${INSTALLED:-}" ] && [ -f "$INSTALLED/embedded.provisionprofile" ]; then
    echo "\$ security cms -D -i <dext>/embedded.provisionprofile | plutil -extract Entitlements xml1 -o - -"
    security cms -D -i "$INSTALLED/embedded.provisionprofile" \
        | plutil -extract Entitlements xml1 -o - - | grep -E '<key>|<true|<false'
fi
echo

echo "--- 4. Is the dext process running?"
echo "\$ ps aux | grep $DEXT_ID"
if ps aux | grep -i thunderbrid | grep -v grep; then :; else echo "(NO PROCESS)"; fi
echo

echo "--- 5. Did IOKit create an IOUserServer for it?"
echo "\$ ioreg -r -c IOUserServer | grep thunderbridge"
ioreg -r -c IOUserServer 2>/dev/null | grep -i thunderbrid || echo "(NO IOUserServer NODE)"
echo

echo "--- 6. The PCIe device it matches against (retain count rises when a dext attaches)"
echo "\$ ioreg -r -n pci19c2,2200"
ioreg -r -n "pci19c2,2200" 2>/dev/null | head -1 || echo "(hardware not present — connect it before capturing)"
echo

echo "--- 7. Did kernelmanagerd attempt to launch the dext?"
echo "    NOTE: a dext's own os_log output is NOT persisted to the log store. \`log show\`"
echo "    never returns it, for working or failing builds alike; only \`log stream\` sees it"
echo "    live. So the evidence below concerns the SYSTEM subsystems, whose logs do persist."
echo "\$ log show --last 10m --info --debug --predicate 'eventMessage CONTAINS \"thunderbridge\"'"
log show --last 10m --info --debug --predicate 'eventMessage CONTAINS "thunderbridge"' 2>/dev/null \
    | grep -iE "kernelmanagerd|sysextd|AMFI|kernel:" | head -25
C=$(log show --last 10m --info --debug --predicate 'eventMessage CONTAINS "thunderbridge"' 2>/dev/null | grep -c . || true)
echo "[total matching lines: ${C:-0}]"
echo "[a working build shows: 'Launching dext', 'Launching driver extension',"
echo " 'Received kext load notification'. Their absence means no launch was attempted.]"
echo

echo "--- 8. Was any rejection reason recorded by kernelmanagerd / sysextd / AMFI?"
echo "\$ log show --last 10m --info --debug --predicate 'process==\"kernelmanagerd\" OR process==\"sysextd\" OR subsystem==\"com.apple.amfi\"' | grep -i 'entitle|denied|reject|invalid|ENOEXEC'"
R=$(log show --last 10m --info --debug \
    --predicate 'process == "kernelmanagerd" OR process == "sysextd" OR subsystem == "com.apple.amfi"' 2>/dev/null \
    | grep -iE "entitle|denied|ENOEXEC|reject|invalid|not permitted" | head -20)
if [ -n "$R" ]; then echo "$R"; else echo "(NOTHING — no subsystem records any rejection or reason)"; fi
echo

echo "--- 8b. The dext's own os_log, captured LIVE (the only way to see it)"
echo "\$ log stream --predicate 'eventMessage CONTAINS \"SymphonyTB\"' --info    [5s sample]"
S=$(timeout 5 log stream --predicate 'eventMessage CONTAINS "SymphonyTB"' --info 2>/dev/null | grep -c "SymphonyTB" || true)
echo "[lines seen live in 5s: ${S:-0}]  (0 for a dext that never launched)"
echo

echo "--- 9. Gatekeeper assessment of the installed dext"
[ -n "${INSTALLED:-}" ] && spctl -a -vvv --type install "$INSTALLED" 2>&1 | head -4
echo

echo "==============================================================="
echo " Saved to: $OUT"
echo "==============================================================="
