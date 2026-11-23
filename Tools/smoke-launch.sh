#!/bin/bash
# smoke-launch.sh: after installing a package, prove Maestro opens and stays up.
#
#   Tools/smoke-launch.sh [seconds]      (default 20)
#
# Opens /Applications/Maestro.app if it is not running, waits, then fails when
# the process is gone or a MaestroApp crash report newer than the start exists.
# Prints the app build and the ThunderBridge driver macOS has active. Package
# 1113 crashed at launch with every test passing; this is the check that would
# have caught it.
set -u
WAIT="${1:-20}"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
MARK="$(mktemp -t maestro-smoke)"
trap 'rm -f "$MARK"' EXIT
pgrep -x MaestroApp >/dev/null || open -g /Applications/Maestro.app
sleep "$WAIT"
fail=0
if ! pgrep -x MaestroApp >/dev/null; then
    echo "FAIL: Maestro is not running ${WAIT}s after launch"; fail=1
fi
new="$(find "$REPORTS" -maxdepth 1 -name 'MaestroApp-*.ips' -newer "$MARK" 2>/dev/null | head -1)"
# The marker was created before the wait, so anything newer crashed in it.
if [ -n "$new" ]; then echo "FAIL: new crash report $new"; fail=1; fi
build="$(/usr/libexec/PlistBuddy -c 'Print :MaestroBuildNumber' /Applications/Maestro.app/Contents/Info.plist 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Maestro.app/Contents/Info.plist)"
echo "Maestro: $build"
systemextensionsctl list 2>/dev/null | grep -i 'maestro.thunderbridge' | sed 's/^/driver: /'
[ "$fail" = 0 ] && echo "OK: Maestro up for ${WAIT}s, no new crash report"
exit "$fail"
