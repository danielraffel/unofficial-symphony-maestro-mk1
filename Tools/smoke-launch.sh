#!/bin/bash
# smoke-launch.sh: after installing a package, prove the installed Maestro opens.
set -u
WAIT="${1:-20}"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
MARK="$(mktemp -t maestro-smoke)"
trap 'rm -f "$MARK"' EXIT

if pgrep -x MaestroApp >/dev/null; then
    osascript -e 'tell application "Maestro" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        pgrep -x MaestroApp >/dev/null || break
        sleep 1
    done
    if pgrep -x MaestroApp >/dev/null; then
        echo "FAIL: Maestro is still running after quit request" >&2
        exit 1
    fi
fi

open -g /Applications/Maestro.app
sleep "$WAIT"
fail=0
pid="$(pgrep -x MaestroApp | head -1 || true)"
if [ -z "$pid" ]; then
    echo "FAIL: Maestro is not running ${WAIT}s after launch"; fail=1
else
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in
        /Applications/Maestro.app/*) ;;
        *) echo "FAIL: running Maestro is not the installed app: $command"; fail=1 ;;
    esac
fi
new="$(find "$REPORTS" -maxdepth 1 -name 'MaestroApp-*.ips' -newer "$MARK" 2>/dev/null | head -1)"
if [ -n "$new" ]; then echo "FAIL: new crash report $new"; fail=1; fi
plist="/Applications/Maestro.app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || echo '?')"
echo "CFBundleVersion: $bundle"
if extra="$(/usr/libexec/PlistBuddy -c 'Print :MaestroBuildNumber' "$plist" 2>/dev/null)"; then
    echo "MaestroBuildNumber: $extra"
fi
systemextensionsctl list 2>/dev/null | grep -i 'maestro.thunderbridge' | sed 's/^/driver: /'
[ "$fail" = 0 ] && echo "OK: Maestro up for ${WAIT}s, no new crash report"
exit "$fail"
