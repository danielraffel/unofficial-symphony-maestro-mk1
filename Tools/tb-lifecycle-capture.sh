#!/bin/bash
# tb-lifecycle-capture.sh — snapshot the ThunderBridge/Symphony lifecycle state
# at one point of a power-cycle or cable test, without sudo.
#
#   Tools/tb-lifecycle-capture.sh <label> [minutes-of-log]
#
#   e.g.  Tools/tb-lifecycle-capture.sh 1-symphony-off 5
#         Tools/tb-lifecycle-capture.sh 2-symphony-on  3
#
# Writes /tmp/tb-lifecycle/<timestamp>-<label>/ with:
#   systemextensionsctl.txt   registered dext versions + states
#   dext-process.txt          the dext process that actually owns the card and
#                             WHICH BUNDLE VERSION it was launched from (sysextd
#                             can list a newer build as "activated" while an older
#                             process keeps running — 2026-10-21, 105 vs 106)
#   pci.txt                   system_profiler SPPCIDataType
#   audio-devices.txt         Core Audio devices
#   app-stdout.txt            tail of /tmp/maestro.log (direct-binary launches only)
#   unified-tb-lifecycle.log  Maestro's persisted probe log (category tb-lifecycle)
#   unified-sysext.log        Maestro's dext registration log (category sysext)
#   unified-dext.log          the dext's own log lines (vendor reads, link state)
#   summary.txt               one-screen digest
set -uo pipefail

LABEL="${1:?usage: tb-lifecycle-capture.sh <label> [minutes-of-log]}"
MINUTES="${2:-5}"
DEXT_ID="com.danielraffel.maestro.thunderbridge"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/tb-lifecycle/${STAMP}-${LABEL}"
mkdir -p "$OUT"

systemextensionsctl list 2>&1 | grep -iE "thunderbridge|enabled.*active|^---" > "$OUT/systemextensionsctl.txt"

describe_dext_pid() {
  local pid="$1"
  local exe bundle ver started
  exe="$(ps -o command= -p "$pid" | awk '{print $1}')"
  bundle="$(dirname "$exe")"
  ver="$(/usr/bin/plutil -extract CFBundleVersion raw "$bundle/Info.plist" 2>/dev/null || echo '?')"
  started="$(ps -o lstart= -p "$pid")"
  echo "pid=$pid version=$ver started=$started bundle=$bundle"
}
export -f describe_dext_pid

{
  echo "# processes"
  pgrep -fl "$DEXT_ID" 2>/dev/null || echo "(no dext process)"
  echo
  echo "# bundle version of each running dext process"
  pgrep -f "$DEXT_ID" 2>/dev/null | xargs -n1 -I{} bash -c 'describe_dext_pid {}'
  echo
  echo "# every registered copy on disk"
  ls -d /Library/SystemExtensions/*/"$DEXT_ID".dext 2>/dev/null | xargs -n1 -I{} bash -c \
    'echo "$(/usr/bin/plutil -extract CFBundleVersion raw {}/Info.plist 2>/dev/null)  {}"'
  echo
  echo "# app-embedded dext"
  /usr/bin/plutil -extract CFBundleVersion raw \
    "/Applications/Maestro.app/Contents/Library/SystemExtensions/$DEXT_ID.dext/Info.plist" 2>/dev/null || echo "(none)"
} > "$OUT/dext-process.txt"

# `timeout` is Homebrew coreutils, not /usr/bin; run without a limit if absent.
tmo() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
tmo 20 system_profiler SPPCIDataType > "$OUT/pci.txt" 2> "$OUT/pci.err"
# Do NOT use system_profiler SPAudioDataType here: when coreaudiod is busy its
# reporter never returns and keeps issuing property queries, which on
# 2026-10-21 left five of them stacked up and coreaudiod pegged at >100% CPU.
# One bounded enumeration through the app's own discovery is enough.
HT="$(dirname "$0")/../Apps/Maestro/.build/debug/HardwareTest"
if [ -x "$HT" ]; then
  tmo 10 "$HT" --thunderbolt-timing 2> "$OUT/audio-devices.err" | grep -E "found [0-9]+ audio|Symphony|ThunderBridge" > "$OUT/audio-devices.txt"
else
  echo "(HardwareTest not built — skipped)" > "$OUT/audio-devices.txt"
fi
tail -n 400 /tmp/maestro.log > "$OUT/app-stdout.txt" 2>/dev/null || echo "(no /tmp/maestro.log — app launched from Finder?)" > "$OUT/app-stdout.txt"

/usr/bin/log show --last "${MINUTES}m" --info \
  --predicate 'subsystem == "com.danielraffel.maestro" AND category == "tb-lifecycle"' \
  --style compact 2>/dev/null | grep -v "^Timestamp" > "$OUT/unified-tb-lifecycle.log"
/usr/bin/log show --last "${MINUTES}m" --info \
  --predicate 'subsystem == "com.danielraffel.maestro" AND category == "sysext"' \
  --style compact 2>/dev/null | grep -v "^Timestamp" | tail -n 50 > "$OUT/unified-sysext.log"
# The dext logs through os_log default; on this machine the lines surface under
# sender "thunderbridge" (process shows as kernel), not senderImagePath.
/usr/bin/log show --last "${MINUTES}m" --info \
  --predicate 'sender CONTAINS "thunderbridge"' \
  --style compact 2>/dev/null | grep -v "^Timestamp" > "$OUT/unified-dext.log"

{
  echo "label: $LABEL   captured: $STAMP   log window: ${MINUTES}m"
  echo
  echo "## registrations"; cat "$OUT/systemextensionsctl.txt"
  echo
  echo "## running dext"; grep "^pid=" "$OUT/dext-process.txt" || echo "(none)"
  echo
  echo "## PCI link"; grep -E "Link Status|Driver Installed|Slot" "$OUT/pci.txt" || echo "(no pci19c2,2200 entry)"
  echo
  echo "## last probe lines"; tail -n 8 "$OUT/unified-tb-lifecycle.log"
  echo
  echo "## last dext lines"; tail -n 6 "$OUT/unified-dext.log"
} | tee "$OUT/summary.txt"

echo
echo "saved: $OUT"
