#!/bin/bash
# test-app.sh: run the app's Swift tests, then remove the scratch settings
# files (maestro.tests.*) the run left in ~/Library/Preferences.
#
#   Tools/test-app.sh [swift test arguments]
#
# The tests remove their settings suites, but cfprefsd writes some plists back
# after the test processes exit, so the sweep runs once the whole run is over
# (and a few seconds later, for files still being flushed). Only files named
# maestro.tests.* created during this run are removed.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFS="$HOME/Library/Preferences"
MARK="$(mktemp -t maestro-test-run)"
trap 'rm -f "$MARK"' EXIT
(cd "$REPO/Apps/Maestro" && swift test "$@")
status=$?
sweep() {
    find "$PREFS" -maxdepth 1 -name 'maestro.tests.*.plist' -newer "$MARK" -print0 2>/dev/null \
        | xargs -0 rm -f 2>/dev/null
}
sweep; sleep 3; sweep
left=$(find "$PREFS" -maxdepth 1 -name 'maestro.tests.*.plist' -newer "$MARK" 2>/dev/null | wc -l | tr -d ' ')
echo "test-app: scratch settings files left from this run: $left"
exit $status
